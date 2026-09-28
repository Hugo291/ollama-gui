//! The Discover page: search ollama.com and pull tags.

use std::rc::Rc;
use std::time::Duration;

use slint::{ComponentHandle, ModelRc, SharedString, VecModel};

use super::{App, same_strings, update_rows};
use crate::api::library::{self as ollama_library, LibraryModel, LibrarySort, LibraryTag};
use crate::api::reference::canonical;
use crate::{Api, LibraryDetail, LibraryRow, TagRow};

#[derive(Default)]
pub struct Library {
    results: Vec<LibraryModel>,
    searched: bool,
    searching: bool,
    search_generation: u64,
    tags: Vec<LibraryTag>,
    tags_for: String,
    tags_generation: u64,
    debounce: slint::Timer,
    /// Last page loaded, and whether ollama.com has more (it pages by 20).
    page: u32,
    has_more: bool,
    loading_more: bool,
}

/// Search parameters, read from the interface.
fn search_query(api: &Api) -> (String, Option<&'static str>, LibrarySort) {
    let query = api.get_library_query().trim().to_owned();
    let capability = match api.get_library_filter() {
        1 => Some("vision"),
        2 => Some("tools"),
        3 => Some("thinking"),
        4 => Some("embedding"),
        5 => Some("cloud"),
        _ => None,
    };
    let sort = if api.get_library_sort() == 1 { LibrarySort::Newest } else { LibrarySort::Popular };
    (query, capability, sort)
}

fn strings(values: &[String]) -> ModelRc<SharedString> {
    ModelRc::new(VecModel::from(values.iter().map(SharedString::from).collect::<Vec<_>>()))
}

pub fn bind(app: &Rc<App>, api: &Api) {
    api.on_library_search({
        let app = Rc::downgrade(app);
        move || {
            let Some(app) = app.upgrade() else { return };
            // Typing triggers a search on every key: wait for a short pause.
            let weak = Rc::downgrade(&app);
            app.library.borrow().debounce.start(slint::TimerMode::SingleShot, Duration::from_millis(300), move || {
                if let Some(app) = weak.upgrade() {
                    search(&app);
                }
            });
        }
    });
    api.on_library_load_more({
        let app = Rc::downgrade(app);
        move || {
            if let Some(app) = app.upgrade() {
                load_more(&app);
            }
        }
    });
    api.on_select_library({
        let app = Rc::downgrade(app);
        move |path| {
            let Some(app) = app.upgrade() else { return };
            select(&app, path.to_string());
        }
    });
    api.on_tag_filter_changed({
        let app = Rc::downgrade(app);
        move || {
            if let Some(app) = app.upgrade() {
                sync_tags(&app);
            }
        }
    });
    api.on_reload_tags({
        let app = Rc::downgrade(app);
        move || {
            if let Some(app) = app.upgrade() {
                let path = app.ui().global::<Api>().get_library_selected().to_string();
                load_tags(&app, path);
            }
        }
    });
}

/// Runs the first search when Discover is opened.
pub fn ensure_loaded(app: &Rc<App>) {
    let pending = {
        let library = app.library.borrow();
        !library.searched && !library.searching
    };
    if pending {
        search(app);
    }
}

