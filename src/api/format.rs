//! Display helpers.

use std::time::Duration;

/// Languages of the interface. Slint picks the same one for its own strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Lang {
    #[default]
    En,
    Fr,
}

impl Lang {
    pub fn from_locale(locale: &str) -> Self {
        if locale.to_lowercase().starts_with("fr") { Lang::Fr } else { Lang::En }
    }
}

/// Byte count in decimal units as Ollama reports sizes, with the precision of
/// macOS: `291.6 MB`, `12.77 GB` (`291,6 Mo`, `12,77 Go` in French).
pub fn bytes(value: u64, lang: Lang) -> String {
    let units: [&str; 5] = match lang {
        Lang::En => ["B", "KB", "MB", "GB", "TB"],
        Lang::Fr => ["o", "Ko", "Mo", "Go", "To"],
    };
    let digits_for = |unit: usize| match unit {
        0 | 1 => 0,
        2 => 1,
        _ => 2,
    };
    let mut size = value as f64;
    let mut unit = 0;
    // Round first: 999.96 MB is shown as 1.00 GB, not 1000.0 MB.
    while unit < units.len() - 1 && {
        let scale = 10f64.powi(digits_for(unit) as i32);
        (size * scale).round() / scale >= 1000.0
    } {
        size /= 1000.0;
        unit += 1;
    }
    let digits = digits_for(unit);
    let number = format!("{size:.digits$}");
    let number = if lang == Lang::Fr { number.replace('.', ",") } else { number };
    format!("{number} {}", units[unit])
}

/// Token counts the way Ollama prints context windows: `8K`, `256K`, `1M`.
pub fn tokens(value: u64) -> String {
    if value >= 1_048_576 && value % 1_048_576 == 0 {
        format!("{}M", value / 1_048_576)
    } else if value >= 1024 {
        format!("{}K", (value as f64 / 1024.0).round() as u64)
    } else {
        value.to_string()
    }
}

/// Parameter counts: `268M`, `4.3B`, `2.8T`.
pub fn parameter_count(value: u64) -> String {
    let number = value as f64;
    let (scaled, suffix) = if number >= 1e12 {
        (number / 1e12, "T")
    } else if number >= 1e9 {
        (number / 1e9, "B")
    } else if number >= 1e6 {
        (number / 1e6, "M")
    } else if number >= 1e3 {
        (number / 1e3, "K")
    } else {
        (number, "")
    };
    let text = if scaled >= 100.0 { format!("{scaled:.0}") } else { format!("{scaled:.1}") };
    format!("{}{suffix}", text.strip_suffix(".0").unwrap_or(&text))
}

/// Numeric value of a parameter size label (`873.44M`, `4.4B`), for sorting.
pub fn parameter_value(label: Option<&str>) -> f64 {
    let Some(text) = label.map(|l| l.trim().to_uppercase()).filter(|l| !l.is_empty()) else { return 0.0 };
    let (number, multiplier) = match text.chars().last() {
        Some('K') => (&text[..text.len() - 1], 1e3),
        Some('M') => (&text[..text.len() - 1], 1e6),
        Some('B') => (&text[..text.len() - 1], 1e9),
        Some('T') => (&text[..text.len() - 1], 1e12),
        _ => (text.as_str(), 1.0),
    };
    number.parse::<f64>().unwrap_or(0.0) * multiplier
}

/// `1 h 05 min`, `4 min 5 s`, `12 s`, `350 ms`.
pub fn duration(duration: Duration) -> String {
    let seconds = duration.as_secs();
    if seconds >= 3600 {
        let minutes = (seconds % 3600) / 60;
        if minutes == 0 { format!("{} h", seconds / 3600) } else { format!("{} h {minutes:02} min", seconds / 3600) }
    } else if seconds >= 60 {
        let rest = seconds % 60;
        if rest == 0 { format!("{} min", seconds / 60) } else { format!("{} min {rest} s", seconds / 60) }
    } else if seconds > 0 {
        format!("{seconds} s")
    } else {
        format!("{} ms", duration.as_millis())
    }
}

/// `3 wk ago`, `il y a 3 sem.`
pub fn relative_time(elapsed: chrono::TimeDelta, lang: Lang) -> String {
    let minutes = elapsed.num_minutes().max(0);
    let hours = elapsed.num_hours();
    let days = elapsed.num_days();
    match lang {
        Lang::En => match () {
            _ if minutes < 1 => "just now".into(),
            _ if hours < 1 => format!("{minutes} min ago"),
            _ if days < 1 => format!("{hours} h ago"),
            _ if days == 1 => "yesterday".into(),
            _ if days < 7 => format!("{days} days ago"),
            _ if days < 31 => format!("{} wk ago", days / 7),
            _ if days < 365 => format!("{} mo ago", days / 30),
            _ => format!("{} yr ago", days / 365),
        },
        Lang::Fr => match () {
            _ if minutes < 1 => "à l’instant".into(),
            _ if hours < 1 => format!("il y a {minutes} min"),
            _ if days < 1 => format!("il y a {hours} h"),
            _ if days == 1 => "hier".into(),
            _ if days < 7 => format!("il y a {days} jours"),
            _ if days < 31 => format!("il y a {} sem.", days / 7),
            _ if days < 365 => format!("il y a {} mois", days / 30),
            _ if days < 730 => "il y a 1 an".into(),
            _ => format!("il y a {} ans", days / 365),
        },
    }
}

/// Long date for tooltips and the details pane: `27 Sep 2026, 21:02` / `27 sept. 2026, 21:02`.
pub fn long_date(date: chrono::DateTime<chrono::Local>, lang: Lang) -> String {
    const EN: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const FR: [&str; 12] = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."];
    use chrono::{Datelike, Timelike};
    let month = match lang {
        Lang::En => EN,
        Lang::Fr => FR,
    }[date.month0() as usize];
    format!("{} {month} {}, {:02}:{:02}", date.day(), date.year(), date.hour(), date.minute())
}
