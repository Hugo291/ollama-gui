//! Client for the Ollama REST API (https://docs.ollama.com/api).

use std::time::Duration;

use futures_util::StreamExt;
use reqwest::{Method, Url};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::models::{ChatChunk, ChatMessage, ModelInfo, OllamaModel, ProgressEvent, RunningModel};

pub const DEFAULT_PORT: u16 = 11434;

#[derive(Debug, Clone, PartialEq)]
pub enum ApiError {
    /// The server couldn't be reached or the connection broke.
    Network(String),
    /// The server answered with an error (`{"error": "…"}` or a failing status).
    Server(String),
    /// The response wasn't what the API documents.
    Unexpected(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Network(message) | ApiError::Server(message) | ApiError::Unexpected(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for ApiError {}

impl From<reqwest::Error> for ApiError {
    fn from(error: reqwest::Error) -> Self {
        // Keep the innermost cause: "error sending request" alone says nothing.
        let mut message = error.to_string();
        let mut source = std::error::Error::source(&error);
        while let Some(cause) = source {
            message = cause.to_string();
            source = cause.source();
        }
        if error.is_decode() { ApiError::Unexpected(message) } else { ApiError::Network(message) }
    }
}

pub type ApiResult<T> = Result<T, ApiError>;

/// Turns a user supplied address (`localhost`, `192.168.1.20:11434`, `https://ollama.example.com`)
/// into a base URL. Without a port, plain HTTP uses Ollama's default port 11434.
pub fn parse_address(input: &str) -> Option<Url> {
    let text = input.trim();
    if text.is_empty() || text.contains(char::is_whitespace) {
        return None;
    }
    let with_scheme = match text.split_once("://") {
        Some((scheme, _)) if scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https") => text.to_owned(),
        Some(_) => return None,
        None => format!("http://{text}"),
    };
    let mut url = Url::parse(&with_scheme).ok()?;
    if url.host_str().is_none_or(str::is_empty) {
        return None;
    }
    if url.port().is_none() && url.scheme() == "http" {
        url.set_port(Some(DEFAULT_PORT)).ok()?;
    }
    // 0.0.0.0 is a bind address; connect through the loopback interface instead.
    if url.host_str() == Some("0.0.0.0") {
        url.set_host(Some("127.0.0.1")).ok()?;
    }
    let path = url.path().trim_end_matches('/').to_owned();
    url.set_path(&path);
    url.set_query(None);
    url.set_fragment(None);
    Some(url)
}

/// Canonical display form of a base URL (no trailing slash).
pub fn display_url(url: &Url) -> String {
    url.as_str().trim_end_matches('/').to_owned()
}

/// A running stream (pull, create, chat). Dropping the handle, or aborting
/// its [`StreamHandle::abort_handle`], stops the request right away.
pub struct StreamHandle<T> {
    events: mpsc::Receiver<ApiResult<T>>,
    task: tokio::task::AbortHandle,
}

impl<T> StreamHandle<T> {
    /// Next event, or `None` once the stream is over.
    pub async fn next(&mut self) -> Option<ApiResult<T>> {
        self.events.recv().await
    }

    /// A handle to abort the request from elsewhere.
    pub fn abort_handle(&self) -> tokio::task::AbortHandle {
        self.task.clone()
    }
}

impl<T> Drop for StreamHandle<T> {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[derive(Clone)]
pub struct OllamaClient {
    base: Url,
    http: reqwest::Client,
}

impl OllamaClient {
    pub fn new(base: Url) -> Self {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .user_agent(concat!("OllamaGUI/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("HTTP client");
        Self { base, http }
    }

    fn url(&self, path: &str) -> Url {
        let mut url = self.base.clone();
        let base_path = url.path().trim_end_matches('/').to_owned();
        url.set_path(&format!("{base_path}/{path}"));
        url
    }

    async fn request(&self, method: Method, path: &str, body: Option<Value>, timeout: Duration) -> ApiResult<Value> {
        let mut request = self.http.request(method, self.url(path)).timeout(timeout);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await?;
        let status = response.status();
        let text = response.text().await?;
        if !status.is_success() {
            return Err(ApiError::Server(error_message(&text).unwrap_or_else(|| format!("HTTP {status}"))));
        }
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text).map_err(|e| ApiError::Unexpected(e.to_string()))
    }

    pub async fn version(&self) -> ApiResult<String> {
        let json = self.request(Method::GET, "api/version", None, Duration::from_secs(4)).await?;
        Ok(json.get("version").and_then(Value::as_str).unwrap_or("?").to_owned())
    }

    pub async fn models(&self) -> ApiResult<Vec<OllamaModel>> {
        let json = self.request(Method::GET, "api/tags", None, Duration::from_secs(30)).await?;
        Ok(json.get("models").and_then(Value::as_array).map(|list| list.iter().filter_map(OllamaModel::from_json).collect()).unwrap_or_default())
    }

    pub async fn running_models(&self) -> ApiResult<Vec<RunningModel>> {
        let json = self.request(Method::GET, "api/ps", None, Duration::from_secs(15)).await?;
        Ok(json.get("models").and_then(Value::as_array).map(|list| list.iter().filter_map(RunningModel::from_json).collect()).unwrap_or_default())
    }

    pub async fn show(&self, model: &str) -> ApiResult<ModelInfo> {
        let json = self.request(Method::POST, "api/show", Some(json!({ "model": model })), Duration::from_secs(60)).await?;
        Ok(ModelInfo::from_json(&json))
    }

    pub async fn delete(&self, model: &str) -> ApiResult<()> {
        self.request(Method::DELETE, "api/delete", Some(json!({ "model": model })), Duration::from_secs(120)).await.map(|_| ())
    }

    pub async fn copy(&self, source: &str, destination: &str) -> ApiResult<()> {
        let body = json!({ "source": source, "destination": destination });
        self.request(Method::POST, "api/copy", Some(body), Duration::from_secs(120)).await.map(|_| ())
    }

    /// Loads a model into memory for `keep_alive_seconds`.
    pub async fn load(&self, model: &str, keep_alive_seconds: u64, is_embedding: bool) -> ApiResult<()> {
        let timeout = Duration::from_secs(15 * 60);
        if is_embedding {
            let body = json!({ "model": model, "input": [], "keep_alive": keep_alive_seconds });
            self.request(Method::POST, "api/embed", Some(body), timeout).await.map(|_| ())
        } else {
            let body = json!({ "model": model, "keep_alive": keep_alive_seconds });
            self.request(Method::POST, "api/generate", Some(body), timeout).await.map(|_| ())
        }
    }

    /// Unloads a model from memory (text and embedding models alike).
    pub async fn unload(&self, model: &str) -> ApiResult<()> {
        let body = json!({ "model": model, "keep_alive": 0 });
        self.request(Method::POST, "api/generate", Some(body), Duration::from_secs(120)).await.map(|_| ())
    }

    /// Downloads (or updates) a model. The stream ends after the `success` event.
    pub fn pull(&self, model: &str) -> StreamHandle<ProgressEvent> {
        self.stream("api/pull", json!({ "model": model, "stream": true }), |v| ProgressEvent::from_json(v))
    }

    pub fn create(&self, model: &str, from: &str, system: Option<&str>, parameters: Value) -> StreamHandle<ProgressEvent> {
        let mut body = json!({ "model": model, "from": from, "stream": true });
        if let Some(system) = system {
            body["system"] = json!(system);
        }
        if parameters.as_object().is_some_and(|p| !p.is_empty()) {
            body["parameters"] = parameters;
        }
        self.stream("api/create", body, |v| ProgressEvent::from_json(v))
    }

    pub fn chat(&self, model: &str, messages: &[ChatMessage], think: Option<bool>, options: Value, keep_alive_seconds: u64) -> StreamHandle<ChatChunk> {
        let mut body = json!({ "model": model, "messages": messages, "stream": true, "keep_alive": keep_alive_seconds });
        if let Some(think) = think {
            body["think"] = json!(think);
        }
        if options.as_object().is_some_and(|o| !o.is_empty()) {
            body["options"] = options;
        }
        self.stream("api/chat", body, |v| ChatChunk::from_json(v))
    }

    /// POSTs `body` and decodes the newline-delimited JSON response line by line.
    fn stream<T: Send + 'static>(&self, path: &str, body: Value, decode: fn(&Value) -> T) -> StreamHandle<T> {
        // Bounded: a slow consumer slows down reading instead of buffering without limit.
        let (sender, events) = mpsc::channel(256);
        let request = self.http.post(self.url(path)).json(&body);
        let task = tokio::spawn(async move {
            if let Err(error) = run_stream(request, decode, &sender).await {
                let _ = sender.send(Err(error)).await;
            }
        });
        StreamHandle { events, task: task.abort_handle() }
    }
}

async fn run_stream<T>(request: reqwest::RequestBuilder, decode: fn(&Value) -> T, sender: &mpsc::Sender<ApiResult<T>>) -> ApiResult<()> {
    let response = request.send().await?;
    let status = response.status();
    if !status.is_success() {
        let text = response.text().await.unwrap_or_default();
        return Err(ApiError::Server(error_message(&text).unwrap_or_else(|| format!("HTTP {status}"))));
    }
    let mut bytes = response.bytes_stream();
    let mut buffer: Vec<u8> = Vec::new();
    loop {
        // Ollama can stay silent for a long time (verifying a large blob, loading a model):
        // only give up after an hour without any data.
        let next = tokio::time::timeout(Duration::from_secs(3600), bytes.next()).await;
        let chunk = match next {
            Err(_) => return Err(ApiError::Network("The server stopped responding.".into())),
            Ok(None) => break,
            Ok(Some(chunk)) => chunk?,
        };
        buffer.extend_from_slice(&chunk);
        while let Some(newline) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=newline).collect();
            if let Some(event) = decode_line(&line, decode)? {
                // The receiver is gone when the stream was cancelled: stop quietly.
                if sender.send(Ok(event)).await.is_err() {
                    return Ok(());
                }
            }
        }
    }
    if let Some(event) = decode_line(&buffer, decode)? {
        let _ = sender.send(Ok(event)).await;
    }
    Ok(())
}

fn decode_line<T>(line: &[u8], decode: fn(&Value) -> T) -> ApiResult<Option<T>> {
    let text = String::from_utf8_lossy(line);
    let text = text.trim();
    if text.is_empty() {
        return Ok(None);
    }
    let value: Value = serde_json::from_str(text).map_err(|e| ApiError::Unexpected(e.to_string()))?;
    if let Some(error) = value.get("error").and_then(Value::as_str).filter(|e| !e.is_empty()) {
        return Err(ApiError::Server(error.to_owned()));
    }
    Ok(Some(decode(&value)))
}

/// Extracts `{"error": "…"}` from a response body, or returns a short raw body.
pub fn error_message(body: &str) -> Option<String> {
    let text = body.trim();
    if text.is_empty() {
        return None;
    }
    if let Ok(value) = serde_json::from_str::<Value>(text)
        && let Some(error) = value.get("error").and_then(Value::as_str)
    {
        return Some(error.to_owned());
    }
    Some(text.chars().take(300).collect())
}
