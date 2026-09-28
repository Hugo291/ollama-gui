//! Pulls, with their progress aggregated over the layers of each model.

use std::collections::{HashMap, VecDeque};
use std::rc::Rc;
use std::time::{Duration, Instant};

use slint::{ComponentHandle, SharedString};

use super::{App, Text, update_rows};
use crate::api::client::OllamaClient;
use crate::api::models::ProgressEvent;
use crate::api::reference::{ModelReference, canonical};
use crate::{Api, DownloadRow};

#[derive(Debug, Clone, PartialEq)]
enum State {
    Running,
    Completed,
    Failed(String),
    Cancelled,
}

struct Download {
    id: i32,
    name: String,
    server_id: String,
    server_name: String,
    client: OllamaClient,
    state: State,
    status: String,
    /// Total and completed bytes per layer digest.
    layers: HashMap<String, (u64, u64)>,
    total: u64,
    completed: u64,
    bytes_per_second: f64,
    samples: VecDeque<(Instant, u64)>,
    last_publish: Option<Instant>,
    started: Instant,
    finished: Option<Instant>,
    saw_success: bool,
    cancel_requested: bool,
    abort: Option<tokio::task::AbortHandle>,
    /// Increments on every start, so a stream from an earlier attempt is ignored.
    run: u64,
}

impl Download {
    fn is_active(&self) -> bool {
        self.state == State::Running
    }

    fn fraction(&self) -> Option<f32> {
        (self.total > 0).then(|| (self.completed as f64 / self.total as f64).min(1.0) as f32)
    }

    fn remaining(&self) -> Option<Duration> {
        (self.bytes_per_second > 1.0 && self.total > self.completed)
            .then(|| Duration::from_secs_f64((self.total - self.completed) as f64 / self.bytes_per_second))
    }

    fn reset(&mut self) {
        self.state = State::Running;
        self.status.clear();
        self.layers.clear();
        self.total = 0;
        self.completed = 0;
        self.bytes_per_second = 0.0;
        self.samples.clear();
        self.last_publish = None;
        self.started = Instant::now();
        self.finished = None;
        self.saw_success = false;
        self.cancel_requested = false;
        self.run += 1;
    }

    /// Applies an event; returns whether the interface should be updated.
    fn apply(&mut self, event: &ProgressEvent) -> bool {
        let now = Instant::now();
        let mut status_changed = false;
        if let Some(status) = &event.status
            && *status != self.status
        {
            self.status = status.clone();
            status_changed = true;
            if status == "success" {
                self.saw_success = true;
            }
        }
        if let (Some(digest), Some(total)) = (&event.digest, event.total)
            && total > 0
        {
            let previous = self.layers.get(digest).map_or(0, |layer| layer.1);
            self.layers.insert(digest.clone(), (total, event.completed.unwrap_or(previous).min(total)));
        }
        // Pull events arrive many times per second: publish about 6 times per second.
        if !status_changed && self.last_publish.is_some_and(|last| now.duration_since(last) < Duration::from_millis(160)) {
            return false;
        }
        self.last_publish = Some(now);
        self.total = self.layers.values().map(|layer| layer.0).sum();
        self.completed = self.layers.values().map(|layer| layer.1).sum();
        self.samples.push_back((now, self.completed));
        while self.samples.front().is_some_and(|(date, _)| now.duration_since(*date) > Duration::from_secs(4)) {
            self.samples.pop_front();
        }
        if let Some((first_date, first_bytes)) = self.samples.front() {
            let elapsed = now.duration_since(*first_date).as_secs_f64();
            if elapsed > 0.5 {
                self.bytes_per_second = (self.completed.saturating_sub(*first_bytes)) as f64 / elapsed;
            }
        }
        true
    }

    fn finish(&mut self, state: State) {
        if state == State::Completed {
            self.completed = self.total;
        }
        self.state = state;
        self.bytes_per_second = 0.0;
        self.finished = Some(Instant::now());
        self.abort = None;
    }

