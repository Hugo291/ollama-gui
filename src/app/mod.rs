//! The controller: owns the state, talks to Ollama and keeps the interface in sync.
//!
//! Everything here runs on the UI thread. Network calls run on a tokio runtime and
//! are awaited from `slint::spawn_local` tasks, so the state needs no locking.

mod chat;
mod downloads;
mod library;
#[cfg(target_os = "macos")]
mod macos;
mod markdown;
#[cfg(debug_assertions)]
mod script;
mod text;
mod tray;

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::rc::Rc;
use std::time::Duration;

use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

use crate::api::client::{OllamaClient, display_url, parse_address};
use crate::api::format;
use crate::api::models::{ModelInfo, OllamaModel, RunningModel, capability, display_value};
use crate::api::reference::{ModelReference, canonical};
use crate::api::registry::{self, UpdateStatus};
use crate::settings::{KEEP_ALIVE_CHOICES, REFRESH_CHOICES, Server, Settings};
use crate::{Api, AppWindow, DetailSection, Fact, ModelDetail, ModelRow, Palette, RunningRow, ServerItem, Theme, Tray};

pub use text::Text;

#[derive(Debug, Clone, PartialEq)]
enum Connection {
    Connecting,
    Connected(String),
    Unreachable(String),
}

impl Connection {
    fn is_connected(&self) -> bool {
        matches!(self, Connection::Connected(_))
    }
}

struct State {
    settings: Settings,
    client: OllamaClient,
    /// Increments on every server change; late results from another server are dropped.
    server_generation: u64,
    connection: Connection,
    models: Vec<OllamaModel>,
    running: Vec<RunningModel>,
    models_loaded: bool,
    updates: HashMap<String, UpdateStatus>,
    checking_updates: bool,
    launch_check_done: bool,
    busy: HashSet<String>,
    details: HashMap<String, ModelInfo>,
    detail_errors: HashMap<String, String>,
    detail_loading: HashSet<String>,
    tick: u64,
    refreshing: bool,
}

pub struct App {
    ui: slint::Weak<AppWindow>,
    rt: tokio::runtime::Handle,
    http: reqwest::Client,
    text: Text,
    state: RefCell<State>,
    downloads: RefCell<downloads::Downloads>,
    library: RefCell<library::Library>,
    chat: RefCell<chat::Chat>,
    refresh_timer: slint::Timer,
    tick_timer: slint::Timer,
    toast_timer: slint::Timer,
    total_memory: u64,
    last_section: Cell<i32>,
    tray: RefCell<Option<Tray>>,
    /// Sections of the model shown in the inspector, kept while it stays the same
    /// so expanded sections stay expanded.
    detail_sections: RefCell<Option<(String, ModelRc<DetailSection>)>>,
}

/// Updates `current` in place when it is a `VecModel`, so the interface keeps its
/// row instances (hover, open menus, expanded state); otherwise returns a new model.
fn update_rows<T: Clone + 'static>(current: ModelRc<T>, rows: Vec<T>, same: impl Fn(&T, &T) -> bool) -> Option<ModelRc<T>> {
    let Some(model) = current.as_any().downcast_ref::<VecModel<T>>() else {
        return Some(ModelRc::new(VecModel::from(rows)));
    };
    if model.row_count() == rows.len() {
        for (index, row) in rows.into_iter().enumerate() {
            if !model.row_data(index).is_some_and(|old| same(&old, &row)) {
                model.set_row_data(index, row);
            }
        }
    } else {
        model.set_vec(rows);
    }
    None
}

/// Compares string models by content (models compare by identity).
fn same_strings(a: &ModelRc<SharedString>, b: &ModelRc<SharedString>) -> bool {
    a.row_count() == b.row_count() && a.iter().zip(b.iter()).all(|(x, y)| x == y)
}

fn strings(values: Option<&Vec<String>>) -> ModelRc<SharedString> {
    ModelRc::new(VecModel::from(values.map(|v| v.iter().map(SharedString::from).collect::<Vec<_>>()).unwrap_or_default()))
}

