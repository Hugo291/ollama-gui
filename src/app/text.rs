//! Strings composed on the Rust side, in the same language as the Slint interface.

use std::time::Duration;

use crate::api::client::ApiError;
use crate::api::format::{self, Lang};

pub struct Text {
    pub lang: Lang,
}

impl Text {
    /// The language of the system, as Slint picks it for the interface.
    pub fn system() -> Self {
        Self { lang: sys_locale::get_locale().map(|l| Lang::from_locale(&l)).unwrap_or_default() }
    }

    fn pick(&self, en: &str, fr: &str) -> String {
        match self.lang {
            Lang::En => en.to_owned(),
            Lang::Fr => fr.to_owned(),
        }
    }

    pub fn bytes(&self, value: u64) -> String {
        format::bytes(value, self.lang)
    }

    pub fn duration(&self, value: Duration) -> String {
        format::duration(value)
    }

    pub fn this_computer(&self) -> String {
        match (self.lang, cfg!(target_os = "macos")) {
            (Lang::En, true) => "This Mac".into(),
            (Lang::En, false) => "This PC".into(),
            (Lang::Fr, true) => "Ce Mac".into(),
            (Lang::Fr, false) => "Ce PC".into(),
        }
    }

    pub fn connecting(&self) -> String {
        self.pick("Connecting…", "Connexion…")
    }

    pub fn connected(&self, version: &str) -> String {
        match self.lang {
            Lang::En => format!("Connected · Ollama {version}"),
            Lang::Fr => format!("Connecté · Ollama {version}"),
        }
    }

    pub fn unreachable(&self) -> String {
        self.pick("Not reachable", "Injoignable")
    }

    pub fn models_count(&self, count: usize) -> String {
        match (self.lang, count) {
            (Lang::En, 1) => "1 model".into(),
            (Lang::En, n) => format!("{n} models"),
            (Lang::Fr, 0 | 1) => format!("{count} modèle"),
            (Lang::Fr, n) => format!("{n} modèles"),
        }
    }

    pub fn updates_available(&self, count: usize) -> String {
        match (self.lang, count) {
            (Lang::En, 1) => "1 update available".into(),
            (Lang::En, n) => format!("{n} updates available"),
            (Lang::Fr, 1) => "1 mise à jour disponible".into(),
            (Lang::Fr, n) => format!("{n} mises à jour disponibles"),
        }
    }

    pub fn loaded_count(&self, count: usize) -> String {
        match (self.lang, count) {
            (Lang::En, n) => format!("{n} loaded"),
            (Lang::Fr, 0 | 1) => format!("{count} chargé"),
            (Lang::Fr, n) => format!("{n} chargés"),
        }
    }

    pub fn of(&self, part: &str, whole: &str) -> String {
        match self.lang {
            Lang::En => format!("{part} of {whole}"),
            Lang::Fr => format!("{part} sur {whole}"),
        }
    }

    pub fn cloud(&self) -> String {
        "Cloud".into()
    }

    pub fn unloads_at(&self, time: &str) -> String {
        match self.lang {
            Lang::En => format!("Unloads at {time}"),
            Lang::Fr => format!("Déchargement à {time}"),
        }
    }

    pub fn never(&self) -> String {
        self.pick("Never", "Jamais")
    }

    pub fn now(&self) -> String {
        self.pick("Now", "Maintenant")
    }

    pub fn in_duration(&self, duration: Duration) -> String {
        match self.lang {
            Lang::En => format!("in {}", self.duration(duration)),
            Lang::Fr => format!("dans {}", self.duration(duration)),
        }
    }

    pub fn tokens(&self, value: &str) -> String {
        format!("{value} tokens")
    }

    pub fn keep_alive_label(&self, seconds: u64) -> String {
        match (self.lang, seconds) {
            (Lang::En, 60) => "1 minute".into(),
            (Lang::En, 3600) => "1 hour".into(),
            (Lang::En, s) => format!("{} minutes", s / 60),
            (Lang::Fr, 60) => "1 minute".into(),
            (Lang::Fr, 3600) => "1 heure".into(),
            (Lang::Fr, s) => format!("{} minutes", s / 60),
        }
    }