    fn detail(&self, text: &Text) -> String {
        match &self.state {
            State::Running => {
                let status = if self.status.is_empty() { "pulling manifest" } else { &self.status };
                let mut parts = vec![text.progress_status(status)];
                if self.total > 0 {
                    parts.push(text.of(&text.bytes(self.completed), &text.bytes(self.total)));
                }
                if self.bytes_per_second > 0.0 {
                    parts.push(format!("{}/s", text.bytes(self.bytes_per_second as u64)));
                }
                if let Some(remaining) = self.remaining() {
                    parts.push(text.remaining(Duration::from_secs(remaining.as_secs().max(1))));
                }
                parts.join(" · ")
            }
            State::Completed => {
                let elapsed = self.finished.unwrap_or_else(Instant::now).duration_since(self.started);
                let completed = text.completed_in(Duration::from_secs(elapsed.as_secs().max(1)));
                if self.total > 0 { format!("{completed} · {}", text.bytes(self.total)) } else { completed }
            }
            State::Failed(message) => message.clone(),
            State::Cancelled => text.cancelled(),
        }
    }
}

#[derive(Default)]
pub struct Downloads {
    items: Vec<Download>,
    next_id: i32,
}

impl Downloads {
    fn get_mut(&mut self, id: i32) -> Option<&mut Download> {
        self.items.iter_mut().find(|d| d.id == id)
    }

    fn active(&self, name: &str, server_id: &str) -> Option<&Download> {
        let target = canonical(name);
        self.items.iter().find(|d| d.is_active() && d.server_id == server_id && canonical(&d.name) == target)
    }

    /// For a running pull of `name` on the server: `Some(progress)`, where the progress
    /// is `None` while the size is still unknown.
    pub fn active_progress(&self, name: &str, server_id: &str) -> Option<Option<f32>> {
        self.active(name, server_id).map(Download::fraction)
    }

    pub fn active_count(&self) -> usize {
        self.items.iter().filter(|d| d.is_active()).count()
    }

    /// Names and progress of the running pulls, for the tray menu.
    pub fn active_summary(&self) -> Vec<(String, Option<f32>)> {
        self.items.iter().filter(|d| d.is_active()).map(|d| (d.name.clone(), d.fraction())).collect()
    }
}

/// Starts pulling `name` on the current server, unless it is already being pulled.
pub fn pull(app: &Rc<App>, name: &str) {
    let name = name.trim();
    if ModelReference::parse(name).is_none() {
        return;
    }
    let (server, client) = {
        let state = app.state.borrow();
        (state.settings.current_server().clone(), state.client.clone())
    };
    if app.downloads.borrow().active(name, &server.id).is_some() {
        return;
    }
    let id = {
        let mut downloads = app.downloads.borrow_mut();
        downloads.next_id += 1;
        let id = downloads.next_id;
        downloads.items.insert(
            0,
            Download {
                id,
                name: name.to_owned(),
                server_id: server.id.clone(),
                server_name: app.server_label(&server),
                client,
                state: State::Running,
                status: String::new(),
                layers: HashMap::new(),
                total: 0,
                completed: 0,
                bytes_per_second: 0.0,
                samples: VecDeque::new(),
                last_publish: None,
                started: Instant::now(),
                finished: None,
                saw_success: false,
                cancel_requested: false,
                abort: None,
                run: 0,
            },
        );
        id
    };
    start(app, id);
}

fn start(app: &Rc<App>, id: i32) {
    let (client, name, run) = {
        let mut downloads = app.downloads.borrow_mut();
        let Some(download) = downloads.get_mut(id) else { return };
        download.reset();
        (download.client.clone(), download.name.clone(), download.run)
    };
    let mut stream = {
        let _runtime = app.rt.enter();
        client.pull(&name)
    };
    if let Some(download) = app.downloads.borrow_mut().get_mut(id) {
        download.abort = Some(stream.abort_handle());
    }
    sync(app);
    let app = app.clone();
    let _ = slint::spawn_local(async move {
        let mut failure = None;
        while let Some(event) = stream.next().await {
            match event {
                Ok(event) => {
                    let publish = app.downloads.borrow_mut().get_mut(id).filter(|d| d.run == run).is_some_and(|d| d.apply(&event));
                    if publish {
                        sync(&app);
                    }
                }
                Err(error) => {
                    failure = Some(app.text.api_error(&error));
                    break;
                }
            }
        }
        let completed_here = {
            let mut downloads = app.downloads.borrow_mut();
            let Some(download) = downloads.get_mut(id).filter(|d| d.run == run) else { return };
            let outcome = if download.cancel_requested {
                State::Cancelled
            } else if download.saw_success {
                State::Completed
            } else {
                State::Failed(failure.unwrap_or_else(|| app.text.incomplete()))
            };
            let completed = outcome == State::Completed;
            download.finish(outcome);
            completed && download.server_id == app.state.borrow().settings.selected_server
        };
        sync(&app);
        if completed_here {
            {
                let mut state = app.state.borrow_mut();
                let target = canonical(&name);
                state.updates.retain(|model, _| canonical(model) != target);
            }
            app.refresh_models().await;
        }
    });
}