impl App {
    pub fn new(ui: &AppWindow, rt: tokio::runtime::Handle) -> Rc<Self> {
        let settings = Settings::load();
        let client = OllamaClient::new(settings.current_server().url());
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .user_agent(concat!("OllamaGUI/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("HTTP client");
        let total_memory = {
            let mut system = sysinfo::System::new();
            system.refresh_memory();
            system.total_memory()
        };
        Rc::new(Self {
            ui: ui.as_weak(),
            rt,
            http,
            text: Text::system(),
            state: RefCell::new(State {
                settings,
                client,
                server_generation: 0,
                connection: Connection::Connecting,
                models: Vec::new(),
                running: Vec::new(),
                models_loaded: false,
                updates: HashMap::new(),
                checking_updates: false,
                launch_check_done: false,
                busy: HashSet::new(),
                details: HashMap::new(),
                detail_errors: HashMap::new(),
                detail_loading: HashSet::new(),
                tick: 0,
                refreshing: false,
            }),
            downloads: RefCell::new(downloads::Downloads::default()),
            library: RefCell::new(library::Library::default()),
            chat: RefCell::new(chat::Chat::default()),
            refresh_timer: slint::Timer::default(),
            tick_timer: slint::Timer::default(),
            toast_timer: slint::Timer::default(),
            total_memory,
            last_section: Cell::new(-1),
            tray: RefCell::new(None),
            detail_sections: RefCell::new(None),
        })
    }

    fn ui(&self) -> AppWindow {
        self.ui.upgrade().expect("window alive")
    }

    /// Shows the main window again (closed windows are only hidden) and brings it to the front.
    fn show_window(&self) {
        let ui = self.ui();
        let _ = ui.show();
        use slint::winit_030::WinitWindowAccessor;
        ui.window().with_winit_window(|window| {
            window.set_minimized(false);
            window.focus_window();
        });
    }

    /// Runs `future` on the tokio runtime and resolves on the UI thread.
    fn io<T, F>(&self, future: F) -> impl Future<Output = Option<T>> + use<T, F>
    where
        T: Send + 'static,
        F: Future<Output = T> + Send + 'static,
    {
        let handle = self.rt.spawn(future);
        async move { handle.await.ok() }
    }

    /// Waits without blocking the interface. (The timer must be created on the runtime.)
    fn sleep(&self, duration: Duration) -> impl Future<Output = ()> + use<> {
        let wait = self.io(async move { tokio::time::sleep(duration).await });
        async move {
            let _ = wait.await;
        }
    }

    fn spawn(self: &Rc<Self>, future: impl Future<Output = ()> + 'static) {
        let _ = slint::spawn_local(future);
    }

    pub fn start(self: &Rc<Self>) {
        let ui = self.ui();
        ui.global::<Theme>().set_is_macos(cfg!(target_os = "macos"));
        let api = ui.global::<Api>();
        // Development aid: open a given section at launch (used for screenshots).
        #[cfg(debug_assertions)]
        if let Some(section) = std::env::var("OLLAMA_GUI_SECTION").ok().and_then(|s| s.parse().ok()) {
            api.set_section(section);
        }
        #[cfg(debug_assertions)]
        script::run(self);
        api.set_app_version(env!("CARGO_PKG_VERSION").into());
        self.bind_models(&api);
        self.bind_dialogs(&api);
        self.bind_running(&api);
        self.bind_settings(&api);
        downloads::bind(self, &api);
        library::bind(self, &api);
        chat::bind(self, &api);

        self.apply_settings_to_ui();
        tray::create(self);
        self.sync_all();

        let app = Rc::downgrade(self);
        self.tick_timer.start(slint::TimerMode::Repeated, Duration::from_secs(1), move || {
            if let Some(app) = app.upgrade() {
                app.every_second();
            }
        });
        self.restart_refresh_timer();
        #[cfg(target_os = "macos")]
        {
            // Once the event loop runs: a click on the Dock icon reopens a closed window.
            let app = Rc::downgrade(self);
            slint::Timer::single_shot(Duration::ZERO, move || {
                macos::on_reopen(move || {
                    if let Some(app) = app.upgrade() {
                        app.show_window();
                    }
                });
            });
        }
        self.spawn({
            let app = self.clone();
            async move { app.refresh(true).await }
        });
    }

    fn restart_refresh_timer(self: &Rc<Self>) {
        let seconds = self.state.borrow().settings.refresh_seconds;
        let app = Rc::downgrade(self);
        self.refresh_timer.start(slint::TimerMode::Repeated, Duration::from_secs(seconds), move || {
            if let Some(app) = app.upgrade() {
                let task = app.clone();
                app.spawn(async move { task.refresh(false).await });
            }
        });
    }

    fn every_second(self: &Rc<Self>) {
        // Unload countdowns and relative dates move with time.
        if !self.state.borrow().running.is_empty() {
            self.sync_running();
        }
        // Discover loads its first results when it is opened.
        let section = self.ui().global::<Api>().get_section();
        if section != self.last_section.get() {
            self.last_section.set(section);
            if section == 3 {
                library::ensure_loaded(self);
            }
        }
    }

    // MARK: Refresh

    async fn refresh(self: Rc<Self>, force_models: bool) {
        let (client, generation) = {
            let mut state = self.state.borrow_mut();
            if state.refreshing && !force_models {
                return;
            }
            state.refreshing = true;
            (state.client.clone(), state.server_generation)
        };
        let version = self.io(async move { client.version().await }).await;
        if self.state.borrow().server_generation != generation {
            self.state.borrow_mut().refreshing = false;
            return;
        }
        match version {
            Some(Ok(version)) => {
                let need_models = {
                    let mut state = self.state.borrow_mut();
                    let was_connected = state.connection.is_connected();
                    state.connection = Connection::Connected(version);
                    force_models || !was_connected || !state.models_loaded || state.tick % 5 == 0
                };
                self.sync_connection();
                if need_models {
                    self.refresh_models().await;
                }
                self.refresh_running().await;
                let launch_check = {
                    let mut state = self.state.borrow_mut();
                    let due = state.settings.check_updates_on_launch && !state.launch_check_done && state.models_loaded;
                    if due {
                        state.launch_check_done = true;
                    }
                    due
                };
                if launch_check {
                    let app = self.clone();
                    self.spawn(async move { app.check_updates().await });
                }
            }
            Some(Err(error)) => {
                {
                    let mut state = self.state.borrow_mut();
                    state.connection = Connection::Unreachable(error.to_string());
                    state.running.clear();
                }
                self.sync_connection();
                self.sync_running();
                self.sync_models();
            }
            None => {}
        }
        let mut state = self.state.borrow_mut();
        state.tick += 1;
        state.refreshing = false;
    }

    async fn refresh_models(self: &Rc<Self>) {
        let (client, generation) = {
            let state = self.state.borrow();
            (state.client.clone(), state.server_generation)
        };
        let Some(Ok(mut models)) = self.io(async move { client.models().await }).await else { return };
        if self.state.borrow().server_generation != generation {
            return;
        }
        models.sort_by_key(|m| m.name.to_lowercase());
        {
            let mut state = self.state.borrow_mut();
            let names: HashSet<&str> = models.iter().map(|m| m.name.as_str()).collect();
            state.updates.retain(|name, _| names.contains(name.as_str()));
            state.models = models;
            state.models_loaded = true;
        }
        let ui = self.ui();
        let api = ui.global::<Api>();
        let selected = api.get_selected_model();
        if !selected.is_empty() && !self.state.borrow().models.iter().any(|m| m.name == selected.as_str()) {
            api.set_selected_model(SharedString::new());
        }
        self.sync_models();
        self.sync_detail();
        // The models that can be loaded come from this list.
        self.sync_running();
        library::sync(self);
        chat::sync_models(self);
    }

    async fn refresh_running(self: &Rc<Self>) {
        let (client, generation) = {
            let state = self.state.borrow();
            (state.client.clone(), state.server_generation)
        };
        let Some(Ok(mut running)) = self.io(async move { client.running_models().await }).await else { return };
        if self.state.borrow().server_generation != generation {
            return;
        }
        running.sort_by_key(|m| m.name.to_lowercase());
        let changed = self.state.borrow().running != running;
        self.state.borrow_mut().running = running;
        if changed {
            self.sync_running();
            self.sync_models();
            self.sync_detail();
            chat::sync_hint(self);
        }
    }

    fn select_server(self: &Rc<Self>, id: &str) {
        {
            let mut state = self.state.borrow_mut();
            if state.settings.selected_server == id || !state.settings.servers.iter().any(|s| s.id == id) {
                return;
            }
            state.settings.selected_server = id.to_owned();
            state.settings.save();
        }
        self.server_changed();
    }

    /// Resets everything bound to the previous server and reconnects.
    fn server_changed(self: &Rc<Self>) {
        {
            let mut state = self.state.borrow_mut();
            state.client = OllamaClient::new(state.settings.current_server().url());
            state.server_generation += 1;
            state.connection = Connection::Connecting;
            state.models.clear();
            state.running.clear();
            state.models_loaded = false;
            state.updates.clear();
            state.details.clear();
            state.detail_errors.clear();
            state.launch_check_done = false;
            state.refreshing = false;
        }
        self.ui().global::<Api>().set_selected_model(SharedString::new());
        self.sync_all();
        let app = self.clone();
        self.spawn(async move { app.refresh(true).await });
    }

    // MARK: Sync to the interface

    fn sync_all(self: &Rc<Self>) {
        self.sync_connection();
        self.sync_models();
        self.sync_detail();
        self.sync_running();
        self.sync_servers();
        downloads::sync(self);
        library::sync(self);
        chat::sync(self);
    }

    fn server_label(&self, server: &Server) -> String {
        if server.name.trim().is_empty() { self.text.this_computer() } else { server.name.clone() }
    }

    fn sync_connection(self: &Rc<Self>) {
        let ui = self.ui();
        let api = ui.global::<Api>();
        let state = self.state.borrow();
        let server = state.settings.current_server();
        let (code, text, error) = match &state.connection {
            Connection::Connecting => (0, self.text.connecting(), String::new()),
            Connection::Connected(version) => (1, self.text.connected(version), String::new()),
            Connection::Unreachable(error) => (2, self.text.unreachable(), error.clone()),
        };
        api.set_connection(code);
        api.set_connection_text(text.into());
        api.set_connection_error(error.into());
        api.set_server_name(self.server_label(server).into());
        api.set_server_url(display_url(&server.url()).into());
        api.set_can_start_ollama(server.is_local() && ollama_launcher().is_some());
        drop(state);
        tray::sync(self);
    }

    fn sync_servers(self: &Rc<Self>) {
        let ui = self.ui();
        let api = ui.global::<Api>();
        let state = self.state.borrow();
        let items: Vec<ServerItem> = state
            .settings
            .servers
            .iter()
            .map(|server| ServerItem {
                id: server.id.clone().into(),
                name: self.server_label(server).into(),
                address: server.address.clone().into(),
                url: display_url(&server.url()).into(),
                current: server.id == state.settings.selected_server,
            })
            .collect();
        let model = ModelRc::new(VecModel::from(items));
        api.set_servers(model.clone());
        api.set_server_list(model);
    }

    fn model_kind(model: &OllamaModel) -> i32 {
        if model.is_cloud() {
            4
        } else if model.supports(capability::IMAGE) {
            3
        } else if model.supports(capability::EMBEDDING) {
            2
        } else if model.supports(capability::VISION) {
            1
        } else {
            0
        }
    }

    fn update_code(status: Option<&UpdateStatus>) -> i32 {
        match status {
            Some(UpdateStatus::Checking) => 1,
            Some(UpdateStatus::Available) => 2,
            Some(UpdateStatus::UpToDate) => 3,
            _ => 0,
        }
    }

    fn is_running(state: &State, name: &str) -> bool {
        state.running.iter().any(|m| m.name == name || m.model.as_deref() == Some(name))
    }

    fn sync_models(self: &Rc<Self>) {
        let ui = self.ui();
        let api = ui.global::<Api>();
        let state = self.state.borrow();
        let query = api.get_model_search().trim().to_lowercase();
        let filter = api.get_model_filter();
        let column = api.get_sort_column();
        let ascending = api.get_sort_ascending();

        let mut rows: Vec<&OllamaModel> = state
            .models
            .iter()
            .filter(|m| match filter {
                1 => !m.is_cloud(),
                2 => m.is_cloud(),
                3 => m.supports(capability::VISION),
                4 => m.supports(capability::TOOLS),
                5 => m.supports(capability::THINKING),
                6 => m.supports(capability::EMBEDDING),
                7 => m.supports(capability::IMAGE),
                _ => true,
            })
            .filter(|m| query.is_empty() || m.name.to_lowercase().contains(&query) || m.family().is_some_and(|f| f.to_lowercase().contains(&query)))
            .collect();
        rows.sort_by(|a, b| {
            let ordering = match column {
                1 => format::parameter_value(a.parameter_size().as_deref()).total_cmp(&format::parameter_value(b.parameter_size().as_deref())),
                2 => a.quantization().unwrap_or_default().cmp(&b.quantization().unwrap_or_default()),
                3 => (if a.is_cloud() { 0 } else { a.size + 1 }).cmp(&(if b.is_cloud() { 0 } else { b.size + 1 })),
                4 => a.modified_at.cmp(&b.modified_at),
                _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            };
            if ascending { ordering } else { ordering.reverse() }
        });

        let now = chrono::Utc::now();
        let downloads = self.downloads.borrow();
        let generation_server = state.settings.selected_server.clone();
        let items: Vec<ModelRow> = rows
            .iter()
            .map(|m| {
                let download = downloads.active_progress(&m.name, &generation_server);
                ModelRow {
                    name: m.name.clone().into(),
                    kind: Self::model_kind(m),
                    parameters: m.parameter_size().unwrap_or_else(|| "—".into()).into(),
                    quantization: m.quantization().unwrap_or_else(|| "—".into()).into(),
                    size: if m.is_cloud() { self.text.cloud() } else { self.text.bytes(m.size) }.into(),
                    is_cloud: m.is_cloud(),
                    capabilities: strings(m.capabilities.as_ref()),
                    modified: m.modified_at.map(|d| format::relative_time(now - d.to_utc(), self.text.lang)).unwrap_or_else(|| "—".into()).into(),
                    modified_long: m.modified_at.map(|d| format::long_date(d.with_timezone(&chrono::Local), self.text.lang)).unwrap_or_default().into(),
                    running: Self::is_running(&state, &m.name),
                    update: Self::update_code(state.updates.get(&m.name)),
                    downloading: download.is_some(),
                    progress: download.flatten().unwrap_or(-1.0),
                    can_chat: m.can_chat(),
                    can_load: m.can_load(),
                    can_customize: !m.is_cloud() && m.can_chat(),
                    has_page: m.reference().and_then(|r| r.web_page()).is_some(),
                }
            })
            .collect();
        let same =
            |a: &ModelRow, b: &ModelRow| ModelRow { capabilities: b.capabilities.clone(), ..a.clone() } == *b && same_strings(&a.capabilities, &b.capabilities);
        if let Some(model) = update_rows(api.get_models(), items, same) {
            api.set_models(model);
        }
        api.set_models_count(state.models.len() as i32);
        api.set_models_loaded(state.models_loaded);

        let update_count = state.updates.values().filter(|s| **s == UpdateStatus::Available).count();
        api.set_update_count(update_count as i32);
        api.set_checking_updates(state.checking_updates);
        let subtitle = if state.models_loaded {
            let disk: u64 = state.models.iter().filter(|m| !m.is_cloud()).map(|m| m.size).sum();
            let mut parts = vec![self.text.models_count(state.models.len()), self.text.bytes(disk)];
            if update_count > 0 {
                parts.push(self.text.updates_available(update_count));
            }
            parts.join(" · ")
        } else {
            String::new()
        };
        api.set_models_subtitle(subtitle.into());
    }

    fn sync_detail(self: &Rc<Self>) {
        let ui = self.ui();
        let api = ui.global::<Api>();
        let selected = api.get_selected_model().to_string();
        let state = self.state.borrow();
        let Some(model) = state.models.iter().find(|m| m.name == selected) else {
            api.set_has_detail(false);
            return;
        };
        let key = format!("{}@{}", model.name, model.digest);
        let info = state.details.get(&key);
        let t = &self.text;
        let mut facts: Vec<(String, String, bool)> = Vec::new();
        if model.is_cloud() {
            facts.push((t.fact_runs_on(), model.remote_host.clone().unwrap_or_else(|| "ollama.com".into()), false));
        } else {
            facts.push((t.fact_size(), t.bytes(model.size), false));
        }
        if let Some(parameters) = model.parameter_size().or_else(|| info.and_then(ModelInfo::parameter_count).map(format::parameter_count)) {
            facts.push((t.fact_parameters(), parameters, false));
        }
        if let Some(quantization) = model.quantization() {
            facts.push((t.fact_quantization(), quantization, false));
        }
        if let Some(format) = model.format() {
            facts.push((t.fact_format(), format, false));
        }
        if let Some(architecture) = info.and_then(ModelInfo::architecture) {
            facts.push((t.fact_architecture(), architecture, false));
        }
        if let Some(context) = info.and_then(ModelInfo::context_length).or(model.details.context_length) {
            facts.push((t.fact_context(), t.tokens(&format::tokens(context)), false));
        }
        if let Some(embedding) = info.and_then(ModelInfo::embedding_length) {
            facts.push((t.fact_embedding(), embedding.to_string(), false));
        }
        if let Some(modified) = model.modified_at {
            facts.push((t.fact_modified(), format::long_date(modified.with_timezone(&chrono::Local), t.lang), false));
        }
        if let Some(requires) = info.and_then(|i| i.requires.clone()) {
            facts.push((t.fact_requires(), format!("Ollama {requires}"), false));
        }
        if let Some(license) = info.and_then(ModelInfo::license_title) {
            facts.push((t.fact_license(), license, false));
        }

        let mut sections: Vec<DetailSection> = Vec::new();
        if let Some(info) = info {
            let non_blank = |text: &Option<String>| text.as_ref().filter(|t| !t.trim().is_empty()).cloned();
            let parameters = info.parameter_list();
            if !parameters.is_empty() {
                let width = parameters.iter().map(|p| p.key.len()).max().unwrap_or(0);
                let text = parameters.iter().map(|p| format!("{:width$}  {}", p.key, p.value)).collect::<Vec<_>>().join("\n");
                sections.push(DetailSection { title: t.section_parameters().into(), text: text.into(), expanded: true });
            }
            if let Some(system) = non_blank(&info.system) {
                sections.push(DetailSection { title: t.section_system().into(), text: system.into(), expanded: true });
            }
            if let Some(template) = non_blank(&info.template) {
                sections.push(DetailSection { title: t.section_template().into(), text: template.into(), expanded: false });
            }
            if let Some(modelfile) = non_blank(&info.modelfile) {
                sections.push(DetailSection { title: t.section_modelfile().into(), text: modelfile.into(), expanded: false });
            }
            if let Some(license) = non_blank(&info.license) {
                sections.push(DetailSection { title: t.section_license().into(), text: license.into(), expanded: false });
            }
            if !info.model_info.is_empty() {
                let mut keys: Vec<&String> = info.model_info.keys().collect();
                keys.sort();
                let text = keys.iter().map(|k| format!("{k} = {}", display_value(&info.model_info[*k]))).collect::<Vec<_>>().join("\n");
                sections.push(DetailSection { title: t.section_model_info().into(), text: text.into(), expanded: false });
            }
            if !info.tensors.is_empty() {
                let text = info.tensors.iter().map(|tensor| format!("{}  {}  {:?}", tensor.name, tensor.kind, tensor.shape)).collect::<Vec<_>>().join("\n");
                sections.push(DetailSection { title: t.section_tensors(info.tensors.len()).into(), text: text.into(), expanded: false });
            }
        }

        let summary = [model.family(), model.parameter_size(), model.quantization()].into_iter().flatten().collect::<Vec<_>>().join(" · ");
        let download = self.downloads.borrow().active_progress(&model.name, &state.settings.selected_server);
        let detail = ModelDetail {
            name: model.name.clone().into(),
            kind: Self::model_kind(model),
            summary: summary.into(),
            is_cloud: model.is_cloud(),
            running: Self::is_running(&state, &model.name),
            update: Self::update_code(state.updates.get(&model.name)),
            busy: state.busy.contains(&model.name),
            downloading: download.is_some(),
            progress: download.flatten().unwrap_or(-1.0),
            capabilities: strings(model.capabilities.as_ref()),
            can_chat: model.can_chat(),
            can_load: model.can_load(),
            can_customize: !model.is_cloud() && model.can_chat(),
            has_page: model.reference().and_then(|r| r.web_page()).is_some(),
            facts: ModelRc::new(VecModel::from(
                facts.into_iter().map(|(title, value, mono)| Fact { title: title.into(), value: value.into(), mono }).collect::<Vec<_>>(),
            )),
            digest: model.digest.clone().into(),
            short_digest: model.short_digest().into(),
            sections: self.detail_sections(format!("{key}:{}", info.is_some()), sections),
            loading: info.is_none() && state.detail_loading.contains(&key),
            error: state.detail_errors.get(&key).cloned().unwrap_or_default().into(),
            load_tooltip: t.load_tooltip(state.settings.keep_alive_seconds).into(),
        };
        let needs_load = info.is_none() && !state.detail_loading.contains(&key) && !state.detail_errors.contains_key(&key);
        drop(state);
        api.set_detail(detail);
        api.set_has_detail(true);
        if needs_load {
            self.load_details(key, selected);
        }
    }

    /// Reuses the sections model while the same model (and the same data) is shown.
    fn detail_sections(&self, key: String, sections: Vec<DetailSection>) -> ModelRc<DetailSection> {
        let mut cache = self.detail_sections.borrow_mut();
        if let Some((cached_key, model)) = cache.as_ref()
            && *cached_key == key
        {
            if let Some(vec) = model.as_any().downcast_ref::<VecModel<DetailSection>>()
                && vec.row_count() == sections.len()
            {
                // Same sections: refresh the text, keep the rows (and their expanded state).
                for (index, section) in sections.into_iter().enumerate() {
                    if vec.row_data(index).is_some_and(|old| old.text != section.text) {
                        vec.set_row_data(index, DetailSection { expanded: vec.row_data(index).is_some_and(|old| old.expanded), ..section });
                    }
                }
                return model.clone();
            }
        }
        let model = ModelRc::new(VecModel::from(sections));
        *cache = Some((key, model.clone()));
        model
    }

    fn load_details(self: &Rc<Self>, key: String, name: String) {
        let (client, generation) = {
            let mut state = self.state.borrow_mut();
            state.detail_loading.insert(key.clone());
            (state.client.clone(), state.server_generation)
        };
        let app = self.clone();
        self.spawn(async move {
            let result = app.io(async move { client.show(&name).await }).await;
            {
                let mut state = app.state.borrow_mut();
                state.detail_loading.remove(&key);
                if state.server_generation != generation {
                    return;
                }
                match result {
                    Some(Ok(info)) => {
                        state.details.insert(key, info);
                    }
                    Some(Err(error)) => {
                        state.detail_errors.insert(key, error.to_string());
                    }
                    None => {}
                }
            }
            app.sync_detail();
        });
    }

    fn sync_running(self: &Rc<Self>) {
        let ui = self.ui();
        let api = ui.global::<Api>();
        let state = self.state.borrow();
        let now = chrono::Utc::now();
        let rows: Vec<RunningRow> = state
            .running
            .iter()
            .map(|m| {
                let installed = state.models.iter().find(|i| i.name == m.name);
                let detail = [m.details.family.clone(), m.details.parameter_size.clone(), m.details.quantization_level.clone()]
                    .into_iter()
                    .flatten()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" · ");
                let unloads = match m.expires_at {
                    None => "—".to_owned(),
                    Some(_) if m.stays_loaded() => self.text.never(),
                    Some(expires) => {
                        let remaining = expires.to_utc() - now;
                        if remaining.num_seconds() <= 0 { self.text.now() } else { self.text.in_duration(Duration::from_secs(remaining.num_seconds() as u64)) }
                    }
                };
                RunningRow {
                    name: m.name.clone().into(),
                    detail: detail.into(),
                    kind: installed.map(Self::model_kind).unwrap_or(0),
                    memory: self.text.bytes(m.size).into(),
                    processor: m.processor_label().into(),
                    context: m.context_length.map(|c| self.text.tokens(&format::tokens(c))).unwrap_or_default().into(),
                    gpu_share: m.gpu_share(),
                    unloads: unloads.into(),
                    can_chat: installed.is_some_and(|i| i.can_chat()),
                    can_load: installed.is_some_and(|i| i.can_load()),
                    busy: state.busy.contains(&m.name),
                }
            })
            .collect();
        if let Some(model) = update_rows(api.get_running(), rows, |a, b| a == b) {
            api.set_running(model);
        }
        let used: u64 = state.running.iter().map(|m| m.size).sum();
        api.set_running_subtitle(
            if state.running.is_empty() { String::new() } else { format!("{} · {}", self.text.loaded_count(state.running.len()), self.text.bytes(used)) }
                .into(),
        );
        let local = state.settings.current_server().is_local() && self.total_memory > 0;
        api.set_show_memory_gauge(local);
        if local {
            api.set_memory_text(self.text.of(&self.text.bytes(used), &self.text.bytes(self.total_memory)).into());
            api.set_memory_share((used as f64 / self.total_memory as f64).clamp(0.0, 1.0) as f32);
        }
        let loadable: Vec<SharedString> =
            state.models.iter().filter(|m| m.can_load() && !Self::is_running(&state, &m.name)).map(|m| m.name.clone().into()).collect();
        api.set_loadable_models(ModelRc::new(VecModel::from(loadable)));
        drop(state);
        tray::sync(self);
    }

    // MARK: Model actions

    fn bind_models(self: &Rc<Self>, api: &Api) {
        let app = Rc::downgrade(self);
        let with = move |f: fn(&Rc<App>, String)| {
            let app = app.clone();
            move |name: SharedString| {
                if let Some(app) = app.upgrade() {
                    f(&app, name.to_string());
                }
            }
        };
        api.on_models_query_changed({
            let app = Rc::downgrade(self);
            move || {
                if let Some(app) = app.upgrade() {
                    app.sync_models();
                }
            }
        });
        api.on_select_model(with(|app, name| {
            app.ui().global::<Api>().set_selected_model(name.into());
            app.sync_detail();
        }));
        api.on_move_selection({
            let app = Rc::downgrade(self);
            move |delta| {
                let Some(app) = app.upgrade() else { return };
                let ui = app.ui();
                let api = ui.global::<Api>();
                let rows = api.get_models();
                if rows.row_count() == 0 {
                    return;
                }
                let current = api.get_selected_model();
                let index = (0..rows.row_count()).find(|&i| rows.row_data(i).is_some_and(|r| r.name == current));
                let next = match index {
                    None => 0,
                    Some(i) => (i as i64 + delta as i64).clamp(0, rows.row_count() as i64 - 1) as usize,
                };
                if let Some(row) = rows.row_data(next) {
                    api.set_selected_model(row.name);
                    app.sync_detail();
                }
            }
        });
        api.on_refresh({
            let app = Rc::downgrade(self);
            move || {
                if let Some(app) = app.upgrade() {
                    let task = app.clone();
                    app.spawn(async move { task.refresh(true).await });
                }
            }
        });
        api.on_retry({
            let app = Rc::downgrade(self);
            move || {
                if let Some(app) = app.upgrade() {
                    app.server_changed();
                }
            }
        });
        api.on_check_updates({
            let app = Rc::downgrade(self);
            move || {
                if let Some(app) = app.upgrade() {
                    let task = app.clone();
                    app.spawn(async move { task.check_updates().await });
                }
            }
        });
        api.on_update_all({
            let app = Rc::downgrade(self);
            move || {
                if let Some(app) = app.upgrade() {
                    let names: Vec<String> =
                        app.state.borrow().updates.iter().filter(|(_, s)| **s == UpdateStatus::Available).map(|(n, _)| n.clone()).collect();
                    for name in names {
                        downloads::pull(&app, &name);
                    }
                }
            }
        });
        api.on_load_model(with(|app, name| app.load(name, None)));
        api.on_unload_model(with(|app, name| app.unload(name)));
        api.on_update_model(with(|app, name| downloads::pull(app, &name)));
        api.on_chat_with(with(|app, name| chat::open_with(app, &name)));
        api.on_copy_name(with(|_, name| copy_to_clipboard(&name)));
        api.on_copy_text(with(|_, text| copy_to_clipboard(&text)));
        api.on_open_page(with(|_, name| {
            if let Some(url) = ModelReference::parse(&name).and_then(|r| r.web_page()) {
                let _ = open::that_detached(url);
            }
        }));
        api.on_open_url(with(|_, url| {
            if url.starts_with("https://") || url.starts_with("http://") {
                let _ = open::that_detached(url);
            }
        }));
        api.on_select_server(with(|app, id| app.select_server(&id)));
        api.on_start_ollama({
            let app = Rc::downgrade(self);
            move || {
                if let Some(app) = app.upgrade() {
                    app.start_local_ollama();
                }
            }
        });
        api.on_dismiss_toast({
            let app = Rc::downgrade(self);
            move || {
                if let Some(app) = app.upgrade() {
                    app.ui().global::<Api>().set_toast_visible(false);
                }
            }
        });
    }

    fn set_busy(self: &Rc<Self>, name: &str, busy: bool) {
        {
            let mut state = self.state.borrow_mut();
            if busy {
                state.busy.insert(name.to_owned());
            } else {
                state.busy.remove(name);
            }
        }
        self.sync_detail();
        self.sync_running();
    }

    fn load(self: &Rc<Self>, name: String, keep_alive: Option<u64>) {
        let (client, keep_alive, is_embedding) = {
            let state = self.state.borrow();
            let Some(model) = state.models.iter().find(|m| m.name == name) else { return };
            if !model.can_load() {
                return;
            }
            (state.client.clone(), keep_alive.unwrap_or(state.settings.keep_alive_seconds), model.supports(capability::EMBEDDING))
        };
        self.set_busy(&name, true);
        let app = self.clone();
        self.spawn(async move {
            let task_name = name.clone();
            let result = app.io(async move { client.load(&task_name, keep_alive, is_embedding).await }).await;
            app.set_busy(&name, false);
            if let Some(Err(error)) = result {
                app.toast(app.text.could_not_load(&name), error.to_string());
            }
            app.refresh_running().await;
        });
    }

    fn unload(self: &Rc<Self>, name: String) {
        let client = self.state.borrow().client.clone();
        self.set_busy(&name, true);
        let app = self.clone();
        self.spawn(async move {
            let task_name = name.clone();
            let result = app.io(async move { client.unload(&task_name).await }).await;
            app.set_busy(&name, false);
            if let Some(Err(error)) = result {
                app.toast(app.text.could_not_unload(&name), error.to_string());
            }
            app.refresh_running().await;
        });
    }

    fn bind_running(self: &Rc<Self>, api: &Api) {
        api.on_keep_loaded({
            let app = Rc::downgrade(self);
            move |name, choice| {
                if let Some(app) = app.upgrade()
                    && let Some(seconds) = KEEP_ALIVE_CHOICES.get(choice.max(0) as usize)
                {
                    app.load(name.to_string(), Some(*seconds));
                }
            }
        });
        api.on_unload_all({
            let app = Rc::downgrade(self);
            move || {
                if let Some(app) = app.upgrade() {
                    let names: Vec<String> = app.state.borrow().running.iter().map(|m| m.name.clone()).collect();
                    for name in names {
                        app.unload(name);
                    }
                }
            }
        });
    }

    async fn check_updates(self: Rc<Self>) {
        let candidates: Vec<OllamaModel> = {
            let mut state = self.state.borrow_mut();
            if state.checking_updates {
                return;
            }
            let candidates: Vec<OllamaModel> =
                state.models.iter().filter(|m| !m.is_cloud() && m.reference().is_some_and(|r| r.is_official_registry())).cloned().collect();
            if candidates.is_empty() {
                return;
            }
            state.checking_updates = true;
            for model in &candidates {
                state.updates.insert(model.name.clone(), UpdateStatus::Checking);
            }
            candidates
        };
        self.sync_models();
        self.sync_detail();
        let generation = self.state.borrow().server_generation;
        let http = self.http.clone();
        let results = self
            .io(async move {
                use futures_util::StreamExt;
                futures_util::stream::iter(candidates)
                    .map(|model| {
                        let http = http.clone();
                        async move { (model.name.clone(), registry::status(&http, &model).await) }
                    })
                    .buffer_unordered(4)
                    .collect::<Vec<_>>()
                    .await
            })
            .await
            .unwrap_or_default();
        {
            let mut state = self.state.borrow_mut();
            state.checking_updates = false;
            if state.server_generation == generation {
                for (name, status) in results {
                    state.updates.insert(name, status);
                }
            }
            state.updates.retain(|_, status| *status != UpdateStatus::Checking);
        }
        self.sync_models();
        self.sync_detail();
    }

    // MARK: Dialogs

    fn bind_dialogs(self: &Rc<Self>, api: &Api) {
        api.on_name_status({
            let app = Rc::downgrade(self);
            move |name, source| {
                let Some(app) = app.upgrade() else { return 0 };
                let name = name.trim();
                if name.is_empty() {
                    return 0;
                }
                if ModelReference::parse(name).is_none() {
                    return 1;
                }
                if !source.is_empty() && canonical(name) == canonical(&source) {
                    return 4;
                }
                let target = canonical(name);
                if app.state.borrow().models.iter().any(|m| canonical(&m.name) == target) { 3 } else { 2 }
            }
        });
        api.on_open_dialog({
            let app = Rc::downgrade(self);
            move |kind, target| {
                if let Some(app) = app.upgrade() {
                    app.open_dialog(kind, target.to_string());
                }
            }
        });
        api.on_pull({
            let app = Rc::downgrade(self);
            move |name| {
                if let Some(app) = app.upgrade() {
                    let ui = app.ui();
                    let api = ui.global::<Api>();
                    let from_dialog = api.get_dialog() == 1;
                    downloads::pull(&app, name.trim());
                    if from_dialog {
                        api.set_dialog(0);
                        api.set_section(2);
                    }
                }
            }
        });
        api.on_copy_model({
            let app = Rc::downgrade(self);
            move |source, destination, rename| {
                if let Some(app) = app.upgrade() {
                    app.copy_model(source.to_string(), destination.trim().to_owned(), rename);
                }
            }
        });
        api.on_delete_model({
            let app = Rc::downgrade(self);
            move |name| {
                if let Some(app) = app.upgrade() {
                    app.delete_model(name.to_string());
                }
            }
        });
        api.on_customize_base_changed({
            let app = Rc::downgrade(self);
            move |base| {
                if let Some(app) = app.upgrade() {
                    app.prefill_system_prompt(base.to_string());
                }
            }
        });
        api.on_create_model({
            let app = Rc::downgrade(self);
            move |base, name, system, temperature, num_ctx, top_p, seed| {
                if let Some(app) = app.upgrade() {
                    let mut parameters = serde_json::Map::new();
                    if temperature >= 0.0 {
                        parameters.insert("temperature".into(), serde_json::json!((temperature as f64 * 100.0).round() / 100.0));
                    }
                    if num_ctx > 0 {
                        parameters.insert("num_ctx".into(), serde_json::json!(num_ctx));
                    }
                    if top_p >= 0.0 {
                        parameters.insert("top_p".into(), serde_json::json!((top_p as f64 * 100.0).round() / 100.0));
                    }
                    if seed >= 0 {
                        parameters.insert("seed".into(), serde_json::json!(seed));
                    }
                    app.create_model(base.to_string(), name.trim().to_owned(), system.trim().to_owned(), serde_json::Value::Object(parameters));
                }
            }
        });
    }

    fn open_dialog(self: &Rc<Self>, kind: i32, target: String) {
        let ui = self.ui();
        let api = ui.global::<Api>();
        api.set_dialog_error(SharedString::new());
        api.set_dialog_status(SharedString::new());
        api.set_dialog_busy(false);
        match kind {
            2 | 3 => {
                let suggestion = if kind == 3 { target.clone() } else { suggested_copy_name(&target) };
                api.set_dialog_suggestion(suggestion.into());
            }
            4 => {
                let base_models: Vec<SharedString> =
                    self.state.borrow().models.iter().filter(|m| !m.is_cloud() && m.can_chat()).map(|m| m.name.clone().into()).collect();
                api.set_base_models(ModelRc::new(VecModel::from(base_models)));
                let repository = ModelReference::parse(&target).map(|r| r.repository).unwrap_or_else(|| "model".into());
                api.set_dialog_suggestion(format!("{repository}-custom:latest").into());
                api.set_customize_system(SharedString::new());
                self.prefill_system_prompt(target.clone());
            }
            5 => {
                let state = self.state.borrow();
                let size = state.models.iter().find(|m| m.name == target).filter(|m| !m.is_cloud() && m.size > 0).map(|m| m.size);
                api.set_dialog_message(self.text.delete_message(size).into());
            }
            _ => {}
        }
        api.set_dialog_target(target.into());
        api.set_dialog(kind);
    }

    fn prefill_system_prompt(self: &Rc<Self>, base: String) {
        let Some(model) = self.state.borrow().models.iter().find(|m| m.name == base).cloned() else { return };
        let key = format!("{}@{}", model.name, model.digest);
        if let Some(info) = self.state.borrow().details.get(&key) {
            self.ui().global::<Api>().set_customize_system(info.system.clone().unwrap_or_default().into());
            return;
        }
        let client = self.state.borrow().client.clone();
        let app = self.clone();
        self.spawn(async move {
            if let Some(Ok(info)) = app.io(async move { client.show(&model.name).await }).await {
                let ui = app.ui();
                let api = ui.global::<Api>();
                if api.get_dialog() == 4 {
                    api.set_customize_system(info.system.clone().unwrap_or_default().into());
                }
                app.state.borrow_mut().details.insert(key, info);
            }
        });
    }

    fn copy_model(self: &Rc<Self>, source: String, destination: String, rename: bool) {
        let (client, generation) = {
            let state = self.state.borrow();
            (state.client.clone(), state.server_generation)
        };
        let kind = if rename { 3 } else { 2 };
        let ui = self.ui();
        let api = ui.global::<Api>();
        api.set_dialog_busy(true);
        api.set_dialog_error(SharedString::new());
        let app = self.clone();
        self.spawn(async move {
            let (src, dst) = (source.clone(), destination.clone());
            let result = app
                .io(async move {
                    client.copy(&src, &dst).await?;
                    if rename {
                        let _ = client.unload(&src).await;
                        client.delete(&src).await?;
                    }
                    Ok::<(), crate::api::client::ApiError>(())
                })
                .await;
            let ui = app.ui();
            let api = ui.global::<Api>();
            api.set_dialog_busy(false);
            // The server changed meanwhile, or the dialog was closed: nothing to show.
            if app.state.borrow().server_generation != generation {
                return;
            }
            let dialog_open = api.get_dialog() == kind && api.get_dialog_target() == source.as_str();
            match result {
                Some(Ok(())) => {
                    if dialog_open {
                        api.set_dialog(0);
                    }
                    app.refresh_models().await;
                    app.reveal(&destination);
                }
                Some(Err(error)) if dialog_open => api.set_dialog_error(error.to_string().into()),
                Some(Err(error)) => app.toast(app.text.could_not_copy(&source), error.to_string()),
                None => {}
            }
        });
    }

    fn delete_model(self: &Rc<Self>, name: String) {
        let (client, running, generation) = {
            let state = self.state.borrow();
            (state.client.clone(), Self::is_running(&state, &name), state.server_generation)
        };
        let app = self.clone();
        self.spawn(async move {
            let task_name = name.clone();
            let result = app
                .io(async move {
                    if running {
                        let _ = client.unload(&task_name).await;
                    }
                    client.delete(&task_name).await
                })
                .await;
            if app.state.borrow().server_generation != generation {
                return;
            }
            match result {
                Some(Ok(())) => {
                    app.state.borrow_mut().updates.remove(&name);
                    let ui = app.ui();
                    let api = ui.global::<Api>();
                    if api.get_selected_model() == name.as_str() {
                        api.set_selected_model(SharedString::new());
                    }
                }
                Some(Err(error)) => app.toast(app.text.could_not_delete(&name), error.to_string()),
                None => {}
            }
            app.refresh_models().await;
            app.refresh_running().await;
        });
    }

    fn create_model(self: &Rc<Self>, base: String, name: String, system: String, parameters: serde_json::Value) {
        let (client, generation) = {
            let state = self.state.borrow();
            (state.client.clone(), state.server_generation)
        };
        let ui = self.ui();
        let api = ui.global::<Api>();
        api.set_dialog_busy(true);
        api.set_dialog_error(SharedString::new());
        let mut stream = {
            let _guard = self.rt.enter();
            client.create(&name, &base, (!system.is_empty()).then_some(system.as_str()), parameters)
        };
        let app = self.clone();
        self.spawn(async move {
            let mut succeeded = false;
            let mut failure = None;
            while let Some(event) = stream.next().await {
                match event {
                    Ok(event) => {
                        if let Some(status) = event.status {
                            succeeded |= status == "success";
                            let ui = app.ui();
                            let api = ui.global::<Api>();
                            if api.get_dialog() == 4 {
                                api.set_dialog_status(app.text.progress_status(&status).into());
                            }
                        }
                    }
                    Err(error) => {
                        failure = Some(error.to_string());
                        break;
                    }
                }
            }
            let ui = app.ui();
            let api = ui.global::<Api>();
            api.set_dialog_busy(false);
            if app.state.borrow().server_generation != generation {
                return;
            }
            let dialog_open = api.get_dialog() == 4;
            if succeeded {
                if dialog_open {
                    api.set_dialog(0);
                }
                app.refresh_models().await;
                app.reveal(&name);
            } else {
                let error = failure.unwrap_or_else(|| app.text.incomplete());
                if dialog_open {
                    api.set_dialog_error(error.into());
                } else {
                    app.toast(app.text.could_not_create(&name), error);
                }
            }
        });
    }

    /// Shows a model in the Models page.
    fn reveal(self: &Rc<Self>, name: &str) {
        let target = canonical(name);
        let found = self.state.borrow().models.iter().find(|m| canonical(&m.name) == target).map(|m| m.name.clone());
        let ui = self.ui();
        let api = ui.global::<Api>();
        if let Some(found) = found {
            api.set_selected_model(found.into());
        }
        api.set_section(0);
        self.sync_detail();
    }

    fn toast(self: &Rc<Self>, title: String, message: String) {
        let ui = self.ui();
        let api = ui.global::<Api>();
        api.set_toast_title(title.into());
        api.set_toast_message(message.into());
        api.set_toast_visible(true);
        let app = Rc::downgrade(self);
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_secs(8), move || {
            if let Some(app) = app.upgrade() {
                app.ui().global::<Api>().set_toast_visible(false);
            }
        });
    }

