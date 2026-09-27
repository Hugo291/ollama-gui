//! The Playground: a chat with streamed replies.

use std::rc::Rc;
use std::time::{Duration, Instant};

use base64::Engine;
use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

use super::App;
use super::markdown::{self, Part};
use crate::api::format;
use crate::api::models::{ChatMessage, capability};
use crate::{Api, ChatPart, ChatRow};

/// Context window choices; 0 keeps the model's default.
const CONTEXT_CHOICES: [u64; 8] = [0, 2048, 4096, 8192, 16384, 32768, 65536, 131072];

#[derive(Clone)]
struct Attachment {
    image: slint::Image,
    base64: String,
}

struct Message {
    is_user: bool,
    text: String,
    thinking: String,
    images: Vec<Attachment>,
    model: String,
    streaming: bool,
    error: Option<String>,
    stats: String,
}

impl Message {
    fn row(&self) -> ChatRow {
        let parts: Vec<ChatPart> = if self.is_user {
            Vec::new()
        } else {
            markdown::split(&self.text)
                .into_iter()
                .map(|part| match part {
                    Part::Text(text) => ChatPart { kind: 0, styled: markdown::styled(&text), text: text.into(), language: SharedString::new() },
                    Part::Code { language, text } => ChatPart { kind: 1, styled: Default::default(), text: text.into(), language: language.into() },
                })
                .collect()
        };
        ChatRow {
            is_user: self.is_user,
            text: self.text.clone().into(),
            parts: ModelRc::new(VecModel::from(parts)),
            thinking: self.thinking.clone().into(),
            model: self.model.clone().into(),
            streaming: self.streaming,
            error: self.error.clone().unwrap_or_default().into(),
            stats: self.stats.clone().into(),
            images: ModelRc::new(VecModel::from(self.images.iter().map(|a| a.image.clone()).collect::<Vec<_>>())),
        }
    }
}

pub struct Chat {
    messages: Vec<Message>,
    rows: Rc<VecModel<ChatRow>>,
    attachments: Vec<Attachment>,
    generating: bool,
    abort: Option<tokio::task::AbortHandle>,
    /// Increments when the conversation is cleared, so a late reply is dropped.
    conversation: u64,
}

impl Default for Chat {
    fn default() -> Self {
        Self { messages: Vec::new(), rows: Rc::new(VecModel::default()), attachments: Vec::new(), generating: false, abort: None, conversation: 0 }
    }
}

pub fn bind(app: &Rc<App>, api: &Api) {
    api.set_messages(ModelRc::from(app.chat.borrow().rows.clone()));
    let labels: Vec<SharedString> =
        CONTEXT_CHOICES.iter().map(|value| if *value == 0 { app.text.model_default() } else { app.text.tokens(&format::tokens(*value)) }.into()).collect();
    api.set_context_labels(ModelRc::new(VecModel::from(labels)));
    api.on_send_message({
        let app = Rc::downgrade(app);
        move |text| {
            if let Some(app) = app.upgrade() {
                send(&app, text.trim().to_owned());
            }
        }
    });
    api.on_stop_generating({
        let app = Rc::downgrade(app);
        move || {
            if let Some(app) = app.upgrade()
                && let Some(abort) = app.chat.borrow_mut().abort.take()
            {
                abort.abort();
            }
        }
    });
    api.on_new_conversation({
        let app = Rc::downgrade(app);
        move || {
            let Some(app) = app.upgrade() else { return };
            {
                let mut chat = app.chat.borrow_mut();
                if let Some(abort) = chat.abort.take() {
                    abort.abort();
                }
                chat.conversation += 1;
                chat.generating = false;
                chat.messages.clear();
                chat.rows.set_vec(Vec::new());
            }
            app.ui().global::<Api>().set_generating(false);
        }
    });
    api.on_attach_images({
        let app = Rc::downgrade(app);
        move || {
            if let Some(app) = app.upgrade() {
                attach_images(&app);
            }
        }
    });
    api.on_remove_attachment({
        let app = Rc::downgrade(app);
        move |index| {
            let Some(app) = app.upgrade() else { return };
            {
                let mut chat = app.chat.borrow_mut();
                if index >= 0 && (index as usize) < chat.attachments.len() {
                    chat.attachments.remove(index as usize);
                }
            }
            sync_attachments(&app);
        }
    });
    api.on_chat_model_changed({
        let app = Rc::downgrade(app);
        move || {
            if let Some(app) = app.upgrade() {
                sync_hint(&app);
            }
        }
    });
}

