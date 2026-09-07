use serde::{Deserialize, Serialize};
use std::{env, fs, os::unix::fs::PermissionsExt, path::PathBuf, str::FromStr};

const DEFAULT_CLEANUP_PROMPT: &str = "Transform the transcript into clean dictated text. Preserve its meaning and language, never answer it, and return only the final text.";

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Config {
    pub behavior: Behavior,
    pub backend: Backend,
    pub cleanup: Cleanup,
    pub shortcut: Shortcut,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default)]
pub struct Shortcut {
    pub keys: Vec<String>,
    pub consumed: Vec<String>,
}

impl Default for Shortcut {
    fn default() -> Self {
        Self {
            keys: vec!["ISO_Level3_Shift".into(), "Menu".into()],
            consumed: vec!["Menu".into()],
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct Behavior {
    pub models_configured: bool,
    pub double_tap_ms: u64,
    pub success_visible_ms: u64,
    pub clipboard_result_visible_ms: u64,
    pub error_visible_ms: u64,
    pub notice_visible_ms: u64,
    pub history_limit: usize,
    pub training_log_enabled: bool,
    pub max_recording_seconds: u64,
    pub reduced_motion: bool,
    pub meter_gate_db: i32,
    pub duck_audio_percent: u8,
    pub paste_mode: PasteMode,
    pub keep_models_loaded: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum PasteMode {
    #[default]
    Auto,
    CtrlV,
    ShiftInsert,
    Clipboard,
}

impl PasteMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::CtrlV => "ctrl-v",
            Self::ShiftInsert => "shift-insert",
            Self::Clipboard => "clipboard",
        }
    }
}

impl FromStr for PasteMode {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "auto" => Ok(Self::Auto),
            "ctrl-v" => Ok(Self::CtrlV),
            "shift-insert" => Ok(Self::ShiftInsert),
            "clipboard" => Ok(Self::Clipboard),
            _ => Err(()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default)]
pub struct Backend {
    pub engine: String,
    pub status_timeout_ms: u64,
    pub endpoint: String,
    pub model: String,
    pub language: String,
    pub health_endpoint: String,
    pub device: String,
    /// Never serialized: `omaflow effective-config` and the panel state file
    /// are both read by other processes, and a bearer token belongs in neither.
    #[serde(skip_serializing)]
    pub api_key: String,
    pub live_segment_seconds: u64,
    pub live_segment_tiers: Vec<SegmentTier>,
}

/// An extra live-segment rule: once a segment has grown to `seconds`, a pause
/// of only `pause_ms` is enough to cut it. Empty means the single base rule.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct SegmentTier {
    pub seconds: u64,
    pub pause_ms: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct Cleanup {
    pub enabled: bool,
    pub endpoint: String,
    pub model: String,
    pub timeout_seconds: u64,
    pub keep_alive: String,
    pub think: bool,
    pub temperature: f64,
    pub context_max_chars: usize,
    pub num_ctx: i64,
    pub num_predict: i64,
    pub stop_sequences: Vec<String>,
    pub use_window_context: bool,
    pub use_clipboard_context: bool,
    pub custom_vocabulary: Vec<String>,
    pub guard_retry: bool,
    #[serde(skip_serializing)]
    pub api_key: String,
    pub system_prompt: String,
    #[serde(skip_serializing)]
    pub style: String,
}

impl Default for Behavior {
    fn default() -> Self {
        Self {
            models_configured: true,
            double_tap_ms: 260,
            success_visible_ms: 1_400,
            clipboard_result_visible_ms: 5_000,
            error_visible_ms: 5_000,
            notice_visible_ms: 5_000,
            history_limit: 30,
            training_log_enabled: false,
            max_recording_seconds: 1_200,
            reduced_motion: false,
            keep_models_loaded: true,
            meter_gate_db: -60,
            duck_audio_percent: 70,
            paste_mode: PasteMode::Auto,
        }
    }
}

impl Default for Backend {
    fn default() -> Self {
        Self {
            engine: "parakeet".into(),
            status_timeout_ms: 60_000,
            endpoint: "http://127.0.0.1:18103/v1/audio/transcriptions".into(),
            model: "parakeet-tdt-0.6b-v3".into(),
            language: "auto".into(),
            health_endpoint: String::new(),
            device: "cuda".into(),
            api_key: String::new(),
            live_segment_seconds: 20,
            live_segment_tiers: Vec::new(),
        }
    }
}

impl Backend {
    pub fn managed(&self) -> bool {
        matches!(self.engine.as_str(), "nemo" | "parakeet")
    }
    pub fn nemo_model(&self) -> &str {
        if self.model == "parakeet-tdt-0.6b-v3" {
            "nvidia/parakeet-tdt-0.6b-v3"
        } else {
            &self.model
        }
    }
    pub fn listen_address(&self) -> Result<(&str, u16), String> {
        let authority = self
            .endpoint
            .strip_prefix("http://")
            .and_then(|url| url.split_once('/'))
            .map(|(host, _)| host);
        if let Some((host, port)) = authority.and_then(|host| host.rsplit_once(':'))
            && matches!(host, "127.0.0.1" | "localhost")
            && let Ok(port @ 1..) = port.parse::<u16>()
        {
            return Ok((host, port));
        }
        Err("Managed NeMo needs an http://127.0.0.1:PORT/... speech endpoint".into())
    }
}

impl Default for Cleanup {
    fn default() -> Self {
        Self {
            enabled: false,
            endpoint: "http://127.0.0.1:11434/api/chat".into(),
            model: "gemma4:e4b".into(),
            timeout_seconds: 30,
            keep_alive: "24h".into(),
            think: false,
            temperature: 0.0,
            context_max_chars: 4_000,
            num_ctx: 16_384,
            num_predict: -1,
            stop_sequences: vec!["</think>".into()],
            use_window_context: true,
            use_clipboard_context: false,
            custom_vocabulary: Vec::new(),
            guard_retry: true,
            api_key: String::new(),
            system_prompt: DEFAULT_CLEANUP_PROMPT.into(),
            style: "natural".into(),
        }
    }
}

impl Config {
    pub fn path() -> PathBuf {
        env::var_os("OMAFLOW_CONFIG")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                let base = env::var_os("XDG_CONFIG_HOME")
                    .map(PathBuf::from)
                    .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
                    .unwrap_or_else(|| PathBuf::from("."));
                base.join("omaflow/config.toml")
            })
    }

    pub fn load() -> Result<Self, String> {
        let path = Self::path();
        let mut merged: toml::Value = toml::from_str(include_str!("../config/config.toml"))
            .map_err(|error| format!("invalid bundled OmaFlow defaults: {error}"))?;
        if path.exists() {
            let text = fs::read_to_string(&path)
                .map_err(|e| format!("could not read {}: {e}", path.display()))?;
            let overrides: toml::Value =
                toml::from_str(&text).map_err(|e| format!("invalid {}: {e}", path.display()))?;
            merge_toml(&mut merged, overrides);
        }
        let config: Self = merged
            .try_into()
            .map_err(|error| format!("invalid effective OmaFlow configuration: {error}"))?;
        config.validate()?;
        Ok(config)
    }

    pub fn write_behavior_preferences(
        meter_gate_db: i32,
        paste_mode: PasteMode,
    ) -> Result<(), String> {
        Self::write_values(&[
            (
                "behavior",
                "meter_gate_db",
                toml::Value::Integer(i64::from(meter_gate_db.clamp(-70, -35))),
            ),
            (
                "behavior",
                "paste_mode",
                toml::Value::String(paste_mode.as_str().into()),
            ),
        ])
    }

    pub fn write_custom_vocabulary(vocabulary: &[String]) -> Result<(), String> {
        Self::write_values(&[(
            "cleanup",
            "custom_vocabulary",
            toml::Value::Array(
                vocabulary
                    .iter()
                    .cloned()
                    .map(toml::Value::String)
                    .collect(),
            ),
        )])
    }

    pub fn save_setting(key: &str, value: serde_json::Value) -> Result<Self, String> {
        if key == "shortcut" {
            let shortcut: Shortcut = serde_json::from_value(value).map_err(|e| e.to_string())?;
            Self::write_values(&[
                (
                    "shortcut",
                    "keys",
                    toml::Value::try_from(shortcut.keys).map_err(|e| e.to_string())?,
                ),
                (
                    "shortcut",
                    "consumed",
                    toml::Value::try_from(shortcut.consumed).map_err(|e| e.to_string())?,
                ),
            ])?;
            return Self::load();
        }
        if key == "models" {
            let fields = value.as_object().ok_or("Expected model settings")?;
            if fields.is_empty() {
                return Err("No model settings supplied".into());
            }
            let mut updates = Vec::new();
            for (key, value) in fields {
                let (section, field) = match key.as_str() {
                    "cleanup_model" => ("cleanup", "model"),
                    "cleanup_endpoint" => ("cleanup", "endpoint"),
                    "cleanup_api_key" => ("cleanup", "api_key"),
                    "speech_api_key" => ("backend", "api_key"),
                    "speech_engine" => ("backend", "engine"),
                    "speech_model" => ("backend", "model"),
                    "speech_endpoint" => ("backend", "endpoint"),
                    "speech_health_endpoint" => ("backend", "health_endpoint"),
                    "speech_language" => ("backend", "language"),
                    "speech_device" => ("backend", "device"),
                    _ => return Err(format!("Unknown model setting: {key}")),
                };
                updates.push((
                    section,
                    field,
                    toml::Value::String(
                        value
                            .as_str()
                            .ok_or("Model settings must be text")?
                            .trim()
                            .into(),
                    ),
                ));
            }
            Self::write_values(&updates)?;
            return Self::load();
        }
        if key == "enabled" {
            let enabled = value.as_bool().ok_or("Cleanup must be on or off")?;
            // replace_toml_key drops any stored `style` key alongside this write.
            Self::write_values(&[("cleanup", "enabled", toml::Value::Boolean(enabled))])?;
            return Self::load();
        }
        if key == "style" && !matches!(value.as_str(), Some("natural" | "verbatim")) {
            return Err("Choose natural or verbatim dictation".into());
        }
        let section = match key {
            "models_configured"
            | "training_log_enabled"
            | "history_limit"
            | "reduced_motion"
            | "duck_audio_percent"
            | "keep_models_loaded" => "behavior",
            "enabled" | "use_window_context" | "use_clipboard_context" | "style" => "cleanup",
            _ => return Err("Unknown setting".into()),
        };
        let value = toml::Value::try_from(value).map_err(|e| e.to_string())?;
        Self::write_values(&[(section, key, value)])?;
        Self::load()
    }

    pub fn initialize() -> Result<Self, String> {
        Self::write_values(&[])?;
        Self::load()
    }

    fn write_values(values: &[(&str, &str, toml::Value)]) -> Result<(), String> {
        let path = Self::path();
        let mut text = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(error) => return Err(error.to_string()),
        };
        text = complete_config(&text)?;
        for (section, key, value) in values {
            text = replace_toml_key(&text, section, key, &value.to_string())?;
        }
        let mut merged: toml::Value =
            toml::from_str(include_str!("../config/config.toml")).map_err(|e| e.to_string())?;
        merge_toml(
            &mut merged,
            toml::from_str(&text).map_err(|e| e.to_string())?,
        );
        let config: Config = merged
            .try_into()
            .map_err(|e| format!("Invalid setting: {e}"))?;
        config.validate()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let temporary = path.with_extension("toml.tmp");
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|e| e.to_string())?;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
        file.write_all(text.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        fs::rename(&temporary, &path).map_err(|e| e.to_string())
    }

    fn validate(&self) -> Result<(), String> {
        let keys = &self.shortcut.keys;
        if keys.is_empty()
            || keys.len() > 4
            || keys.iter().enumerate().any(|(i, k)| {
                k.is_empty()
                    || k.len() > 80
                    || !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                    || keys[..i].contains(k)
            })
            || self.shortcut.consumed.iter().any(|k| !keys.contains(k))
        {
            return Err("Shortcut needs one to four distinct XKB key names; consumed keys must belong to it".into());
        }
        if !(1..=5_000).contains(&self.behavior.double_tap_ms)
            || !(1..=3_600).contains(&self.behavior.max_recording_seconds)
            || self.behavior.success_visible_ms > 60_000
            || self.behavior.error_visible_ms > 60_000
            || self.behavior.notice_visible_ms > 60_000
            || !(100..=300_000).contains(&self.backend.status_timeout_ms)
            || !(1..=300).contains(&self.cleanup.timeout_seconds)
        {
            return Err("Invalid timing: use a 1–5000 ms double-tap window, 1–3600 second recording limit, and bounded model timeouts".into());
        }
        if !["nemo", "parakeet", "openai", "whisper-cpp"].contains(&self.backend.engine.as_str()) {
            return Err("Speech engine must be parakeet, nemo, openai or whisper-cpp".into());
        }
        // whisper-server takes no model field, and OmaFlow never sends one to
        // it, so demanding a name there would be asking for an unused answer.
        let speech_model_optional = self.backend.engine == "whisper-cpp";
        for (model, optional) in [
            (&self.backend.model, speech_model_optional),
            (&self.cleanup.model, false),
        ] {
            if optional && model.is_empty() {
                continue;
            }
            if model.trim().is_empty()
                || model.len() > 512
                || model.chars().any(char::is_control)
                || model.starts_with('-')
            {
                return Err("Enter a model name or path, up to 512 characters".into());
            }
        }
        // A newline here would let a key smuggle a second HTTP header in.
        for key in [&self.backend.api_key, &self.cleanup.api_key] {
            if key.len() > 4_096 || key.chars().any(|c| c.is_control() || c == '"') {
                return Err(
                    "An API key must be one line of at most 4096 characters, without quotes".into(),
                );
            }
        }
        if self.backend.live_segment_seconds != 0
            && !(5..=600).contains(&self.backend.live_segment_seconds)
        {
            return Err("Live transcription segments must be 0 (off) or 5–600 seconds".into());
        }
        let mut previous = (self.backend.live_segment_seconds, 700_u64);
        for tier in &self.backend.live_segment_tiers {
            if tier.seconds <= previous.0 || tier.pause_ms >= previous.1 || tier.pause_ms < 100 {
                return Err(format!(
                    "backend.live_segment_tiers must rise in seconds and fall in pause_ms (at least 100) after ({} s, {} ms); got ({} s, {} ms)",
                    previous.0, previous.1, tier.seconds, tier.pause_ms
                ));
            }
            previous = (tier.seconds, tier.pause_ms);
        }
        if !["cpu", "cuda", "auto", "vulkan", "metal"].contains(&self.backend.device.as_str()) {
            return Err("Speech device must be auto, cpu, cuda, vulkan or metal".into());
        }
        if self.backend.managed() {
            self.backend.listen_address()?;
            // The health probe is derived by splitting the endpoint on /v1/,
            // so an endpoint without it saves fine and then never reports ready.
            if !self.backend.endpoint.contains("/v1/") {
                return Err("A managed NeMo speech endpoint must contain /v1/, as in http://127.0.0.1:18103/v1/audio/transcriptions".into());
            }
            // Managed NeMo answers on its own derived /health. A URL left over
            // from another server would otherwise keep deciding whether it runs.
            if !self.backend.health_endpoint.is_empty() {
                return Err(
                    "Managed NeMo has no separate health endpoint; clear it or choose another speech engine"
                        .into(),
                );
            }
        }
        if !self.backend.health_endpoint.is_empty()
            && !(self.backend.health_endpoint.starts_with("http://")
                || self.backend.health_endpoint.starts_with("https://"))
        {
            return Err("Speech health endpoint must be HTTP or HTTPS".into());
        }
        if !self.cleanup.endpoint.ends_with("/api/chat") {
            return Err("Ollama cleanup endpoint must end in /api/chat".into());
        }
        if self.backend.language.is_empty()
            || self.backend.language.len() > 32
            || !self
                .backend
                .language
                .chars()
                .all(|c| c.is_ascii_alphabetic() || c == '-')
        {
            return Err("Use auto or a speech language code".into());
        }
        for endpoint in [
            &self.backend.endpoint,
            &self.cleanup.endpoint,
            &self.backend.health_endpoint,
        ] {
            if endpoint.is_empty() {
                continue;
            }
            if endpoint.len() > 2048 || endpoint.chars().any(char::is_whitespace) {
                return Err(
                    "Model URLs must not contain whitespace or exceed 2048 characters".into(),
                );
            }
            if !(endpoint.starts_with("http://") || endpoint.starts_with("https://")) {
                return Err("Model endpoints must be HTTP or HTTPS URLs".into());
            }
        }
        if self.behavior.duck_audio_percent > 100 {
            return Err("Duck other audio by 0 to 100 percent".into());
        }
        if self.behavior.history_limit > 1000 {
            return Err("Keep at most 1000 dictations".into());
        }
        if !["natural", "verbatim"].contains(&self.cleanup.style.as_str()) {
            return Err("Choose natural or verbatim dictation".into());
        }
        Ok(())
    }
}

