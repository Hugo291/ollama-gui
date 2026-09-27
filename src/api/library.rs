//! The public model library of ollama.com.
//!
//! ollama.com has no public search API, so this parses the HTML of the search and
//! tags pages. Parsing is lenient: unknown markup yields fewer fields, not errors.

use std::collections::HashSet;
use std::sync::LazyLock;
use std::time::Duration;

use regex::Regex;

use super::client::ApiError;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct LibraryModel {
    /// Path on ollama.com: `library/qwen3` or `user/model`.
    pub path: String,
    pub name: String,
    pub summary: String,
    pub capabilities: Vec<String>,
    pub sizes: Vec<String>,
    pub pulls: Option<String>,
    pub tag_count: Option<String>,
    pub updated: Option<String>,
}

impl LibraryModel {
    pub fn page_url(&self) -> String {
        format!("https://ollama.com/{}", self.path)
    }

    /// Name to pass to `ollama pull` (without tag).
    pub fn pull_name(&self) -> &str {
        self.path.strip_prefix("library/").unwrap_or(&self.path)
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct LibraryTag {
    /// Name to pull, e.g. `qwen3:8b`.
    pub name: String,
    pub badges: Vec<String>,
    pub digest: Option<String>,
    /// Download size (`5.2GB`), or the usage level for cloud models.
    pub size: Option<String>,
    pub context: Option<String>,
    pub input: Option<String>,
    pub updated: Option<String>,
}

impl LibraryTag {
    pub fn tag(&self) -> &str {
        self.name.rsplit_once(':').map_or("latest", |(_, tag)| tag)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LibrarySort {
    #[default]
    Popular,
    Newest,
}

/// `capability` is one of `vision`, `tools`, `thinking`, `embedding`, `cloud`.
pub async fn search(http: &reqwest::Client, query: &str, capability: Option<&str>, sort: LibrarySort) -> Result<Vec<LibraryModel>, ApiError> {
    let mut params = vec![("q", query)];
    if let Some(capability) = capability {
        params.push(("c", capability));
    }
    if sort == LibrarySort::Newest {
        params.push(("o", "newest"));
    }
    let url = reqwest::Url::parse_with_params("https://ollama.com/search", &params).map_err(|e| ApiError::Unexpected(e.to_string()))?;
    Ok(parse_search(&fetch(http, url.as_str()).await?))
}

pub async fn tags(http: &reqwest::Client, model: &LibraryModel) -> Result<Vec<LibraryTag>, ApiError> {
    Ok(parse_tags(&fetch(http, &format!("{}/tags", model.page_url())).await?))
}

async fn fetch(http: &reqwest::Client, url: &str) -> Result<String, ApiError> {
    let response = http.get(url).header("Accept", "text/html").timeout(Duration::from_secs(20)).send().await?;
    if !response.status().is_success() {
        return Err(ApiError::Server(format!("ollama.com: HTTP {}", response.status())));
    }
    Ok(response.text().await?)
}

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("valid regex")
}

static LIST_ITEM: LazyLock<Regex> = LazyLock::new(|| regex(r"(?is)<li\b[^>]*>(.*?)</li>"));
static MODEL_LINK: LazyLock<Regex> = LazyLock::new(|| regex(r#"(?is)<a\s+href="/([^"?#]+)""#));
static TITLE: LazyLock<Regex> = LazyLock::new(|| regex(r"(?is)<h2[^>]*>\s*<span[^>]*>(.*?)</span>"));
static SUMMARY: LazyLock<Regex> = LazyLock::new(|| regex(r#"(?is)<p\s+class="max-w-lg[^"]*"[^>]*>(.*?)</p>"#));
static BADGE: LazyLock<Regex> = LazyLock::new(|| regex(r#"(?is)<span[^>]*class="[^"]*inline-flex[^"]*"[^>]*>([^<]*)</span>"#));
static PULLS: LazyLock<Regex> = LazyLock::new(|| regex(r"(?is)<span[^>]*>([^<]*)</span>\s*<span[^>]*>(?:&nbsp;|\s)*Pulls?\s*</span>"));
static TAG_COUNT: LazyLock<Regex> = LazyLock::new(|| regex(r"(?is)<span[^>]*>([^<]*)</span>\s*<span[^>]*>(?:&nbsp;|\s)*Tags?\s*</span>"));
static UPDATED: LazyLock<Regex> = LazyLock::new(|| regex(r"(?is)Updated(?:&nbsp;|\s)*</span>\s*<span[^>]*>([^<]*)</span>"));
static TAG_BLOCK: LazyLock<Regex> = LazyLock::new(|| regex(r#"(?is)<a\s+href="/([^"]+:[^"]+)"\s+class="md:hidden[^"]*"[^>]*>(.*?)</a>"#));
static DIGEST: LazyLock<Regex> = LazyLock::new(|| regex(r"\b([0-9a-f]{12})\b"));
static SIZE_BADGE: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)^(?:e?\d+(?:\.\d+)?|\d+x\d+(?:\.\d+)?)[kmbt]$"));
static HTML_TAG: LazyLock<Regex> = LazyLock::new(|| regex(r"<[^>]+>"));
static ENTITY: LazyLock<Regex> = LazyLock::new(|| regex(r"&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);"));

fn capture(regex: &Regex, text: &str) -> Option<String> {
    regex.captures(text).and_then(|c| c.get(1)).map(|m| m.as_str().to_owned())
}

fn non_empty(text: String) -> Option<String> {
    if text.is_empty() { None } else { Some(text) }
}

pub fn is_size_badge(text: &str) -> bool {
    SIZE_BADGE.is_match(text)
}

pub fn parse_search(html: &str) -> Vec<LibraryModel> {
    let mut results = Vec::new();
    let mut seen = HashSet::new();
    for item in LIST_ITEM.captures_iter(html) {
        let body = item.get(1).map_or("", |m| m.as_str());
        let (Some(path), Some(raw_title)) = (capture(&MODEL_LINK, body), capture(&TITLE, body)) else { continue };
        let components: Vec<&str> = path.split('/').collect();
        if components.len() != 2 || !seen.insert(path.clone()) {
            continue;
        }
        let badges: Vec<String> = BADGE.captures_iter(body).filter_map(|c| c.get(1)).map(|m| clean(m.as_str())).filter(|b| !b.is_empty()).collect();
        let name = clean(&raw_title);
        results.push(LibraryModel {
            name: if name.is_empty() { components[1].to_owned() } else { name },
            summary: capture(&SUMMARY, body).map(|s| clean(&s)).unwrap_or_default(),
            capabilities: badges.iter().filter(|b| !is_size_badge(b)).map(|b| b.to_lowercase()).collect(),
            sizes: badges.iter().filter(|b| is_size_badge(b)).cloned().collect(),
            pulls: capture(&PULLS, body).map(|s| clean(&s)).and_then(non_empty),
            tag_count: capture(&TAG_COUNT, body).map(|s| clean(&s)).and_then(non_empty),
            updated: capture(&UPDATED, body).map(|s| clean(&s)).and_then(non_empty),
            path,
        });
    }
    results
}

pub fn parse_tags(html: &str) -> Vec<LibraryTag> {
    let mut results = Vec::new();
    let mut seen = HashSet::new();
    for block in TAG_BLOCK.captures_iter(html) {
        let path = &block[1];
        let name = path.strip_prefix("library/").unwrap_or(path).to_owned();
        if !seen.insert(name.clone()) {
            continue;
        }
        let mut text = clean(block.get(2).map_or("", |m| m.as_str()));
        if let Some(rest) = text.strip_prefix(name.as_str()) {
            text = rest.to_owned();
        }
        let (badges, digest, fields_text) = match DIGEST.captures(&text) {
            Some(captures) => {
                let whole = captures.get(0).expect("match");
                let badges = text[..whole.start()].split_whitespace().map(str::to_owned).collect();
                (badges, Some(captures[1].to_owned()), text[whole.end()..].to_owned())
            }
            None => (Vec::new(), None, text.clone()),
        };
        let fields: Vec<String> = fields_text.split('•').map(|f| f.trim().to_owned()).filter(|f| !f.is_empty()).collect();
        results.push(LibraryTag {
            size: fields.first().cloned(),
            context: fields.iter().find(|f| f.to_lowercase().contains("context")).cloned(),
            input: fields.iter().find(|f| f.to_lowercase().contains("input")).cloned(),
            updated: if fields.len() >= 4 { fields.last().cloned() } else { None },
            name,
            badges,
            digest,
        });
    }
    results
}

/// Strips tags, decodes entities and collapses whitespace.
pub fn clean(html: &str) -> String {
    decode_entities(&HTML_TAG.replace_all(html, " ")).split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn decode_entities(text: &str) -> String {
    if !text.contains('&') {
        return text.to_owned();
    }
    ENTITY
        .replace_all(text, |caps: &regex::Captures| {
            let entity = &caps[1];
            let decoded = match entity {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some(' '),
                _ if entity.starts_with("#x") || entity.starts_with("#X") => u32::from_str_radix(&entity[2..], 16).ok().and_then(char::from_u32),
                _ if entity.starts_with('#') => entity[1..].parse().ok().and_then(char::from_u32),
                _ => None,
            };
            decoded.map_or_else(|| caps[0].to_owned(), String::from)
        })
        .into_owned()
}