/// Opens the Playground with a model.
pub fn open_with(app: &Rc<App>, name: &str) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    if !app.chat.borrow().generating {
        api.set_chat_model(name.into());
    }
    api.set_section(4);
    sync_hint(app);
}

fn attach_images(app: &Rc<App>) {
    let app = app.clone();
    let _ = slint::spawn_local(async move {
        let Some(files) = rfd::AsyncFileDialog::new().add_filter("Images", &["png", "jpg", "jpeg", "webp"]).pick_files().await else { return };
        // The dialog does not block the window: the model may have changed meanwhile.
        if !app.ui().global::<Api>().get_chat_vision() {
            return;
        }
        for file in files {
            let path = file.path().to_owned();
            let Ok(bytes) = std::fs::read(&path) else { continue };
            let Ok(image) = slint::Image::load_from_path(&path) else { continue };
            let base64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
            app.chat.borrow_mut().attachments.push(Attachment { image, base64 });
        }
        sync_attachments(&app);
    });
}

fn sync_attachments(app: &Rc<App>) {
    let images: Vec<slint::Image> = app.chat.borrow().attachments.iter().map(|a| a.image.clone()).collect();
    app.ui().global::<Api>().set_attachments(ModelRc::new(VecModel::from(images)));
}

fn send(app: &Rc<App>, text: String) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    let model_name = api.get_chat_model().to_string();
    let (client, keep_alive, supports_thinking, supports_vision) = {
        let state = app.state.borrow();
        let model = state.models.iter().find(|m| m.name == model_name);
        (
            state.client.clone(),
            state.settings.keep_alive_seconds,
            model.is_some_and(|m| m.supports(capability::THINKING)),
            model.is_some_and(|m| m.supports(capability::VISION)),
        )
    };
    let (history, conversation, index) = {
        let mut chat = app.chat.borrow_mut();
        let has_images = supports_vision && !chat.attachments.is_empty();
        if chat.generating || model_name.is_empty() || (text.is_empty() && !has_images) {
            return;
        }
        let images = if supports_vision { std::mem::take(&mut chat.attachments) } else { Vec::new() };
        chat.attachments.clear();
        chat.messages.push(Message {
            is_user: true,
            text,
            thinking: String::new(),
            images,
            model: String::new(),
            streaming: false,
            error: None,
            stats: String::new(),
        });

        let mut history = Vec::new();
        let system = api.get_system_prompt().trim().to_owned();
        if !system.is_empty() {
            history.push(ChatMessage { role: "system".into(), content: system, images: Vec::new() });
        }
        for message in &chat.messages {
            if message.error.is_some() || (!message.is_user && message.text.is_empty()) {
                continue;
            }
            history.push(ChatMessage {
                role: if message.is_user { "user" } else { "assistant" }.into(),
                content: message.text.clone(),
                images: message.images.iter().map(|a| a.base64.clone()).collect(),
            });
        }
        chat.messages.push(Message {
            is_user: false,
            text: String::new(),
            thinking: String::new(),
            images: Vec::new(),
            model: model_name.clone(),
            streaming: true,
            error: None,
            stats: String::new(),
        });
        chat.generating = true;
        let count = chat.messages.len();
        let user_row = chat.messages[count - 2].row();
        let reply_row = chat.messages[count - 1].row();
        chat.rows.push(user_row);
        chat.rows.push(reply_row);
        (history, chat.conversation, count - 1)
    };
    api.set_generating(true);
    sync_attachments(app);

    let mut options = serde_json::Map::new();
    if api.get_custom_temperature() {
        options.insert("temperature".into(), serde_json::json!((api.get_temperature() as f64 * 100.0).round() / 100.0));
    }
    if let Some(context) = CONTEXT_CHOICES.get(api.get_context_index().max(0) as usize).filter(|c| **c > 0) {
        options.insert("num_ctx".into(), serde_json::json!(context));
    }
    let think = supports_thinking.then(|| api.get_thinking_enabled());
    let mut stream = {
        let _runtime = app.rt.enter();
        client.chat(&model_name, &history, think, serde_json::Value::Object(options), keep_alive)
    };
    app.chat.borrow_mut().abort = Some(stream.abort_handle());

    let app = app.clone();
    let _ = slint::spawn_local(async move {
        let mut last_publish = Instant::now();
        let mut failure = None;
        while let Some(chunk) = stream.next().await {
            let chunk = match chunk {
                Ok(chunk) => chunk,
                Err(error) => {
                    failure = Some(error.to_string());
                    break;
                }
            };
            let mut chat = app.chat.borrow_mut();
            if chat.conversation != conversation {
                return;
            }
            let message = &mut chat.messages[index];
            message.text.push_str(&chunk.content);
            message.thinking.push_str(&chunk.thinking);
            if chunk.done {
                message.stats = app.text.chat_stats(
                    chunk.tokens_per_second(),
                    chunk.eval_count,
                    chunk.total_duration.map(Duration::from_nanos),
                    chunk.load_duration.map(Duration::from_nanos),
                );
            }
            // Re-render at most 20 times per second: long replies are parsed as a whole.
            if chunk.done || last_publish.elapsed() >= Duration::from_millis(50) {
                last_publish = Instant::now();
                let row = chat.messages[index].row();
                chat.rows.set_row_data(index, row);
            }
        }
        {
            let mut chat = app.chat.borrow_mut();
            if chat.conversation != conversation {
                return;
            }
            let message = &mut chat.messages[index];
            message.streaming = false;
            message.error = failure;
            let row = message.row();
            chat.rows.set_row_data(index, row);
            chat.generating = false;
            chat.abort = None;
        }
        app.ui().global::<Api>().set_generating(false);
        // The model is now in memory.
        app.refresh_running().await;
    });
}