    pub fn load_tooltip(&self, seconds: u64) -> String {
        match self.lang {
            Lang::En => format!("Load the model into memory for {}", self.keep_alive_label(seconds)),
            Lang::Fr => format!("Charger le modèle en mémoire pendant {}", self.keep_alive_label(seconds)),
        }
    }

    pub fn load_menu_tooltip(&self, seconds: u64) -> String {
        match self.lang {
            Lang::En => format!("Load a model into memory for {}", self.keep_alive_label(seconds)),
            Lang::Fr => format!("Charger un modèle en mémoire pendant {}", self.keep_alive_label(seconds)),
        }
    }

    pub fn refresh_label(&self, seconds: u64) -> String {
        match self.lang {
            Lang::En => format!("{seconds} seconds"),
            Lang::Fr => format!("{seconds} secondes"),
        }
    }

    pub fn model_default(&self) -> String {
        self.pick("Model default", "Valeur du modèle")
    }

    // Details facts

    pub fn fact_size(&self) -> String {
        self.pick("Size", "Taille")
    }
    pub fn fact_runs_on(&self) -> String {
        self.pick("Runs on", "S’exécute sur")
    }
    pub fn fact_parameters(&self) -> String {
        self.pick("Parameters", "Paramètres")
    }
    pub fn fact_quantization(&self) -> String {
        self.pick("Quantization", "Quantification")
    }
    pub fn fact_format(&self) -> String {
        "Format".into()
    }
    pub fn fact_architecture(&self) -> String {
        "Architecture".into()
    }
    pub fn fact_context(&self) -> String {
        self.pick("Context", "Contexte")
    }
    pub fn fact_embedding(&self) -> String {
        self.pick("Embedding size", "Taille d’embedding")
    }
    pub fn fact_modified(&self) -> String {
        self.pick("Modified", "Modifié")
    }
    pub fn fact_requires(&self) -> String {
        self.pick("Requires", "Nécessite")
    }
    pub fn fact_license(&self) -> String {
        self.pick("License", "Licence")
    }

    pub fn section_parameters(&self) -> String {
        self.pick("Parameters", "Paramètres")
    }
    pub fn section_system(&self) -> String {
        self.pick("System Prompt", "Prompt système")
    }
    pub fn section_template(&self) -> String {
        "Template".into()
    }
    pub fn section_modelfile(&self) -> String {
        "Modelfile".into()
    }
    pub fn section_license(&self) -> String {
        self.pick("License", "Licence")
    }
    pub fn section_model_info(&self) -> String {
        self.pick("Model Info", "Infos du modèle")
    }
    pub fn section_tensors(&self, count: usize) -> String {
        match self.lang {
            Lang::En => format!("Tensors ({count})"),
            Lang::Fr => format!("Tenseurs ({count})"),
        }
    }

    // Errors

    /// Message for an API error in the interface language. Messages from Ollama itself stay as they are.
    pub fn api_error(&self, error: &ApiError) -> String {
        match (error, self.lang) {
            (ApiError::Network(detail), Lang::En) => format!("Couldn't reach the server: {detail}"),
            (ApiError::Network(detail), Lang::Fr) => format!("Impossible de joindre le serveur : {detail}"),
            (ApiError::Timeout, _) => self.pick("The server isn't responding.", "Le serveur ne répond pas."),
            (ApiError::Server(message), _) => message.clone(),
            (ApiError::Unexpected(detail), Lang::En) => format!("Unexpected response from the server: {detail}"),
            (ApiError::Unexpected(detail), Lang::Fr) => format!("Réponse inattendue du serveur : {detail}"),
        }
    }

