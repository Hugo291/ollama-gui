//! Data returned by the Ollama API, decoded leniently: a missing or oddly typed
//! field never makes a whole response fail.

use chrono::{DateTime, FixedOffset};
use serde::Serialize;
use serde_json::{Map, Value};

use super::reference::ModelReference;

pub mod capability {
    pub const COMPLETION: &str = "completion";
    pub const VISION: &str = "vision";
    pub const TOOLS: &str = "tools";
    pub const THINKING: &str = "thinking";
    pub const EMBEDDING: &str = "embedding";
    pub const IMAGE: &str = "image";
}

fn string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_owned)
}

fn non_empty(value: Option<&str>) -> Option<String> {
    value.map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
}

fn number(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::Number(n) => n.as_u64().or_else(|| n.as_f64().filter(|f| f.is_finite() && *f >= 0.0 && f.fract() == 0.0).map(|f| f as u64)),
        _ => None,
    }
}

fn strings(value: Option<&Value>) -> Option<Vec<String>> {
    value?.as_array().map(|items| items.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
}

/// Parses the RFC 3339 timestamps sent by Ollama, which can carry nanoseconds.
pub fn parse_date(value: Option<&Value>) -> Option<DateTime<FixedOffset>> {
    DateTime::parse_from_rfc3339(value?.as_str()?.trim()).ok()
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ModelDetails {
    pub format: Option<String>,
    pub family: Option<String>,
    pub families: Vec<String>,
    pub parameter_size: Option<String>,
    pub quantization_level: Option<String>,
    pub context_length: Option<u64>,
    pub embedding_length: Option<u64>,
}

impl ModelDetails {
    pub fn from_json(value: Option<&Value>) -> Self {
        let Some(map) = value.and_then(Value::as_object) else { return Self::default() };
        Self {
            format: string(map.get("format")),
            family: string(map.get("family")),
            families: strings(map.get("families")).unwrap_or_default(),
            parameter_size: string(map.get("parameter_size")),
            quantization_level: string(map.get("quantization_level")),
            context_length: number(map.get("context_length")),
            embedding_length: number(map.get("embedding_length")),
        }
    }
}

/// An installed model (`/api/tags`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct OllamaModel {
    pub name: String,
    pub modified_at: Option<DateTime<FixedOffset>>,
    pub size: u64,
    pub digest: String,
    pub details: ModelDetails,
    /// `None` when the server is too old to report capabilities.
    pub capabilities: Option<Vec<String>>,
    pub remote_host: Option<String>,
}

impl OllamaModel {
    pub fn from_json(value: &Value) -> Option<Self> {
        let map = value.as_object()?;
        let name = string(map.get("name")).or_else(|| string(map.get("model")))?;
        Some(Self {
            name,
            modified_at: parse_date(map.get("modified_at")),
            size: number(map.get("size")).unwrap_or(0),
            digest: string(map.get("digest")).unwrap_or_default(),
            details: ModelDetails::from_json(map.get("details")),
            capabilities: strings(map.get("capabilities")),
            remote_host: non_empty(map.get("remote_host").and_then(Value::as_str)),
        })
    }

    pub fn reference(&self) -> Option<ModelReference> {
        ModelReference::parse(&self.name)
    }

    /// Cloud models run on ollama.com; locally they are only a small stub.
    pub fn is_cloud(&self) -> bool {
        self.remote_host.is_some() || self.reference().is_some_and(|r| r.is_cloud_tag())
    }

    pub fn supports(&self, capability: &str) -> bool {
        self.capabilities.as_ref().is_some_and(|caps| caps.iter().any(|c| c == capability))
    }

    /// Without reported capabilities, assume a text model.
    pub fn can_chat(&self) -> bool {
        match &self.capabilities {
            None => true,
            Some(_) => self.supports(capability::COMPLETION) && !self.supports(capability::EMBEDDING),
        }
    }

    /// Whether the model can be preloaded into memory with `keep_alive`.
    pub fn can_load(&self) -> bool {
        !self.is_cloud() && !self.supports(capability::IMAGE)
    }

    pub fn parameter_size(&self) -> Option<String> {
        non_empty(self.details.parameter_size.as_deref())
    }

    pub fn quantization(&self) -> Option<String> {
        non_empty(self.details.quantization_level.as_deref())
    }

    pub fn format(&self) -> Option<String> {
        non_empty(self.details.format.as_deref())
    }

    pub fn family(&self) -> Option<String> {
        non_empty(self.details.family.as_deref()).or_else(|| non_empty(self.details.families.first().map(String::as_str)))
    }

    pub fn short_digest(&self) -> String {
        self.digest.trim_start_matches("sha256:").chars().take(12).collect()
    }
}

/// A model loaded in memory (`/api/ps`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RunningModel {
    pub name: String,
    pub model: Option<String>,
    pub size: u64,
    pub size_vram: u64,
    pub expires_at: Option<DateTime<FixedOffset>>,
    pub context_length: Option<u64>,
    pub details: ModelDetails,
}

