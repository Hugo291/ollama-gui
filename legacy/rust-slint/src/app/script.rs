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
        // Off screen: a scripted run must not cover the screen of someone using the computer,
        // nor receive their clicks. Snapshots are rendered by the app, they still work.
        {
            use slint::winit_030::WinitWindowAccessor;
            let ui = app.ui();
            ui.window().with_winit_window(|window| {
                window.set_outer_position(slint::winit_030::winit::dpi::PhysicalPosition::new(-20000, 400));
            });
        }
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
                // `copy:source>destination`, `rename:source>destination`, `create:base>name>system prompt`
                "copy" | "rename" => {
                    let (source, destination) = argument.split_once('>').unwrap_or((argument, ""));
                    api.invoke_copy_model(source.into(), destination.into(), command == "rename");
                }
                "create" => {
                    let mut parts = argument.splitn(3, '>');
                    let (base, name, system) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
                    api.invoke_create_model(base.into(), name.into(), system.into(), 0.3, 4096, -1.0, -1);
                }
                "filter" => {
                    api.set_model_filter(argument.parse().unwrap_or(0));
                    api.invoke_models_query_changed();
                }
                "sort" => {
                    let (column, ascending) = argument.split_once(',').unwrap_or((argument, "1"));
                    api.set_sort_column(column.parse().unwrap_or(0));
                    api.set_sort_ascending(ascending != "0");
                    api.invoke_models_query_changed();
                }
                "find" => {
                    api.set_model_search(argument.into());
                    api.invoke_models_query_changed();
                }
                "move" => api.invoke_move_selection(argument.parse().unwrap_or(1), false),
                // Selection: `click:name`, `click:name:shift`, `click:name:toggle`, `select-all`.
                "click" => {
                    let (name, modifier) = match argument.rsplit_once(':') {
                        Some((name, modifier @ ("shift" | "toggle"))) => (name, modifier),
                        _ => (argument, ""),
                    };
                    api.invoke_click_model(name.into(), modifier == "shift", modifier == "toggle");
                }
                "select-all" => api.invoke_select_all_models(),
                "delete-selection" => api.invoke_delete_selection(),
                "sidebar" => api.set_sidebar_width(argument.parse().unwrap_or(232.0)),
                "inspector" => api.set_inspector_width(argument.parse().unwrap_or(360.0)),
                "layout-changed" => api.invoke_layout_changed(),
                "check-updates" => api.invoke_check_updates(),
                "add-server" => api.invoke_add_server(),
                // Servers by position in the list: `server:1`, `remove-server:1`, `save-server:1>name>address`.
                "server" | "remove-server" | "save-server" => {
                    let (index, rest) = argument.split_once('>').unwrap_or((argument, ""));
                    let servers = api.get_server_list();
                    if let Some(server) = index.parse().ok().and_then(|i: usize| slint::Model::row_data(&servers, i)) {
                        match command {
                            "server" => api.invoke_select_server(server.id),
                            "remove-server" => api.invoke_remove_server(server.id),
                            _ => {
                                let (name, address) = rest.split_once('>').unwrap_or((rest, ""));
                                api.invoke_save_server(server.id, name.into(), address.into());
                            }
                        }
                    }
                }
                "test-server" => api.invoke_test_server(argument.into()),
                "theme" => {
                    api.set_theme_index(argument.parse().unwrap_or(0));
                    api.invoke_settings_changed();
                }
                "keep-alive" => {
                    api.set_keep_alive_index(argument.parse().unwrap_or(1));
                    api.invoke_settings_changed();
                }
                "close-dialog" => api.set_dialog(0),
                "size" => {
                    let (width, height) = argument.split_once(',').unwrap_or(("1320", "820"));
                    ui.window().set_size(slint::LogicalSize::new(width.parse().unwrap_or(1320.0), height.parse().unwrap_or(820.0)));
                }
                "draft" => api.set_chat_draft(argument.replace("\\n", "\n").into()),
                "more" => api.invoke_library_load_more(),
                "print" => {
                    use slint::Model;
                    eprintln!(
                        "state: section={} dialog={} selected={} count={} index={} models={} library={} more={} chat-model={} messages={} draft={:?} theme-dark={} servers={} sidebar={} inspector={} dialog-title={:?}",
                        api.get_section(),
                        api.get_dialog(),
                        api.get_selected_model(),
                        api.get_selected_count(),
                        api.get_selected_index(),
                        api.get_models().row_count(),
                        api.get_library_results().row_count(),
                        api.get_library_has_more(),
                        api.get_chat_model(),
                        api.get_messages().row_count(),
                        api.get_chat_draft(),
                        ui.global::<crate::Theme>().get_dark(),
                        api.get_server_list().row_count(),
                        api.get_sidebar_width(),
                        api.get_inspector_width(),
                        api.get_dialog_title(),
                    );
                }
                // Keyboard: `key:return`, `key:escape`, `key:up`, `key:a`; `ctrl:1` holds ⌘ (Ctrl on Windows).
                // Mouse: `drag:x1,y1,x2,y2` (dividers), `dblclick:x,y`, `rclick:x,y`, in logical pixels.
                "rclick" => {
                    use slint::platform::{PointerEventButton, WindowEvent};
                    let numbers: Vec<f32> = argument.split(',').filter_map(|n| n.trim().parse().ok()).collect();
                    let position = slint::LogicalPosition::new(numbers.first().copied().unwrap_or(0.0), numbers.get(1).copied().unwrap_or(0.0));
                    let window = ui.window();
                    let _ = window.dispatch_event_with_result(WindowEvent::PointerMoved { position });
                    let _ = window.dispatch_event_with_result(WindowEvent::PointerPressed { position, button: PointerEventButton::Right });
                    let _ = window.dispatch_event_with_result(WindowEvent::PointerReleased { position, button: PointerEventButton::Right });
                }
                "drag" | "dblclick" => {
                    use slint::platform::{PointerEventButton, WindowEvent};
                    let numbers: Vec<f32> = argument.split(',').filter_map(|n| n.trim().parse().ok()).collect();
                    let window = ui.window();
                    let point = |i: usize| slint::LogicalPosition::new(numbers.get(i).copied().unwrap_or(0.0), numbers.get(i + 1).copied().unwrap_or(0.0));
                    let press = |position| {
                        let _ = window.dispatch_event_with_result(WindowEvent::PointerMoved { position });
                        let _ = window.dispatch_event_with_result(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
                    };
                    let release = |position| {
                        let _ = window.dispatch_event_with_result(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
                    };
                    if command == "drag" {
                        let (start, end) = (point(0), point(2));
                        press(start);
                        for step in 1..=10 {
                            let t = step as f32 / 10.0;
                            let position = slint::LogicalPosition::new(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t);
                            let _ = window.dispatch_event_with_result(WindowEvent::PointerMoved { position });
                        }
                        release(end);
                    } else {
                        let position = point(0);
                        press(position);
                        release(position);
                        press(position);
                        release(position);
                    }
                }
                "key" | "ctrl" | "shift" => {
                    use slint::platform::{Key, WindowEvent};
                    let text: slint::SharedString = match argument {
                        "return" => Key::Return.into(),
                        "escape" => Key::Escape.into(),
                        "up" => Key::UpArrow.into(),
                        "down" => Key::DownArrow.into(),
                        "delete" => Key::Delete.into(),
                        "backspace" => Key::Backspace.into(),
                        "shift-return" => Key::Return.into(),
                        other => other.into(),
                    };
                    let window = ui.window();
                    let modifier: Option<slint::SharedString> = match command {
                        "ctrl" => Some(Key::Control.into()),
                        "shift" => Some(Key::Shift.into()),
                        _ if argument == "shift-return" => Some(Key::Shift.into()),
                        _ => None,
                    };
                    if let Some(modifier) = &modifier {
                        let _ = window.dispatch_event_with_result(WindowEvent::KeyPressed { text: modifier.clone() });
                    }
                    let _ = window.dispatch_event_with_result(WindowEvent::KeyPressed { text: text.clone() });
                    let _ = window.dispatch_event_with_result(WindowEvent::KeyReleased { text });
                    if let Some(modifier) = modifier {
                        let _ = window.dispatch_event_with_result(WindowEvent::KeyReleased { text: modifier });
                    }
                }
                // Snapshot of the window, rendered by the app itself (works with the screen locked):
                // saved as $OLLAMA_GUI_SHOTS/<name>.png.
                "shot" => {
                    let directory = std::env::var("OLLAMA_GUI_SHOTS").unwrap_or_else(|_| ".".into());
                    match ui.window().take_snapshot() {
                        Ok(buffer) => {
                            let path = std::path::Path::new(&directory).join(format!("{argument}.png"));
                            let saved = image::save_buffer(&path, buffer.as_bytes(), buffer.width(), buffer.height(), image::ExtendedColorType::Rgba8);
                            eprintln!("shot {argument}: {}", if saved.is_ok() { "ok" } else { "failed" });
                        }
                        Err(error) => eprintln!("shot {argument}: {error}"),
                    }
                }
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