fn search(app: &Rc<App>) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    let (query, capability, sort) = search_query(&api);
    let generation = {
        let mut library = app.library.borrow_mut();
        library.search_generation += 1;
        library.searching = true;
        library.loading_more = false;
        library.search_generation
    };
    api.set_library_loading_more(false);
    api.set_library_loading(true);
    api.set_library_error(SharedString::new());
    let http = app.http.clone();
    let app = app.clone();
    let _ = slint::spawn_local(async move {
        let result = app.io(async move { ollama_library::search(&http, &query, capability, sort, 1).await }).await;
        if app.library.borrow().search_generation != generation {
            return;
        }
        let ui = app.ui();
        let api = ui.global::<Api>();
        {
            let mut library = app.library.borrow_mut();
            library.searching = false;
            library.searched = true;
        }
        api.set_library_loading(false);
        match result {
            Some(Ok(page)) => {
                let found = page.models;
                let selected = api.get_library_selected().to_string();
                let keep = found.iter().any(|m| m.path == selected);
                let first = found.first().map(|m| m.path.clone()).unwrap_or_default();
                {
                    let mut library = app.library.borrow_mut();
                    library.results = found;
                    library.page = 1;
                    library.has_more = page.has_more;
                }
                api.set_library_has_more(page.has_more);
                sync(&app);
                if !keep {
                    select(&app, first);
                }
            }
            Some(Err(error)) => {
                {
                    let mut library = app.library.borrow_mut();
                    library.results.clear();
                    library.has_more = false;
                }
                api.set_library_has_more(false);
                api.set_library_error(app.text.api_error(&error).into());
                sync(&app);
                select(&app, String::new());
            }
            None => {}
        }
    });
}

/// Appends the next page of results (the list asks for it when scrolled to the end).
fn load_more(app: &Rc<App>) {
    let (page, generation) = {
        let mut library = app.library.borrow_mut();
        if !library.has_more || library.loading_more || library.searching {
            return;
        }
        library.loading_more = true;
        (library.page + 1, library.search_generation)
    };
    let ui = app.ui();
    let api = ui.global::<Api>();
    api.set_library_loading_more(true);
    let (query, capability, sort) = search_query(&api);
    let http = app.http.clone();
    let app = app.clone();
    let _ = slint::spawn_local(async move {
        let result = app.io(async move { ollama_library::search(&http, &query, capability, sort, page).await }).await;
        // Another search started meanwhile: these results belong to the previous one.
        if app.library.borrow().search_generation != generation {
            return;
        }
        let ui = app.ui();
        let api = ui.global::<Api>();
        {
            let mut library = app.library.borrow_mut();
            library.loading_more = false;
            match result {
                Some(Ok(more)) => {
                    for model in more.models {
                        if !library.results.iter().any(|m| m.path == model.path) {
                            library.results.push(model);
                        }
                    }
                    library.page = page;
                    library.has_more = more.has_more;
                }
                // Not shown as an error: the results already there stay usable.
                _ => library.has_more = false,
            }
            api.set_library_has_more(library.has_more);
        }
        api.set_library_loading_more(false);
        sync(&app);
    });
}

fn select(app: &Rc<App>, path: String) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    let changed = api.get_library_selected() != path.as_str();
    api.set_library_selected(path.clone().into());
    sync(app);
    if changed || app.library.borrow().tags_for != path {
        api.set_tag_filter(SharedString::new());
        load_tags(app, path);
    }
}

fn load_tags(app: &Rc<App>, path: String) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    let model = app.library.borrow().results.iter().find(|m| m.path == path).cloned();
    let generation = {
        let mut library = app.library.borrow_mut();
        library.tags_generation += 1;
        library.tags.clear();
        library.tags_for = path.clone();
        library.tags_generation
    };
    api.set_tags_error(SharedString::new());
    sync_tags(app);
    let Some(model) = model else {
        api.set_tags_loading(false);
        return;
    };
    api.set_tags_loading(true);
    let http = app.http.clone();
    let app = app.clone();
    let _ = slint::spawn_local(async move {
        let result = app.io(async move { ollama_library::tags(&http, &model).await }).await;
        if app.library.borrow().tags_generation != generation {
            return;
        }
        let ui = app.ui();
        let api = ui.global::<Api>();
        api.set_tags_loading(false);
        match result {
            Some(Ok(tags)) => app.library.borrow_mut().tags = tags,
            Some(Err(error)) => api.set_tags_error(app.text.api_error(&error).into()),
            None => {}
        }
        sync_tags(&app);
    });
}