    // MARK: Settings

    fn apply_settings_to_ui(self: &Rc<Self>) {
        let ui = self.ui();
        let api = ui.global::<Api>();
        let state = self.state.borrow();
        let settings = &state.settings;
        let keep_alive_short: Vec<SharedString> = KEEP_ALIVE_CHOICES.iter().map(|s| self.text.keep_alive_label(*s).into()).collect();
        api.set_keep_alive_labels(ModelRc::new(VecModel::from(keep_alive_short)));
        api.set_keep_alive_index(KEEP_ALIVE_CHOICES.iter().position(|s| *s == settings.keep_alive_seconds).unwrap_or(1) as i32);
        let refresh: Vec<SharedString> = REFRESH_CHOICES.iter().map(|s| self.text.refresh_label(*s).into()).collect();
        api.set_refresh_labels(ModelRc::new(VecModel::from(refresh)));
        api.set_refresh_index(REFRESH_CHOICES.iter().position(|s| *s == settings.refresh_seconds).unwrap_or(1) as i32);
        api.set_check_updates_at_launch(settings.check_updates_on_launch);
        api.set_theme_index(settings.theme);
        api.set_show_tray_icon(settings.show_tray_icon);
        let scheme = match settings.theme {
            1 => slint::language::ColorScheme::Light,
            2 => slint::language::ColorScheme::Dark,
            _ => slint::language::ColorScheme::Unknown,
        };
        ui.global::<Palette>().set_color_scheme(scheme);
    }