    pub fn images_not_attached(&self) -> String {
        self.pick("Some images weren't attached", "Certaines images n’ont pas été jointes")
    }
    pub fn image_too_large(&self, name: &str, limit_mb: u64) -> String {
        match self.lang {
            Lang::En => format!("{name} is larger than {limit_mb} MB."),
            Lang::Fr => format!("{name} dépasse {limit_mb} Mo."),
        }
    }
    pub fn image_unreadable(&self, name: &str) -> String {
        match self.lang {
            Lang::En => format!("{name} couldn't be read as an image."),
            Lang::Fr => format!("{name} n’a pas pu être lue comme une image."),
        }
    }
    pub fn too_many_images(&self, limit: usize) -> String {
        match self.lang {
            Lang::En => format!("At most {limit} images per message."),
            Lang::Fr => format!("{limit} images au maximum par message."),
        }
    }

    pub fn could_not_delete(&self, name: &str) -> String {
        match self.lang {
            Lang::En => format!("Couldn't delete {name}"),
            Lang::Fr => format!("Impossible de supprimer {name}"),
        }
    }
    pub fn could_not_copy(&self, name: &str) -> String {
        match self.lang {
            Lang::En => format!("Couldn't copy {name}"),
            Lang::Fr => format!("Impossible de copier {name}"),
        }
    }
    pub fn could_not_create(&self, name: &str) -> String {
        match self.lang {
            Lang::En => format!("Couldn't create {name}"),
            Lang::Fr => format!("Impossible de créer {name}"),
        }
    }
    pub fn could_not_load(&self, name: &str) -> String {
        match self.lang {
            Lang::En => format!("Couldn't load {name}"),
            Lang::Fr => format!("Impossible de charger {name}"),
        }
    }
    pub fn could_not_unload(&self, name: &str) -> String {
        match self.lang {
            Lang::En => format!("Couldn't unload {name}"),
            Lang::Fr => format!("Impossible de décharger {name}"),
        }
    }
    pub fn could_not_start(&self) -> String {
        self.pick("Couldn't start Ollama", "Impossible de démarrer Ollama")
    }
    pub fn incomplete(&self) -> String {
        self.pick("The operation ended before it completed.", "L’opération s’est arrêtée avant la fin.")
    }

    pub fn delete_message(&self, size: Option<u64>) -> String {
        match (self.lang, size) {
            (Lang::En, Some(size)) => format!("This frees {} of disk space. Deleted models can be pulled again at any time.", self.bytes(size)),
            (Lang::Fr, Some(size)) => {
                format!("Cela libère {} d’espace disque. Les modèles supprimés peuvent être retéléchargés à tout moment.", self.bytes(size))
            }
            (Lang::En, None) => "Deleted models can be pulled again at any time.".into(),
            (Lang::Fr, None) => "Les modèles supprimés peuvent être retéléchargés à tout moment.".into(),
        }
    }

    // Downloads

    pub fn progress_status(&self, status: &str) -> String {
        let lower = status.to_lowercase();
        let (en, fr) = if lower.is_empty() || lower == "pulling manifest" {
            ("Fetching manifest…", "Récupération du manifeste…")
        } else if lower.starts_with("pulling ") || lower.starts_with("downloading") {
            ("Downloading…", "Téléchargement…")
        } else if lower.starts_with("verifying") {
            ("Verifying…", "Vérification…")
        } else if lower.starts_with("writing manifest") {
            ("Writing manifest…", "Écriture du manifeste…")
        } else if lower.starts_with("removing") {
            ("Cleaning up…", "Nettoyage…")
        } else if lower.starts_with("using existing layer") || lower.starts_with("creating new layer") || lower.starts_with("using autodetected") {
            ("Preparing layers…", "Préparation des couches…")
        } else if lower == "success" {
            ("Completed", "Terminé")
        } else {
            return status.to_owned();
        };
        self.pick(en, fr)
    }

    pub fn remaining(&self, duration: Duration) -> String {
        match self.lang {
            Lang::En => format!("{} remaining", self.duration(duration)),
            Lang::Fr => format!("Temps restant : {}", self.duration(duration)),
        }
    }

