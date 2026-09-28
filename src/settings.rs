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
    pub layout: Layout,
}

/// Widths of the resizable panes and table columns, in logical pixels.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Layout {
    pub sidebar: f32,
    pub inspector: f32,
    pub library: f32,
    /// Parameters, Quantization, Size, Capabilities and Modified columns of the Models table.
    pub columns: [f32; 5],
}

impl Layout {
    /// Allowed widths (the interface enforces the same bounds while dragging).
    pub const SIDEBAR: (f32, f32) = (190.0, 320.0);
    pub const INSPECTOR: (f32, f32) = (300.0, 560.0);
    pub const LIBRARY: (f32, f32) = (260.0, 560.0);
    pub const COLUMNS: [(f32, f32); 5] = [(60.0, 200.0), (70.0, 200.0), (60.0, 180.0), (60.0, 240.0), (70.0, 220.0)];

    fn normalize(&mut self) {
        let clamp = |value: f32, (min, max): (f32, f32), default: f32| if value.is_finite() { value.clamp(min, max) } else { default };
        let defaults = Layout::default();
        self.sidebar = clamp(self.sidebar, Self::SIDEBAR, defaults.sidebar);
        self.inspector = clamp(self.inspector, Self::INSPECTOR, defaults.inspector);
        self.library = clamp(self.library, Self::LIBRARY, defaults.library);
        for (index, width) in self.columns.iter_mut().enumerate() {
            *width = clamp(*width, Self::COLUMNS[index], defaults.columns[index]);
        }
    }
}

impl Default for Layout {
    fn default() -> Self {
        Self { sidebar: 232.0, inspector: 360.0, library: 380.0, columns: [92.0, 112.0, 90.0, 118.0, 112.0] }
    }
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
            layout: Layout::default(),
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
        .and_then(|host| crate::api::client::parse_ollama_host(&host))
        .map(|url| crate::api::client::address_text(&url))
        .unwrap_or_else(|| DEFAULT_ADDRESS.to_owned());
    Server { id: new_id(), name: String::new(), address }
}

fn path() -> Option<PathBuf> {
    // Debug builds: a separate settings file for tests (`OLLAMA_GUI_SETTINGS=/tmp/settings.json`).
    #[cfg(debug_assertions)]
    if let Some(path) = std::env::var_os("OLLAMA_GUI_SETTINGS") {
        return Some(path.into());
    }
    let dirs = directories::ProjectDirs::from("com", "hfc", "Ollama GUI")?;
    Some(dirs.config_dir().join("settings.json"))
}

impl Settings {
    pub fn load() -> Self {
        let path = path();
        let text = path.as_ref().and_then(|p| std::fs::read_to_string(p).ok());
        let mut settings = match text {
            None => Settings::default(),
            Some(text) => serde_json::from_str(&text).unwrap_or_else(|_| {
                // A value of an unexpected type (edited by hand, newer version): keep what can be
                // read, and a copy of the file, instead of losing the servers at the next save.
                if let Some(path) = &path {
                    let _ = std::fs::copy(path, path.with_extension("json.bak"));
                }
                Settings::lenient(&text)
            }),
        };
        settings.normalize();
        settings
    }

    /// Reads each value on its own, ignoring the ones that don't have the expected type.
    fn lenient(text: &str) -> Settings {
        use serde_json::Value;
        let mut settings = Settings::default();
        let Ok(Value::Object(map)) = serde_json::from_str::<Value>(text) else { return settings };
        let servers: Vec<Server> = map
            .get("servers")
            .and_then(Value::as_array)
            .map(|servers| {
                servers
                    .iter()
                    .filter_map(|server| {
                        let address = server.get("address")?.as_str()?.to_owned();
                        let id = server.get("id").and_then(Value::as_str).map_or_else(new_id, str::to_owned);
                        let name = server.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
                        Some(Server { id, name, address })
                    })
                    .collect()
            })
            .unwrap_or_default();
        if !servers.is_empty() {
            settings.servers = servers;
        }
        if let Some(selected) = map.get("selected_server").and_then(Value::as_str) {
            settings.selected_server = selected.to_owned();
        }
        let number = |key: &str| map.get(key).and_then(|v| v.as_u64().or_else(|| v.as_f64().map(|f| f as u64)));
        if let Some(value) = number("keep_alive_seconds") {
            settings.keep_alive_seconds = value;
        }
        if let Some(value) = number("refresh_seconds") {
            settings.refresh_seconds = value;
        }
        if let Some(value) = number("theme") {
            settings.theme = value as i32;
        }
        if let Some(value) = map.get("check_updates_on_launch").and_then(Value::as_bool) {
            settings.check_updates_on_launch = value;
        }
        if let Some(value) = map.get("show_tray_icon").and_then(Value::as_bool) {
            settings.show_tray_icon = value;
        }
        if let Some(layout) = map.get("layout").and_then(|l| serde_json::from_value(l.clone()).ok()) {
            settings.layout = layout;
        }
        settings
    }

    /// Repairs values edited by hand or saved by another version.
    pub fn normalize(&mut self) {
        self.servers.retain(|server| parse_address(&server.address).is_some());
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
        self.layout.normalize();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lenient_reading_keeps_servers() {
        let text = r#"{"servers":[{"id":"a","name":"Salon","address":"192.168.1.20"},{"address":"localhost:11434"},{"name":"broken"}],
            "selected_server":"a","keep_alive_seconds":900.0,"theme":"dark","show_tray_icon":false}"#;
        let mut settings = Settings::lenient(text);
        settings.normalize();
        assert_eq!(settings.servers.len(), 2);
        assert_eq!(settings.servers[0].name, "Salon");
        assert_eq!(settings.selected_server, "a");
        assert_eq!(settings.keep_alive_seconds, 900);
        assert_eq!(settings.theme, 0);
        assert!(!settings.show_tray_icon);
    }

    #[test]
    fn invalid_addresses_are_dropped() {
        let mut settings = Settings::default();
        settings.servers.push(Server { id: "x".into(), name: "Bad".into(), address: "ftp://nope".into() });
        settings.normalize();
        assert!(settings.servers.iter().all(|s| s.id != "x"));
    }
}