fn cancel(download: &mut Download) {
    if download.is_active() {
        download.cancel_requested = true;
        if let Some(abort) = &download.abort {
            abort.abort();
        }
    }
}

pub fn bind(app: &Rc<App>, api: &Api) {
    api.on_cancel_pull({
        let app = Rc::downgrade(app);
        move |name| {
            let Some(app) = app.upgrade() else { return };
            let server = app.state.borrow().settings.selected_server.clone();
            let target = canonical(&name);
            let mut downloads = app.downloads.borrow_mut();
            if let Some(download) = downloads.items.iter_mut().find(|d| d.is_active() && d.server_id == server && canonical(&d.name) == target) {
                cancel(download);
            }
        }
    });
    api.on_cancel_download({
        let app = Rc::downgrade(app);
        move |id| {
            let Some(app) = app.upgrade() else { return };
            if let Some(download) = app.downloads.borrow_mut().get_mut(id) {
                cancel(download);
            }
        }
    });
    api.on_retry_download({
        let app = Rc::downgrade(app);
        move |id| {
            let Some(app) = app.upgrade() else { return };
            let can_retry = app.downloads.borrow_mut().get_mut(id).is_some_and(|d| !d.is_active());
            if can_retry {
                start(&app, id);
            }
        }
    });
    api.on_remove_download({
        let app = Rc::downgrade(app);
        move |id| {
            let Some(app) = app.upgrade() else { return };
            {
                let mut downloads = app.downloads.borrow_mut();
                if let Some(abort) = downloads.get_mut(id).and_then(|d| d.abort.take()) {
                    abort.abort();
                }
                downloads.items.retain(|d| d.id != id);
            }
            sync(&app);
        }
    });
    api.on_reveal_download({
        let app = Rc::downgrade(app);
        move |id| {
            let Some(app) = app.upgrade() else { return };
            let name = app.downloads.borrow_mut().get_mut(id).map(|d| d.name.clone());
            if let Some(name) = name {
                app.reveal(&name);
            }
        }
    });
    api.on_clear_finished({
        let app = Rc::downgrade(app);
        move || {
            let Some(app) = app.upgrade() else { return };
            app.downloads.borrow_mut().items.retain(Download::is_active);
            sync(&app);
        }
    });
}

pub fn percent(fraction: f32, text: &Text) -> String {
    let value = (fraction * 100.0).floor() as i32;
    match text.lang {
        crate::api::format::Lang::Fr => format!("{value}\u{202f}%"),
        crate::api::format::Lang::En => format!("{value}%"),
    }
}

/// Updates the Downloads page and everything that shows download progress.
pub fn sync(app: &Rc<App>) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    {
        let downloads = app.downloads.borrow();
        let state = app.state.borrow();
        let several_servers = state.settings.servers.len() > 1;
        let rows: Vec<DownloadRow> = downloads
            .items
            .iter()
            .map(|d| DownloadRow {
                id: d.id,
                name: d.name.clone().into(),
                server: if several_servers { d.server_name.clone().into() } else { SharedString::new() },
                state: match d.state {
                    State::Running => 0,
                    State::Completed => 1,
                    State::Failed(_) => 2,
                    State::Cancelled => 3,
                },
                detail: d.detail(&app.text).into(),
                percent: d.fraction().filter(|_| d.is_active()).map(|f| percent(f, &app.text)).unwrap_or_default().into(),
                progress: d.fraction().unwrap_or(-1.0),
                can_reveal: d.server_id == state.settings.selected_server,
            })
            .collect();
        if let Some(model) = update_rows(api.get_downloads(), rows, |a, b| a == b) {
            api.set_downloads(model);
        }
        api.set_active_downloads(downloads.active_count() as i32);
        api.set_has_finished_downloads(downloads.items.iter().any(|d| !d.is_active()));
    }
    app.sync_models();
    app.sync_detail();
    super::library::sync_tags(app);
    super::tray::sync(app);
}