    pub fn completed_in(&self, duration: Duration) -> String {
        match self.lang {
            Lang::En => format!("Completed in {}", self.duration(duration)),
            Lang::Fr => format!("Terminé en {}", self.duration(duration)),
        }
    }

    pub fn cancelled(&self) -> String {
        self.pick("Cancelled", "Annulé")
    }

    // Discover

    pub fn library_stats(&self, pulls: Option<&str>, tags: Option<&str>, updated: Option<&str>) -> String {
        let mut parts = Vec::new();
        if let Some(pulls) = pulls {
            parts.push(match self.lang {
                Lang::En => format!("{pulls} pulls"),
                Lang::Fr => format!("{} téléchargements", self.site_count(pulls)),
            });
        }
        if let Some(tags) = tags {
            parts.push(if tags == "1" { "1 tag".into() } else { format!("{tags} tags") });
        }
        if let Some(updated) = updated {
            parts.push(self.site_date(updated));
        }
        parts.join(" · ")
    }

    // Values read from ollama.com, which is in English.

    /// `21.4M` → `21,4 M`.
    pub fn site_count(&self, text: &str) -> String {
        match self.lang {
            Lang::En => text.to_owned(),
            Lang::Fr => {
                let text = text.replace('.', ",");
                match text.char_indices().find(|(_, c)| c.is_ascii_alphabetic()) {
                    Some((index, _)) => format!("{}\u{202f}{}", &text[..index], &text[index..]),
                    None => text,
                }
            }
        }
    }

    /// `2 weeks ago` → `il y a 2 semaines`.
    pub fn site_date(&self, text: &str) -> String {
        use std::sync::LazyLock;
        static AGO: LazyLock<regex::Regex> =
            LazyLock::new(|| regex::Regex::new(r"(?i)^(\d+|an?|one)\s+(second|minute|hour|day|week|month|year)s?\s+ago$").expect("regex"));
        if self.lang == Lang::En {
            return text.to_owned();
        }
        let text = text.trim();
        if text.eq_ignore_ascii_case("yesterday") {
            return "hier".into();
        }
        let Some(captures) = AGO.captures(text) else { return text.to_owned() };
        let count: u64 = captures[1].parse().unwrap_or(1);
        let plural = count > 1;
        let unit = match captures[2].to_lowercase().as_str() {
            "second" => {
                if plural {
                    "secondes"
                } else {
                    "seconde"
                }
            }
            "minute" => {
                if plural {
                    "minutes"
                } else {
                    "minute"
                }
            }
            "hour" => {
                if plural {
                    "heures"
                } else {
                    "heure"
                }
            }
            "day" => {
                if plural {
                    "jours"
                } else {
                    "jour"
                }
            }
            "week" => {
                if plural {
                    "semaines"
                } else {
                    "semaine"
                }
            }
            "month" => "mois",
            _ => {
                if plural {
                    "ans"
                } else {
                    "an"
                }
            }
        };
        format!("il y a {count} {unit}")
    }

