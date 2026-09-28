//! Tray icon: loaded models, downloads and quick actions.

use std::rc::Rc;

use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

use super::{App, chat};
use crate::{Api, Tray, TrayModel};

pub fn create(app: &Rc<App>) {
    let tray = match Tray::new() {
        Ok(tray) => tray,
        Err(error) => {
            eprintln!("Tray icon unavailable: {error}");
            return;
        }
    };
    tray.set_monochrome(cfg!(target_os = "macos"));
    tray.on_open_window({
        let app = Rc::downgrade(app);
        move || {
            if let Some(app) = app.upgrade() {
                app.show_window();
            }
        }
    });
    tray.on_open_section({
        let app = Rc::downgrade(app);
        move |section| {
            if let Some(app) = app.upgrade() {
                app.ui().global::<Api>().set_section(section);
                app.show_window();
            }
        }
    });
    tray.on_chat({
        let app = Rc::downgrade(app);
        move |name| {
            if let Some(app) = app.upgrade() {
                chat::open_with(&app, &name);
                app.show_window();
            }
        }
    });
    tray.on_unload({
        let app = Rc::downgrade(app);
        move |name| {
            if let Some(app) = app.upgrade() {
                app.unload(name.to_string());
            }
        }
    });
    tray.on_unload_all({
        let app = Rc::downgrade(app);
        move || {
            if let Some(app) = app.upgrade() {
                app.ui().global::<Api>().invoke_unload_all();
            }
        }
    });
    tray.on_quit(|| {
        let _ = slint::quit_event_loop();
    });
    let visible = app.state.borrow().settings.show_tray_icon;
    *app.tray.borrow_mut() = Some(tray);
    sync(app);
    set_visible(app, visible);
}

pub fn set_visible(app: &Rc<App>, visible: bool) {
    if let Some(tray) = app.tray.borrow().as_ref() {
        let _ = if visible { tray.show() } else { tray.hide() };
    }
}

pub fn sync(app: &Rc<App>) {
    let tray_ref = app.tray.borrow();
    let Some(tray) = tray_ref.as_ref() else { return };
    let ui = app.ui();
    let api = ui.global::<Api>();
    // Called every second while models are loaded: the native menu is only rebuilt when its content changes.
    if tray.get_server() != api.get_server_name() {
        tray.set_server(api.get_server_name());
    }
    if tray.get_status() != api.get_connection_text() {
        tray.set_status(api.get_connection_text());
    }
    let state = app.state.borrow();
    let models: Vec<TrayModel> = state
        .running
        .iter()
        .map(|m| TrayModel {
            name: m.name.clone().into(),
            label: format!("{} — {}", m.name, app.text.bytes(m.size)).into(),
            details: match m.expires_at.filter(|_| !m.stays_loaded()) {
                Some(expires) => {
                    format!("{} · {}", m.processor_label(), app.text.unloads_at(&expires.with_timezone(&chrono::Local).format("%H:%M").to_string()))
                }
                None => m.processor_label(),
            }
            .into(),
            can_chat: state.models.iter().any(|i| i.name == m.name && i.can_chat()),
        })
        .collect();
    let current = tray.get_models();
    if current.row_count() != models.len() || current.iter().zip(&models).any(|(a, b)| a != *b) {
        tray.set_models(ModelRc::new(VecModel::from(models)));
    }
    let downloads: Vec<SharedString> = app
        .downloads
        .borrow()
        .active_summary()
        .into_iter()
        .map(|(name, fraction)| match fraction {
            Some(fraction) => format!("{name} — {}", super::downloads::percent(fraction, &app.text)).into(),
            None => name.into(),
        })
        .collect();
    let current = tray.get_downloads();
    if current.row_count() != downloads.len() || current.iter().zip(&downloads).any(|(a, b)| a != *b) {
        tray.set_downloads(ModelRc::new(VecModel::from(downloads)));
    }
}
