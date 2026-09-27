//! Preferences, stored as JSON in the user's configuration directory.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::api::client::parse_address;

pub const DEFAULT_ADDRESS: &str = "http://127.0.0.1:11434";

/// How long models stay in memory after being loaded or used from the app.
/// There is deliberately no "forever" option.
pub const KEEP_ALIVE_CHOICES: [u64; 5] = [60, 300, 900, 1800, 3600];
pub const REFRESH_CHOICES: [u64; 5] = [2, 3, 5, 10, 30];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Server {
    pub id: String,
    /// Empty for the default local server: the interface shows "This Mac" / "This PC".
    #[serde(default)]
    pub name: String,
    pub address: String,
}

impl Server {
    pub fn url(&self) -> reqwest::Url {
        parse_address(&self.address).unwrap_or_else(|| parse_address(DEFAULT_ADDRESS).expect("default address"))
    }

    /// Whether the server runs on this computer (enables "Start Ollama").
    pub fn is_local(&self) -> bool {
        matches!(self.url().host_str(), Some("localhost" | "127.0.0.1" | "[::1]" | "::1"))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub servers: Vec<Server>,
    pub selected_server: String,
    pub keep_alive_seconds: u64,
    pub refresh_seconds: u64,
    pub check_updates_on_launch: bool,
    /// 0 system, 1 light, 2 dark
    pub theme: i32,
    pub show_tray_icon: bool,
}

impl Default for Settings {
    fn default() -> Self {
        let local = default_local_server();
        Self {
            selected_server: local.id.clone(),
            servers: vec![local],
            keep_alive_seconds: 300,
            refresh_seconds: 3,
            check_updates_on_launch: false,
            theme: 0,
            show_tray_icon: true,
        }
    }
}

pub fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or_default();
    format!("{:x}{:x}", nanos, std::process::id())
}

/// The local server, honoring `OLLAMA_HOST` like the Ollama CLI.
pub fn default_local_server() -> Server {
    let address = std::env::var("OLLAMA_HOST")
        .ok()
        .and_then(|host| parse_address(&host))
        .map(|url| crate::api::client::display_url(&url))
        .unwrap_or_else(|| DEFAULT_ADDRESS.to_owned());
    Server { id: new_id(), name: String::new(), address }
}

fn path() -> Option<PathBuf> {
    let dirs = directories::ProjectDirs::from("com", "hfc", "Ollama GUI")?;
    Some(dirs.config_dir().join("settings.json"))
}

impl Settings {
    pub fn load() -> Self {
        let mut settings: Settings = path().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default();
        settings.normalize();
        settings
    }

    /// Repairs values edited by hand or saved by another version.
    pub fn normalize(&mut self) {
        if self.servers.is_empty() {
            self.servers.push(default_local_server());
        }
        if !self.servers.iter().any(|s| s.id == self.selected_server) {
            self.selected_server = self.servers[0].id.clone();
        }
        if !KEEP_ALIVE_CHOICES.contains(&self.keep_alive_seconds) {
            self.keep_alive_seconds = 300;
        }
        if !REFRESH_CHOICES.contains(&self.refresh_seconds) {
            self.refresh_seconds = 3;
        }
        self.theme = self.theme.clamp(0, 2);
    }

    pub fn save(&self) {
        let Some(path) = path() else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(text) = serde_json::to_string_pretty(self) {
            // Write then rename, so a crash never leaves a truncated file.
            let temporary = path.with_extension("json.tmp");
            if std::fs::write(&temporary, text).is_ok() {
                let _ = std::fs::rename(&temporary, &path);
            }
        }
    }

    pub fn current_server(&self) -> &Server {
        self.servers.iter().find(|s| s.id == self.selected_server).unwrap_or(&self.servers[0])
    }
}
