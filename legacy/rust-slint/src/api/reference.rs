//! Model names: `[host/][namespace/]repository[:tag]`.

pub const OFFICIAL_REGISTRY: &str = "registry.ollama.ai";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelReference {
    pub host: String,
    pub namespace: String,
    pub repository: String,
    pub tag: String,
}

fn valid_component(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

impl ModelReference {
    /// `gemma3` → `registry.ollama.ai/library/gemma3:latest`;
    /// `hf.co/unsloth/Qwen3-GGUF:Q4_K_M` → host `hf.co`, namespace `unsloth`.
    pub fn parse(name: &str) -> Option<Self> {
        let mut text = name.trim();
        if text.is_empty() || text.contains(char::is_whitespace) {
            return None;
        }
        if let Some((_, rest)) = text.split_once("://") {
            text = rest;
        }
        let mut parts: Vec<&str> = text.split('/').collect();
        if parts.iter().any(|p| p.is_empty()) {
            return None;
        }
        let last = parts.pop()?;
        let (repository, tag) = match last.rsplit_once(':') {
            Some((repo, tag)) => (repo, tag),
            None => (last, "latest"),
        };
        if repository.contains(':') {
            return None;
        }
        let (mut host, namespace) = match parts.as_slice() {
            [] => (OFFICIAL_REGISTRY, "library"),
            [namespace] => (OFFICIAL_REGISTRY, *namespace),
            [host, namespace] => (*host, *namespace),
            _ => return None,
        };
        if !valid_component(namespace) || !valid_component(repository) || !valid_component(tag) {
            return None;
        }
        if host == "ollama.com" {
            host = OFFICIAL_REGISTRY;
        }
        Some(Self { host: host.into(), namespace: namespace.into(), repository: repository.into(), tag: tag.into() })
    }

    pub fn is_official_registry(&self) -> bool {
        self.host == OFFICIAL_REGISTRY
    }

    /// Cloud models have a `cloud` tag, or a tag ending in `-cloud`.
    pub fn is_cloud_tag(&self) -> bool {
        self.tag == "cloud" || self.tag.ends_with("-cloud")
    }

    /// The shortest name Ollama accepts for this model.
    pub fn short_name(&self) -> String {
        if self.is_official_registry() {
            if self.namespace == "library" {
                format!("{}:{}", self.repository, self.tag)
            } else {
                format!("{}/{}:{}", self.namespace, self.repository, self.tag)
            }
        } else {
            format!("{}/{}/{}:{}", self.host, self.namespace, self.repository, self.tag)
        }
    }

    /// Fully qualified, lower-cased form used to compare names.
    pub fn canonical_name(&self) -> String {
        format!("{}/{}/{}:{}", self.host, self.namespace, self.repository, self.tag).to_lowercase()
    }

    pub fn manifest_url(&self) -> String {
        format!("https://{}/v2/{}/{}/manifests/{}", self.host, self.namespace, self.repository, self.tag)
    }

    /// Public web page of the model, when it comes from a known registry.
    pub fn web_page(&self) -> Option<String> {
        if self.is_official_registry() {
            Some(if self.namespace == "library" {
                format!("https://ollama.com/library/{}", self.repository)
            } else {
                format!("https://ollama.com/{}/{}", self.namespace, self.repository)
            })
        } else if self.host == "hf.co" || self.host == "huggingface.co" {
            Some(format!("https://huggingface.co/{}/{}", self.namespace, self.repository))
        } else {
            None
        }
    }
}

/// Canonical form of any model name; falls back to the lower-cased input.
pub fn canonical(name: &str) -> String {
    ModelReference::parse(name).map(|r| r.canonical_name()).unwrap_or_else(|| name.to_lowercase())
}