    fn bind_settings(self: &Rc<Self>, api: &Api) {
        api.on_settings_changed({
            let app = Rc::downgrade(self);
            move || {
                let Some(app) = app.upgrade() else { return };
                let ui = app.ui();
                let api = ui.global::<Api>();
                let refresh_changed = {
                    let mut state = app.state.borrow_mut();
                    let settings = &mut state.settings;
                    let before = settings.refresh_seconds;
                    settings.keep_alive_seconds = *KEEP_ALIVE_CHOICES.get(api.get_keep_alive_index().max(0) as usize).unwrap_or(&300);
                    settings.refresh_seconds = *REFRESH_CHOICES.get(api.get_refresh_index().max(0) as usize).unwrap_or(&3);
                    settings.check_updates_on_launch = api.get_check_updates_at_launch();
                    settings.theme = api.get_theme_index().clamp(0, 2);
                    settings.show_tray_icon = api.get_show_tray_icon();
                    settings.save();
                    before != settings.refresh_seconds
                };
                if refresh_changed {
                    app.restart_refresh_timer();
                }
                app.apply_settings_to_ui();
                app.sync_detail();
                chat::sync_hint(&app);
                tray::set_visible(&app, api.get_show_tray_icon());
            }
        });
        api.on_add_server({
            let app = Rc::downgrade(self);
            move || {
                let Some(app) = app.upgrade() else { return };
                {
                    let mut state = app.state.borrow_mut();
                    let server = Server { id: crate::settings::new_id(), name: app.text.new_server(), address: "http://192.168.1.20:11434".into() };
                    state.settings.servers.push(server);
                    state.settings.save();
                }
                app.sync_servers();
            }
        });
        api.on_remove_server({
            let app = Rc::downgrade(self);
            move |id| {
                let Some(app) = app.upgrade() else { return };
                let was_current = {
                    let mut state = app.state.borrow_mut();
                    if state.settings.servers.len() < 2 {
                        return;
                    }
                    let was_current = state.settings.selected_server == id.as_str();
                    state.settings.servers.retain(|s| s.id != id.as_str());
                    state.settings.normalize();
                    state.settings.save();
                    was_current
                };
                app.sync_servers();
                if was_current {
                    app.server_changed();
                }
            }
        });
        api.on_save_server({
            let app = Rc::downgrade(self);
            move |id, name, address| {
                let Some(app) = app.upgrade() else { return };
                if parse_address(&address).is_none() {
                    return;
                }
                let current_changed = {
                    let mut state = app.state.borrow_mut();
                    let selected = state.settings.selected_server.clone();
                    let Some(server) = state.settings.servers.iter_mut().find(|s| s.id == id.as_str()) else { return };
                    let address_changed = server.address != address.trim();
                    server.name = name.trim().to_owned();
                    server.address = address.trim().to_owned();
                    state.settings.save();
                    address_changed && selected == id.as_str()
                };
                app.sync_servers();
                app.sync_connection();
                if current_changed {
                    app.server_changed();
                }
            }
        });
        api.on_address_preview({
            let app = Rc::downgrade(self);
            move |address| {
                let Some(app) = app.upgrade() else { return SharedString::new() };
                match parse_address(&address) {
                    Some(url) => app.text.connects_to(&display_url(&url)).into(),
                    None => app.text.invalid_address().into(),
                }
            }
        });
        api.on_test_server({
            let app = Rc::downgrade(self);
            move |address| {
                let Some(app) = app.upgrade() else { return };
                let ui = app.ui();
                let api = ui.global::<Api>();
                let Some(url) = parse_address(&address) else {
                    api.set_test_ok(false);
                    api.set_test_result(app.text.invalid_address().into());
                    return;
                };
                api.set_testing(true);
                api.set_test_result(SharedString::new());
                let task = app.clone();
                app.spawn(async move {
                    let client = OllamaClient::new(url);
                    let result = task.io(async move { client.version().await }).await;
                    let ui = task.ui();
                    let api = ui.global::<Api>();
                    api.set_testing(false);
                    match result {
                        Some(Ok(version)) => {
                            api.set_test_ok(true);
                            api.set_test_result(task.text.connected(&version).into());
                        }
                        Some(Err(error)) => {
                            api.set_test_ok(false);
                            api.set_test_result(error.to_string().into());
                        }
                        None => api.set_testing(false),
                    }
                });
            }
        });
    }