    /// Download size (`5.2GB` → `5,2 Go`), or the usage level of cloud models.
    pub fn site_size(&self, text: &str) -> String {
        use std::sync::LazyLock;
        static SIZE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"(?i)^([\d.]+)\s*(B|KB|MB|GB|TB)$").expect("regex"));
        if self.lang == Lang::En {
            return text.to_owned();
        }
        if let Some(captures) = SIZE.captures(text.trim()) {
            let unit = match captures[2].to_uppercase().as_str() {
                "B" => "o",
                "KB" => "Ko",
                "MB" => "Mo",
                "GB" => "Go",
                _ => "To",
            };
            return format!("{} {unit}", captures[1].replace('.', ","));
        }
        match text.trim().to_lowercase().as_str() {
            "low usage" => "Utilisation faible".into(),
            "medium usage" => "Utilisation moyenne".into(),
            "high usage" => "Utilisation élevée".into(),
            "extra high usage" => "Utilisation très élevée".into(),
            _ => text.to_owned(),
        }
    }

    /// Accepted inputs: `Text, Image input` → `Texte, image`.
    pub fn site_input(&self, text: &str) -> String {
        if self.lang == Lang::En {
            return text.to_owned();
        }
        let list = text.trim().trim_end_matches(" input").trim_end_matches(" Input");
        list.split(',')
            .map(|item| match item.trim().to_lowercase().as_str() {
                "text" => "texte".to_owned(),
                "image" => "image".to_owned(),
                "audio" => "audio".to_owned(),
                "video" => "vidéo".to_owned(),
                other => other.to_owned(),
            })
            .enumerate()
            .map(|(index, item)| if index == 0 { capitalize(&item) } else { item })
            .collect::<Vec<_>>()
            .join(", ")
    }

    // Playground

    pub fn hint_cloud(&self) -> String {
        self.pick(
            "Cloud model: runs on ollama.com and requires signing in with ollama signin.",
            "Modèle cloud : il s’exécute sur ollama.com et nécessite une connexion avec ollama signin.",
        )
    }

    pub fn hint_load(&self, seconds: u64) -> String {
        match self.lang {
            Lang::En => format!("The first message loads the model into memory; it stays loaded for {} after the last reply.", self.keep_alive_label(seconds)),
            Lang::Fr => format!("Le premier message charge le modèle en mémoire ; il y reste {} après la dernière réponse.", self.keep_alive_label(seconds)),
        }
    }

    pub fn chat_stats(&self, tokens_per_second: Option<f64>, eval_count: Option<u64>, total: Option<Duration>, load: Option<Duration>) -> String {
        let mut parts = Vec::new();
        if let Some(speed) = tokens_per_second.filter(|_| eval_count.unwrap_or(0) > 1) {
            let speed = format!("{speed:.1}");
            parts.push(format!("{} tokens/s", if self.lang == Lang::Fr { speed.replace('.', ",") } else { speed }));
        }
        if let Some(count) = eval_count {
            parts.push(if count == 1 { "1 token".into() } else { format!("{count} tokens") });
        }
        if let Some(total) = total {
            parts.push(self.duration(total));
        }
        if let Some(load) = load.filter(|l| l.as_millis() > 500) {
            parts.push(match self.lang {
                Lang::En => format!("loaded in {}", self.duration(load)),
                Lang::Fr => format!("chargé en {}", self.duration(load)),
            });
        }
        parts.join(" · ")
    }

    // Settings

    pub fn connects_to(&self, url: &str) -> String {
        match self.lang {
            Lang::En => format!("Connects to {url}"),
            Lang::Fr => format!("Se connecte à {url}"),
        }
    }

    pub fn invalid_address(&self) -> String {
        self.pick("This isn't a valid address.", "Cette adresse n’est pas valide.")
    }

    pub fn new_server(&self) -> String {
        self.pick("New Server", "Nouveau serveur")
    }
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_from_ollama_com_in_french() {
        let fr = Text { lang: Lang::Fr };
        assert_eq!(fr.site_date("2 weeks ago"), "il y a 2 semaines");
        assert_eq!(fr.site_date("a month ago"), "il y a 1 mois");
        assert_eq!(fr.site_date("11 months ago"), "il y a 11 mois");
        assert_eq!(fr.site_date("1 year ago"), "il y a 1 an");
        assert_eq!(fr.site_date("Updated recently"), "Updated recently");
        assert_eq!(fr.site_size("5.2GB"), "5,2 Go");
        assert_eq!(fr.site_size("Extra High Usage"), "Utilisation très élevée");
        assert_eq!(fr.site_input("Text, Image input"), "Texte, image");
        assert_eq!(fr.site_count("21.4M"), "21,4\u{202f}M");
        let en = Text { lang: Lang::En };
        assert_eq!(en.site_date("2 weeks ago"), "2 weeks ago");
        assert_eq!(en.site_size("5.2GB"), "5.2GB");
    }
}