fn merge_toml(base: &mut toml::Value, overrides: toml::Value) {
    match (base, overrides) {
        (toml::Value::Table(base), toml::Value::Table(overrides)) => {
            for (key, value) in overrides {
                if let Some(existing) = base.get_mut(&key) {
                    merge_toml(existing, value);
                } else {
                    base.insert(key, value);
                }
            }
        }
        (base, value) => *base = value,
    }
}

fn complete_config(text: &str) -> Result<String, String> {
    let mut document = text
        .parse::<toml_edit::DocumentMut>()
        .map_err(|e| e.to_string())?;
    // A hand-written shortcut Lua file seeds [shortcut] before defaults fill the table.
    if document.get("shortcut").is_none() {
        let base = env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".config")
            });
        let legacy = base.join("hypr/omaflow-hotkey.lua");
        if legacy.is_file() {
            let lua = fs::read_to_string(legacy).map_err(|e| e.to_string())?;
            for (field, variable) in [
                ("keys", "local omaflow_hotkey"),
                ("consumed", "local omaflow_consumed_keys"),
            ] {
                if let Some(line) = lua
                    .lines()
                    .find(|line| line.trim_start().starts_with(variable))
                {
                    let values: toml_edit::Array = line
                        .split('"')
                        .enumerate()
                        .filter(|(i, _)| i % 2 == 1)
                        .map(|(_, s)| s)
                        .collect();
                    document["shortcut"][field] = toml_edit::value(values);
                }
            }
        }
    }
    if let Some(cleanup) = document
        .get_mut("cleanup")
        .and_then(toml_edit::Item::as_table_mut)
    {
        if cleanup.get("style").and_then(toml_edit::Item::as_str) == Some("verbatim") {
            cleanup["enabled"] = toml_edit::value(false);
        }
        cleanup.remove("style");
    }
    let defaults = include_str!("../config/config.toml")
        .parse::<toml_edit::DocumentMut>()
        .map_err(|e| e.to_string())?;
    for (section, item) in defaults.iter() {
        if document.get(section).is_none() {
            document[section] = item.clone();
            continue;
        }
        if let (Some(target), Some(source)) = (document[section].as_table_mut(), item.as_table()) {
            for (key, value) in source.iter() {
                if !target.contains_key(key) {
                    target[key] = value.clone();
                }
            }
        }
    }
    Ok(document.to_string())
}

