//! Update checks against the Ollama registry.
//!
//! The digest of a local model is the SHA-256 of its manifest, so comparing it
//! with the digest of the registry's current manifest tells whether a pull would
//! change anything. Nothing is downloaded but the manifest headers.

use std::time::Duration;

use sha2::{Digest, Sha256};

use super::client::ApiError;
use super::models::OllamaModel;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateStatus {
    Checking,
    UpToDate,
    Available,
    /// Cloud model, other registry, or network error.
    Unknown,
}

const ACCEPT: &str = "application/vnd.docker.distribution.manifest.v2+json";

pub async fn status(http: &reqwest::Client, model: &OllamaModel) -> UpdateStatus {
    let Some(reference) = model.reference() else { return UpdateStatus::Unknown };
    if model.is_cloud() || !reference.is_official_registry() {
        return UpdateStatus::Unknown;
    }
    let local = model.digest.trim_start_matches("sha256:").to_lowercase();
    match remote_digest(http, &reference.manifest_url()).await {
        Ok(remote) if remote == local => UpdateStatus::UpToDate,
        Ok(_) => UpdateStatus::Available,
        Err(_) => UpdateStatus::Unknown,
    }
}

pub async fn remote_digest(http: &reqwest::Client, manifest_url: &str) -> Result<String, ApiError> {
    let timeout = Duration::from_secs(20);
    // The registry exposes the digest as a header: a HEAD request is enough.
    let head = http.head(manifest_url).header("Accept", ACCEPT).timeout(timeout).send().await?;
    if head.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(ApiError::Server(format!("HTTP {}", head.status())));
    }
    if head.status().is_success() {
        for name in ["ollama-content-digest", "docker-content-digest"] {
            if let Some(value) = head.headers().get(name).and_then(|v| v.to_str().ok()).filter(|v| !v.is_empty()) {
                return Ok(value.trim_start_matches("sha256:").to_lowercase());
            }
        }
    }
    // Fallback (no digest header, or a server that refuses HEAD): hash the manifest ourselves.
    let response = http.get(manifest_url).header("Accept", ACCEPT).timeout(timeout).send().await?;
    if !response.status().is_success() {
        return Err(ApiError::Server(format!("HTTP {}", response.status())));
    }
    let body = response.bytes().await?;
    Ok(Sha256::digest(&body).iter().map(|byte| format!("{byte:02x}")).collect())
}