/// Keeps the model list of the composer in sync with the installed models.
pub fn sync_models(app: &Rc<App>) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    let (names, preferred) = {
        let state = app.state.borrow();
        let chat_models: Vec<_> = state.models.iter().filter(|m| m.can_chat()).collect();
        // Default to a model already in memory, then to a local one: cloud models need a sign-in.
        let preferred = chat_models
            .iter()
            .find(|m| !m.is_cloud() && App::is_running(&state, &m.name))
            .or_else(|| chat_models.iter().find(|m| !m.is_cloud()))
            .or(chat_models.first())
            .map(|m| SharedString::from(m.name.as_str()))
            .unwrap_or_default();
        (chat_models.iter().map(|m| SharedString::from(m.name.as_str())).collect::<Vec<_>>(), preferred)
    };
    let current = api.get_chat_model();
    if !app.chat.borrow().generating && !names.contains(&current) {
        api.set_chat_model(preferred);
    }
    let unchanged = {
        let existing = api.get_chat_models();
        existing.row_count() == names.len() && existing.iter().zip(&names).all(|(a, b)| a == *b)
    };
    if !unchanged {
        api.set_chat_models(ModelRc::new(VecModel::from(names)));
    }
    sync_hint(app);
}

/// Hint under the composer and the options the selected model supports.
pub fn sync_hint(app: &Rc<App>) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    let name = api.get_chat_model();
    let state = app.state.borrow();
    let model = state.models.iter().find(|m| m.name == name.as_str());
    let hint = match model {
        None => String::new(),
        Some(model) if model.is_cloud() => app.text.hint_cloud(),
        Some(model) if !App::is_running(&state, &model.name) => app.text.hint_load(state.settings.keep_alive_seconds),
        Some(_) => String::new(),
    };
    api.set_chat_hint(hint.into());
    let vision = model.is_some_and(|m| m.supports(capability::VISION));
    api.set_chat_vision(vision);
    api.set_chat_thinking_supported(model.is_some_and(|m| m.supports(capability::THINKING)));
    drop(state);
    if !vision && !app.chat.borrow().attachments.is_empty() {
        app.chat.borrow_mut().attachments.clear();
        sync_attachments(app);
    }
}

pub fn sync(app: &Rc<App>) {
    sync_models(app);
    sync_attachments(app);
    app.ui().global::<Api>().set_generating(app.chat.borrow().generating);
}
