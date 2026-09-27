//! Development aid (debug builds only): drives the interface through its own
//! callbacks, for screenshots and manual checks without clicking.
//!
//! `OLLAMA_GUI_SCRIPT="wait:2;select:qwen3:8b;section:4;send:Hello"`, steps run 1.5 s apart.

use std::rc::Rc;
use std::time::Duration;

use slint::ComponentHandle;

use super::App;
use crate::Api;

pub fn run(app: &Rc<App>) {
    let Ok(script) = std::env::var("OLLAMA_GUI_SCRIPT") else { return };
    let steps: Vec<String> = script.split(';').map(str::to_owned).collect();
    let app = app.clone();
    let _ = slint::spawn_local(async move {
        for step in steps {
            let (command, argument) = step.split_once(':').unwrap_or((step.as_str(), ""));
            let pause = if command == "wait" { argument.parse().unwrap_or(1.0) } else { 1.5 };
            app.sleep(Duration::from_secs_f64(pause)).await;
            eprintln!("script: {step}");
            let ui = app.ui();
            let api = ui.global::<Api>();
            match command {
                "section" => api.set_section(argument.parse().unwrap_or(0)),
                "select" => api.invoke_select_model(argument.into()),
                "chat" => api.invoke_chat_with(argument.into()),
                "send" => api.invoke_send_message(argument.into()),
                "load" => api.invoke_load_model(argument.into()),
                "pull" => api.invoke_pull(argument.into()),
                "delete" => api.invoke_delete_model(argument.into()),
                "unload" => api.invoke_unload_model(argument.into()),
                "dialog" => {
                    let (kind, target) = argument.split_once(':').unwrap_or((argument, ""));
                    api.invoke_open_dialog(kind.parse().unwrap_or(0), target.into());
                }
                "search" => {
                    api.set_library_query(argument.into());
                    api.invoke_library_search();
                }
                "think" => api.set_thinking_enabled(argument != "0"),
                "hide" => {
                    let _ = ui.hide();
                }
                "dark" => ui.global::<crate::Palette>().set_color_scheme(slint::language::ColorScheme::Dark),
                "quit" => {
                    let _ = slint::quit_event_loop();
                }
                _ => {}
            }
        }
    });
}
