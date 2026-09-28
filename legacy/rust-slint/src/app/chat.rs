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
/// Limits for image attachments: they are sent base64-encoded with every message.
const MAX_ATTACHMENTS: usize = 8;
const MAX_IMAGE_MB: u64 = 20;

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
    /// The rendered reply, updated in place while it streams: the interface keeps its
    /// blocks (and the scroll position inside code blocks) instead of recreating them.
    parts: Rc<VecModel<ChatPart>>,
    image_model: ModelRc<slint::Image>,
}

impl Message {
    fn new(is_user: bool, text: String, images: Vec<Attachment>, model: String) -> Self {
        let image_model = ModelRc::new(VecModel::from(images.iter().map(|a| a.image.clone()).collect::<Vec<_>>()));
        Self {
            is_user,
            text,
            thinking: String::new(),
            images,
            model,
            streaming: !is_user,
            error: None,
            stats: String::new(),
            parts: Rc::new(VecModel::default()),
            image_model,
        }
    }

    /// Renders the reply's Markdown into `parts`, changing only the blocks that differ.
    fn render(&self) {
        if self.is_user {
            return;
        }
        let parts: Vec<ChatPart> = markdown::split(&self.text)
            .into_iter()
            .flat_map(|part| match part {
                Part::Text(text) => markdown::styled(&text)
                    .into_iter()
                    .map(|styled| ChatPart { kind: 0, styled, text: text.clone().into(), language: SharedString::new() })
                    .collect::<Vec<_>>(),
                Part::Code { language, text } => vec![ChatPart { kind: 1, styled: Default::default(), text: text.into(), language: language.into() }],
            })
            .collect();
        let count = parts.len();
        for (index, part) in parts.into_iter().enumerate() {
            if index >= self.parts.row_count() {
                self.parts.push(part);
            } else if self.parts.row_data(index).as_ref() != Some(&part) {
                self.parts.set_row_data(index, part);
            }
        }
        while self.parts.row_count() > count {
            self.parts.remove(self.parts.row_count() - 1);
        }
    }

    fn row(&self) -> ChatRow {
        self.render();
        ChatRow {
            is_user: self.is_user,
            text: self.text.clone().into(),
            parts: ModelRc::from(self.parts.clone()),
            thinking: self.thinking.clone().into(),
            model: self.model.clone().into(),
            streaming: self.streaming,
            error: self.error.clone().unwrap_or_default().into(),
            stats: self.stats.clone().into(),
            images: self.image_model.clone(),
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
/// Selects a chat model, with the dropdown's position in step with the list.
fn set_chat_model(api: &Api, name: SharedString) {
    let index = api.get_chat_models().iter().position(|model| model == name).unwrap_or(0);
    api.set_chat_model_index(index as i32);
    api.set_chat_model(name);
}

pub fn open_with(app: &Rc<App>, name: &str) {
    let ui = app.ui();
    let api = ui.global::<Api>();
    if !app.chat.borrow().generating {
        set_chat_model(&api, name.into());
    }
    api.set_section(4);
    sync_hint(app);
}

fn attach_images(app: &Rc<App>) {
    let app = app.clone();
    let _ = slint::spawn_local(async move {
        let Some(files) = rfd::AsyncFileDialog::new().add_filter("Images", &["png", "jpg", "jpeg"]).pick_files().await else { return };
        // The dialog does not block the window: the model may have changed meanwhile.
        if !app.ui().global::<Api>().get_chat_vision() {
            return;
        }
        let mut problems = Vec::new();
        for file in files {
            if app.chat.borrow().attachments.len() >= MAX_ATTACHMENTS {
                problems.push(app.text.too_many_images(MAX_ATTACHMENTS));
                break;
            }
            let path = file.path().to_owned();
            let name = file.file_name();
            // Reading and encoding run off the interface thread: photos can be large.
            let read_path = path.clone();
            let encoded = app
                .io(async move {
                    let size = std::fs::metadata(&read_path).map(|m| m.len()).unwrap_or(0);
                    if size > MAX_IMAGE_MB * 1_000_000 {
                        return Err(true);
                    }
                    std::fs::read(&read_path).map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes)).map_err(|_| false)
                })
                .await;
            let base64 = match encoded {
                Some(Ok(base64)) => base64,
                Some(Err(true)) => {
                    problems.push(app.text.image_too_large(&name, MAX_IMAGE_MB));
                    continue;
                }
                _ => {
                    problems.push(app.text.image_unreadable(&name));
                    continue;
                }
            };
            let Ok(image) = slint::Image::load_from_path(&path) else {
                problems.push(app.text.image_unreadable(&name));
                continue;
            };
            app.chat.borrow_mut().attachments.push(Attachment { image, base64 });
        }
        sync_attachments(&app);
        if !problems.is_empty() {
            app.toast(app.text.images_not_attached(), problems.join("\n"));
        }
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
        chat.messages.push(Message::new(true, text, images, String::new()));

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
        chat.messages.push(Message::new(false, String::new(), Vec::new(), model_name.clone()));
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
                    failure = Some(app.text.api_error(&error));
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
    // Read before replacing the list: the dropdown then selects by position.
    let current = api.get_chat_model();
    let unchanged = {
        let existing = api.get_chat_models();
        existing.row_count() == names.len() && existing.iter().zip(&names).all(|(a, b)| a == *b)
    };
    if !unchanged {
        api.set_chat_models(ModelRc::new(VecModel::from(names.clone())));
    }
    // Keep the chosen model (it may have moved in the list), or pick another one if it is gone.
    let chosen = if app.chat.borrow().generating || names.contains(&current) { current } else { preferred };
    set_chat_model(&api, chosen);
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