    // MARK: Local Ollama

    fn start_local_ollama(self: &Rc<Self>) {
        let Some(launcher) = ollama_launcher() else { return };
        if let Err(error) = launcher.start() {
            self.toast(self.text.could_not_start(), error.to_string());
            return;
        }
        self.state.borrow_mut().connection = Connection::Connecting;
        self.sync_connection();
        let app = self.clone();
        self.spawn(async move {
            for _ in 0..20 {
                app.sleep(Duration::from_secs(1)).await;
                app.clone().refresh(true).await;
                if app.state.borrow().connection.is_connected() {
                    break;
                }
            }
        });
    }
}

fn copy_to_clipboard(text: &str) {
    if let Ok(mut clipboard) = arboard::Clipboard::new() {
        let _ = clipboard.set_text(text.to_owned());
    }
}

fn suggested_copy_name(source: &str) -> String {
    match ModelReference::parse(source) {
        Some(reference) => {
            let base = if reference.is_official_registry() && reference.namespace == "library" {
                reference.repository.clone()
            } else {
                reference.short_name().split(':').next().unwrap_or(&reference.repository).to_owned()
            };
            format!("{base}-copy:{}", reference.tag)
        }
        None => format!("{source}-copy"),
    }
}

/// How to start Ollama on this computer: the desktop app when installed, otherwise `ollama serve`.
enum Launcher {
    #[cfg(target_os = "macos")]
    MacApp,
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    App(std::path::PathBuf),
    Serve(std::path::PathBuf),
}