fn replace_toml_key(text: &str, section: &str, key: &str, value: &str) -> Result<String, String> {
    let mut document = text
        .parse::<toml_edit::DocumentMut>()
        .map_err(|e| e.to_string())?;
    let parsed = format!("value = {value}")
        .parse::<toml_edit::DocumentMut>()
        .map_err(|e| e.to_string())?;
    document[section][key] = parsed["value"].clone();
    if section == "cleanup"
        && key == "enabled"
        && let Some(table) = document[section].as_table_mut()
    {
        table.remove("style");
    }
    let updated = document.to_string();
    toml::from_str::<toml::Value>(&updated).map_err(|e| e.to_string())?;
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use super::{Config, replace_toml_key};

    #[test]
    fn unknown_cleanup_keys_are_ignored() {
        let config: Config = toml::from_str(
            "[cleanup]\nstyle = 'natural'\n[cleanup.snippets]\ncue = 'saved text'\n[cleanup.app_styles]\nbrowser = 'casual'\n",
        ).unwrap();
        assert_eq!(config.cleanup.style, "natural");
        assert!(config.validate().is_ok());
        let serialized = serde_json::to_value(&config).unwrap();
        assert!(serialized["cleanup"].get("snippets").is_none());
        assert!(serialized["cleanup"].get("app_styles").is_none());
    }

    #[test]
    fn rejects_unbounded_timing_and_invalid_style() {
        let mut config = Config::default();
        config.behavior.max_recording_seconds = u64::MAX;
        assert!(config.validate().is_err());
        config.behavior.max_recording_seconds = 1200;
        config.cleanup.style = "invalid".into();
        assert!(config.validate().is_err());
    }

    #[test]
    fn safely_replaces_multiline_vocabulary() {
        let source = "[cleanup] # comment\ncustom_vocabulary = [\n  \"Alice\",\n  \"Bob\",\n]\nsystem_prompt = '''\n[section-like prompt]\n'''\n";
        let updated =
            replace_toml_key(source, "cleanup", "custom_vocabulary", "[\"Charlie\"]").unwrap();
        let value: toml::Value = toml::from_str(&updated).unwrap();
        assert_eq!(
            value["cleanup"]["custom_vocabulary"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            value["cleanup"]["custom_vocabulary"][0].as_str(),
            Some("Charlie")
        );
        assert!(
            value["cleanup"]["system_prompt"]
                .as_str()
                .unwrap()
                .contains("[section-like prompt]")
        );
    }

    #[test]
    fn updates_one_key_without_rewriting_the_rest_of_the_config() {
        let source = "[behavior]\n# Keep this comment.\nmeter_gate_db = -60\n\n[cleanup]\nsystem_prompt = '''\n[not-a-real-section]\n'''\n";
        let updated = replace_toml_key(source, "behavior", "meter_gate_db", "-48").unwrap();

        assert!(updated.contains("# Keep this comment.\nmeter_gate_db = -48"));
        assert!(updated.contains("system_prompt = '''\n[not-a-real-section]\n'''"));
    }

    #[test]
    fn adds_a_missing_section_for_personal_overrides() {
        let text = "[behavior]\nmeter_gate_db = -60\n";
        let updated = replace_toml_key(
            text,
            "cleanup",
            "custom_vocabulary",
            "[\"OmaFlow\", \"Tobi Lütke\"]",
        )
        .unwrap();
        let value: toml::Value = toml::from_str(&updated).unwrap();
        assert_eq!(
            value["cleanup"]["custom_vocabulary"][1].as_str(),
            Some("Tobi Lütke")
        );
    }

    #[test]
    fn rejects_speech_endpoints_a_health_probe_could_never_follow() {
        let mut config = Config::default();
        config.backend.engine = "nemo".into();
        config.backend.endpoint = "http://127.0.0.1:18103/transcribe".into();
        assert!(config.validate().unwrap_err().contains("/v1/"));

        config.backend.endpoint = "http://127.0.0.1:18103/v1/audio/transcriptions".into();
        assert!(config.validate().is_ok());

        // A URL left behind by another engine must not answer for NeMo.
        config.backend.health_endpoint = "http://127.0.0.1:8080/health".into();
        assert!(config.validate().unwrap_err().contains("health endpoint"));
        config.backend.health_endpoint = String::new();

        // whisper-server takes no model name, so requiring one is asking for
        // an answer that is never sent.
        config.backend.engine = "whisper-cpp".into();
        config.backend.endpoint = "http://127.0.0.1:8080/inference".into();
        config.backend.model = String::new();
        assert!(config.validate().is_ok());
        config.backend.engine = "openai".into();
        assert!(config.validate().is_err());
    }

    #[test]
    fn api_keys_are_bounded_and_never_serialized() {
        let mut config = Config::default();
        config.backend.api_key = "sk-test".into();
        config.cleanup.api_key = "sk-other".into();
        assert!(config.validate().is_ok());
        let serialized = serde_json::to_value(&config).unwrap();
        assert!(serialized["backend"].get("api_key").is_none());
        assert!(serialized["cleanup"].get("api_key").is_none());

        config.backend.api_key = "sk\nX-Injected: yes".into();
        assert!(config.validate().is_err());
    }

    #[test]
    fn production_config_contains_the_full_cleanup_contract() {
        let config: Config = toml::from_str(include_str!("../config/config.toml")).unwrap();
        let prompt = config.cleanup.system_prompt.to_lowercase();

        assert!(prompt.contains("never answer"));
        assert!(prompt.contains("spoken formatting commands"));
        assert!(prompt.contains("introductory phrase"));
        assert!(prompt.contains("preserve every language"));
        assert!(prompt.contains("never translate"));
        assert!(prompt.contains("only fillers or silence"));
        assert_eq!(config.cleanup.temperature, 0.0);
        assert_eq!(config.cleanup.num_ctx, 16_384);
        assert_eq!(config.cleanup.model, "gemma4:e4b");
        assert!(!config.cleanup.enabled);
    }
}