impl RunningModel {
    pub fn from_json(value: &Value) -> Option<Self> {
        let map = value.as_object()?;
        let model = string(map.get("model"));
        let name = string(map.get("name")).or_else(|| model.clone())?;
        Some(Self {
            name,
            model,
            size: number(map.get("size")).unwrap_or(0),
            size_vram: number(map.get("size_vram")).unwrap_or(0),
            expires_at: parse_date(map.get("expires_at")),
            context_length: number(map.get("context_length")),
            details: ModelDetails::from_json(map.get("details")),
        })
    }

    /// Share of the model held in GPU memory, between 0 and 1.
    pub fn gpu_share(&self) -> f32 {
        if self.size == 0 { 0.0 } else { (self.size_vram as f64 / self.size as f64).clamp(0.0, 1.0) as f32 }
    }

    /// Same wording as the `PROCESSOR` column of `ollama ps`.
    pub fn processor_label(&self) -> String {
        if self.size_vram == 0 {
            "100% CPU".into()
        } else if self.size_vram >= self.size {
            "100% GPU".into()
        } else {
            let cpu = ((self.size - self.size_vram) as f64 / self.size as f64 * 100.0).round() as u64;
            format!("{cpu}%/{}% CPU/GPU", 100 - cpu)
        }
    }