impl Launcher {
    fn start(&self) -> std::io::Result<()> {
        use std::process::{Command, Stdio};
        match self {
            #[cfg(target_os = "macos")]
            Launcher::MacApp => Command::new("open").args(["-g", "-a", "Ollama"]).spawn().map(|_| ()),
            Launcher::App(path) => Command::new(path).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map(|_| ()),
            Launcher::Serve(path) => Command::new(path).arg("serve").stdout(Stdio::null()).stderr(Stdio::null()).spawn().map(|_| ()),
        }
    }
}

fn ollama_launcher() -> Option<Launcher> {
    use std::path::PathBuf;
    #[cfg(target_os = "macos")]
    {
        if std::path::Path::new("/Applications/Ollama.app").exists() {
            return Some(Launcher::MacApp);
        }
        for path in ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"] {
            if std::path::Path::new(path).exists() {
                return Some(Launcher::Serve(PathBuf::from(path)));
            }
        }
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            let base = PathBuf::from(local).join("Programs").join("Ollama");
            if base.join("ollama app.exe").exists() {
                return Some(Launcher::App(base.join("ollama app.exe")));
            }
            if base.join("ollama.exe").exists() {
                return Some(Launcher::Serve(base.join("ollama.exe")));
            }
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        for path in ["/usr/local/bin/ollama", "/usr/bin/ollama"] {
            if std::path::Path::new(path).exists() {
                return Some(Launcher::Serve(PathBuf::from(path)));
            }
        }
    }
    None
}
