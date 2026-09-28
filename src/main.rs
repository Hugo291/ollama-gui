// No console window on Windows.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod api;
mod app;
mod settings;

slint::include_modules!();

fn main() -> Result<(), Box<dyn std::error::Error>> {
    slint::BackendSelector::new()
        .backend_name("winit".into())
        .with_winit_window_attributes_hook(|attributes| {
            // Unified title bar on macOS: the sidebar runs under the traffic lights.
            #[cfg(target_os = "macos")]
            let attributes = {
                use slint::winit_030::winit::platform::macos::WindowAttributesExtMacOS;
                attributes.with_titlebar_transparent(true).with_fullsize_content_view(true).with_title_hidden(true)
            };
            // Scripted runs (debug builds): off screen and without the focus, so they neither
            // disturb nor get disturbed by someone using the computer. Snapshots still work.
            #[cfg(debug_assertions)]
            let attributes = if std::env::var_os("OLLAMA_GUI_SCRIPT").is_some() { attributes.with_active(false) } else { attributes };
            attributes
        })
        .select()?;

    // Network I/O runs on a small runtime; the interface stays on the main thread.
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()?;

    let ui = AppWindow::new()?;
    let lang = app::Text::system().lang;
    let _ = slint::select_bundled_translation(if lang == api::format::Lang::Fr { "fr" } else { "en" });

    let app = app::App::new(&ui, runtime.handle().clone());
    app.start();
    ui.show()?;
    // Runs until Quit, or until the window closes while the tray icon is hidden.
    slint::run_event_loop()?;
    drop(app);
    Ok(())
}