    /// Models loaded with a negative keep-alive expire centuries from now.
    pub fn stays_loaded(&self) -> bool {
        self.expires_at.is_some_and(|date| (date.to_utc() - chrono::Utc::now()).num_days() > 365)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ModelParameter {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TensorInfo {
    pub name: String,
    pub kind: String,
    pub shape: Vec<u64>,
}

/// Details of a model (`/api/show`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ModelInfo {
    pub license: Option<String>,
    pub modelfile: Option<String>,
    pub parameters: Option<String>,
    pub template: Option<String>,
    pub system: Option<String>,
    pub details: ModelDetails,
    pub model_info: Map<String, Value>,
    pub tensors: Vec<TensorInfo>,
    pub requires: Option<String>,
}

impl ModelInfo {
    pub fn from_json(value: &Value) -> Self {
        let Some(map) = value.as_object() else { return Self::default() };
        let tensors = map
            .get("tensors")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        let item = item.as_object()?;
                        Some(TensorInfo {
                            name: string(item.get("name"))?,
                            kind: string(item.get("type")).unwrap_or_default(),
                            shape: item
                                .get("shape")
                                .and_then(Value::as_array)
                                .map(|dims| dims.iter().filter_map(|d| number(Some(d))).collect())
                                .unwrap_or_default(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            license: string(map.get("license")),
            modelfile: string(map.get("modelfile")),
            parameters: string(map.get("parameters")),
            template: string(map.get("template")),
            system: string(map.get("system")),
            details: ModelDetails::from_json(map.get("details")),
            model_info: map.get("model_info").and_then(Value::as_object).cloned().unwrap_or_default(),
            tensors,
            requires: string(map.get("requires")),
        }
    }

    pub fn architecture(&self) -> Option<String> {
        non_empty(self.model_info.get("general.architecture").and_then(Value::as_str)).or_else(|| non_empty(self.details.family.as_deref()))
    }

    fn arch_number(&self, key: &str) -> Option<u64> {
        let arch = self.architecture()?;
        number(self.model_info.get(&format!("{arch}.{key}")))
    }

    pub fn context_length(&self) -> Option<u64> {
        self.arch_number("context_length").or(self.details.context_length)
    }

    pub fn embedding_length(&self) -> Option<u64> {
        self.arch_number("embedding_length").or(self.details.embedding_length)
    }

    pub fn parameter_count(&self) -> Option<u64> {
        number(self.model_info.get("general.parameter_count"))
    }

    /// First meaningful line of the license, usually its name.
    pub fn license_title(&self) -> Option<String> {
        self.license.as_deref()?.lines().map(str::trim).find(|line| !line.is_empty()).map(str::to_owned)
    }

    /// The `parameters` block as key/value pairs (keys may repeat, e.g. `stop`).
    pub fn parameter_list(&self) -> Vec<ModelParameter> {
        parse_parameters(self.parameters.as_deref().unwrap_or_default())
    }
}

pub fn parse_parameters(text: &str) -> Vec<ModelParameter> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| match line.split_once(char::is_whitespace) {
            Some((key, value)) => {
                let value = value.trim();
                let value = if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') { &value[1..value.len() - 1] } else { value };
                ModelParameter { key: key.to_owned(), value: value.to_owned() }
            }
            None => ModelParameter { key: line.to_owned(), value: String::new() },
        })
        .collect()
}

/// Human-readable rendering of a `model_info` value.
pub fn display_value(value: &Value) -> String {
    match value {
        Value::Null => "null".into(),
        Value::String(s) => s.clone(),
        Value::Array(items) if items.len() > 12 => {
            let head: Vec<String> = items.iter().take(12).map(display_value).collect();
            format!("[{}, … ({})]", head.join(", "), items.len())
        }
        Value::Array(items) => format!("[{}]", items.iter().map(display_value).collect::<Vec<_>>().join(", ")),
        other => other.to_string(),
    }
}

/// A line of `/api/pull` or `/api/create`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProgressEvent {
    pub status: Option<String>,
    pub digest: Option<String>,
    pub total: Option<u64>,
    pub completed: Option<u64>,
}

impl ProgressEvent {
    pub fn from_json(value: &Value) -> Self {
        Self {
            status: string(value.get("status")),
            digest: string(value.get("digest")),
            total: number(value.get("total")),
            completed: number(value.get("completed")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
    /// Base64-encoded images, for vision models.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<String>,
}

/// A line of `/api/chat`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChatChunk {
    pub content: String,
    pub thinking: String,
    pub done: bool,
    pub eval_count: Option<u64>,
    /// Nanoseconds.
    pub eval_duration: Option<u64>,
    pub load_duration: Option<u64>,
    pub total_duration: Option<u64>,
}

impl ChatChunk {
    pub fn from_json(value: &Value) -> Self {
        let message = value.get("message");
        Self {
            content: string(message.and_then(|m| m.get("content"))).unwrap_or_default(),
            thinking: string(message.and_then(|m| m.get("thinking"))).unwrap_or_default(),
            done: value.get("done").and_then(Value::as_bool).unwrap_or(false),
            eval_count: number(value.get("eval_count")),
            eval_duration: number(value.get("eval_duration")),
            load_duration: number(value.get("load_duration")),
            total_duration: number(value.get("total_duration")),
        }
    }

    pub fn tokens_per_second(&self) -> Option<f64> {
        match (self.eval_count, self.eval_duration) {
            (Some(count), Some(duration)) if duration > 0 => Some(count as f64 / (duration as f64 / 1e9)),
            _ => None,
        }
    }
}