/// Installed models whose name starts with a library model (`qwen3` → `qwen3:8b`).
fn has_installed_tag(app: &App, model: &LibraryModel) -> bool {
    let prefix = format!("{}:", model.pull_name().to_lowercase());
    app.state.borrow().models.iter().any(|m| m.name.to_lowercase().starts_with(&prefix))
}

pub fn sync(app: &Rc<App>) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    let library = app.library.borrow();
    let rows: Vec<LibraryRow> = library
        .results
        .iter()
        .map(|m| LibraryRow {
            path: m.path.clone().into(),
            name: m.name.clone().into(),
            summary: m.summary.clone().into(),
            capabilities: strings(&m.capabilities),
            sizes: strings(&m.sizes),
            pulls: m.pulls.as_deref().map(|pulls| app.text.site_count(pulls)).unwrap_or_default().into(),
            installed: has_installed_tag(app, m),
        })
        .collect();
    let same = |a: &LibraryRow, b: &LibraryRow| {
        LibraryRow { capabilities: b.capabilities.clone(), sizes: b.sizes.clone(), ..a.clone() } == *b
            && same_strings(&a.capabilities, &b.capabilities)
            && same_strings(&a.sizes, &b.sizes)
    };
    if let Some(model) = update_rows(api.get_library_results(), rows, same) {
        api.set_library_results(model);
    }
    let selected = api.get_library_selected();
    match library.results.iter().find(|m| m.path == selected.as_str()) {
        Some(model) => {
            api.set_library_detail(LibraryDetail {
                name: model.name.clone().into(),
                summary: model.summary.clone().into(),
                stats: app.text.library_stats(model.pulls.as_deref(), model.tag_count.as_deref(), model.updated.as_deref()).into(),
                capabilities: strings(&model.capabilities),
                url: model.page_url().into(),
            });
            api.set_has_library_detail(true);
        }
        None => api.set_has_library_detail(false),
    }
}

fn short_context(context: Option<&str>) -> String {
    match context {
        None => "—".into(),
        Some(context) => {
            // ASCII lowercasing keeps byte offsets valid for slicing the original text.
            let lower = context.to_ascii_lowercase();
            match lower.find("context window") {
                Some(start) => format!("{}{}", &context[..start], &context[start + "context window".len()..]).trim().to_owned(),
                None => context.trim().to_owned(),
            }
        }
    }
}

pub fn sync_tags(app: &Rc<App>) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    let filter = api.get_tag_filter().trim().to_lowercase();
    let library = app.library.borrow();
    let state = app.state.borrow();
    let downloads = app.downloads.borrow();
    let server = &state.settings.selected_server;
    let rows: Vec<TagRow> = library
        .tags
        .iter()
        .filter(|tag| filter.is_empty() || tag.name.to_lowercase().contains(&filter) || tag.badges.iter().any(|b| b.to_lowercase().contains(&filter)))
        .map(|tag| {
            let download = downloads.active_progress(&tag.name, server);
            let target = canonical(&tag.name);
            let installed = state.models.iter().any(|m| canonical(&m.name) == target);
            TagRow {
                name: tag.name.clone().into(),
                tag: tag.tag().into(),
                badges: strings(&tag.badges),
                size: tag.size.as_deref().map(|size| app.text.site_size(size)).unwrap_or_else(|| "—".into()).into(),
                context: short_context(tag.context.as_deref()).into(),
                input: tag.input.as_deref().map(|input| app.text.site_input(input)).unwrap_or_else(|| "—".into()).into(),
                state: if download.is_some() {
                    1
                } else if installed {
                    2
                } else {
                    0
                },
                progress: download.flatten().unwrap_or(-1.0),
            }
        })
        .collect();
    let same = |a: &TagRow, b: &TagRow| TagRow { badges: b.badges.clone(), ..a.clone() } == *b && same_strings(&a.badges, &b.badges);
    if let Some(model) = update_rows(api.get_tags(), rows, same) {
        api.set_tags(model);
    }
}
