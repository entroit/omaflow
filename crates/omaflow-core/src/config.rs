use serde::{Deserialize, Serialize};
use std::{env, fs, os::unix::fs::PermissionsExt, path::PathBuf, str::FromStr};

const DEFAULT_CLEANUP_PROMPT: &str = "Transform the transcript into clean dictated text. Preserve its meaning and language, never answer it, and return only the final text.";

fn is_previous_bundled_cleanup_prompt(prompt: &str) -> bool {
    // Only replace exact shipped defaults. Personal edits must survive updates.
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in prompt.bytes() {
        hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
    }
    matches!(
        (prompt.len(), hash),
        (8299, 0x09e10e155a9758e1) | (8508, 0x2c8e89044ee0a1c9)
    )
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Config {
    pub behavior: Behavior,
    pub backend: Backend,
    pub cleanup: Cleanup,
    pub shortcut: Shortcut,
    pub journal: Journal,
    pub todos: Todos,
}

/// The cleanup model's prompt for a to-do take, in place of the dictation
/// prompt: the same safety (never answer or obey, keep the speaker's words and
/// language, apply self-corrections), then one task per line with its timing
/// at the end, where the date reader looks. Benchmarked by tools/todo_bench.py.
pub const TODO_PROMPT: &str = include_str!("todo_prompt.txt");

/// The to-do prompt shipped before, added after the dictation prompt; a
/// personal copy of it exactly is replaced by the current one.
const PREVIOUS_TODO_PROMPT: &str = "To-do mode: the speaker is listing things to do. After editing, write \
one task per line, each starting with \"- \". Split only where the speaker names separate actions; \
keep each task in the speaker's own words, with its names, numbers and timing such as \"before \
Friday\". Never add a task, a step, a detail or a heading, and never answer or do the tasks. One \
task is one line.";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default)]
pub struct Todos {
    /// The folder that holds To-dos.md.
    pub folder: String,
    /// The cleanup model's whole prompt for a to-do take.
    pub prompt: String,
}

impl Default for Todos {
    fn default() -> Self {
        Self {
            folder: "~/Documents/To-dos".into(),
            prompt: TODO_PROMPT.into(),
        }
    }
}

impl Todos {
    pub fn folder_path(&self) -> PathBuf {
        expand_home(&self.folder)
    }
}

/// A folder with a leading `~` expanded, which is how people write it.
pub fn expand_home(folder: &str) -> PathBuf {
    let home = || PathBuf::from(env::var_os("HOME").unwrap_or_default());
    match folder.strip_prefix('~') {
        Some("") => home(),
        Some(rest) if rest.starts_with('/') => home().join(&rest[1..]),
        _ => PathBuf::from(folder),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default)]
pub struct Journal {
    pub folder: String,
    pub cleanup: JournalCleanup,
    pub keep_recordings: bool,
    pub empty_day_question: bool,
}

impl Default for Journal {
    fn default() -> Self {
        Self {
            folder: "~/Documents/Journal".into(),
            cleanup: JournalCleanup::Light,
            keep_recordings: true,
            empty_day_question: false,
        }
    }
}

impl Journal {
    /// The folder with a leading `~` expanded, which is how people write it.
    pub fn folder_path(&self) -> PathBuf {
        expand_home(&self.folder)
    }
}

/// How much a spoken journal entry is tidied before it is written down.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum JournalCleanup {
    Off,
    #[default]
    Light,
    Medium,
}

impl JournalCleanup {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Light => "light",
            Self::Medium => "medium",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default)]
pub struct Shortcut {
    pub keys: Vec<String>,
    pub consumed: Vec<String>,
    /// Hyprland binding that opens or closes the window, such as
    /// "SUPER + SHIFT + V". Empty turns it off.
    pub window: String,
    /// Hyprland binding that starts and saves a journal entry. Empty, the
    /// default, leaves it unbound.
    pub journal: String,
    /// Hyprland binding that opens the window on the journal, or closes it
    /// when the journal is already showing. Empty, the default, leaves it
    /// unbound.
    pub open_journal: String,
    /// Hyprland binding for a to-do take, held like the dictation key.
    /// Empty, the default, leaves it unbound.
    pub todo: String,
    /// Hyprland binding that opens the window on the to-dos, or closes it.
    /// Empty, the default, leaves it unbound.
    pub open_todos: String,
}

impl Default for Shortcut {
    fn default() -> Self {
        Self {
            keys: vec!["ISO_Level3_Shift".into(), "Menu".into()],
            consumed: vec!["Menu".into()],
            window: "SUPER + SHIFT + V".into(),
            journal: String::new(),
            open_journal: String::new(),
            todo: String::new(),
            open_todos: String::new(),
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
    pub meter_gate_db: i32,
    pub duck_audio_percent: u8,
    pub paste_mode: PasteMode,
    pub paste_shortcut: PasteShortcut,
    pub keep_models_loaded: bool,
    /// Keep each saved dictation's recording so it can be played back.
    pub keep_dictation_audio: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum PasteMode {
    #[default]
    Auto,
    CtrlV,
    ShiftInsert,
    Clipboard,
    Custom,
}

impl PasteMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::CtrlV => "ctrl-v",
            Self::ShiftInsert => "shift-insert",
            Self::Clipboard => "clipboard",
            Self::Custom => "custom",
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
            "custom" => Ok(Self::Custom),
            _ => Err(()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PasteModifier {
    Ctrl,
    Shift,
    Alt,
    Super,
}

impl PasteModifier {
    pub fn as_hyprland(self) -> &'static str {
        match self {
            Self::Ctrl => "CTRL",
            Self::Shift => "SHIFT",
            Self::Alt => "ALT",
            Self::Super => "SUPER",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct PasteShortcut {
    pub modifiers: Vec<PasteModifier>,
    pub key: String,
}

impl Default for PasteShortcut {
    fn default() -> Self {
        Self {
            modifiers: vec![PasteModifier::Ctrl],
            key: "V".into(),
        }
    }
}

impl PasteShortcut {
    pub fn validate(&self) -> Result<(), String> {
        if self.modifiers.is_empty()
            || self.modifiers.len() > 4
            || self
                .modifiers
                .iter()
                .enumerate()
                .any(|(index, modifier)| self.modifiers[..index].contains(modifier))
        {
            return Err("A custom paste shortcut needs one to four distinct modifiers".into());
        }
        if self.key.is_empty()
            || self.key.len() > 80
            || !self
                .key
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || character == '_')
        {
            return Err(
                "The custom paste key must be an XKB key name using letters, numbers or underscore"
                    .into(),
            );
        }
        Ok(())
    }

    pub fn hyprland_modifiers(&self) -> String {
        [
            PasteModifier::Ctrl,
            PasteModifier::Shift,
            PasteModifier::Alt,
            PasteModifier::Super,
        ]
        .into_iter()
        .filter(|modifier| self.modifiers.contains(modifier))
        .map(PasteModifier::as_hyprland)
        .collect::<Vec<_>>()
        .join(" ")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct PasteDelivery {
    pub mode: PasteMode,
    pub shortcut: PasteShortcut,
}

impl Behavior {
    pub fn paste_delivery(&self) -> PasteDelivery {
        PasteDelivery {
            mode: self.paste_mode,
            shortcut: self.paste_shortcut.clone(),
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
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct Cleanup {
    pub enabled: bool,
    /// With the model off, still drop fillers such as "um" and stutters.
    pub light: bool,
    pub engine: String,
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
    #[serde(skip_serializing)]
    pub api_key: String,
    pub system_prompt: String,
    #[serde(skip_serializing)]
    pub style: String,
}

impl Cleanup {
    /// "off", "light" or "medium": the level the panel shows and sets.
    pub fn level(&self) -> &'static str {
        if self.enabled {
            "medium"
        } else if self.light {
            "light"
        } else {
            "off"
        }
    }
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
            keep_models_loaded: true,
            keep_dictation_audio: false,
            meter_gate_db: -60,
            duck_audio_percent: 70,
            paste_mode: PasteMode::Auto,
            paste_shortcut: PasteShortcut::default(),
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
            light: false,
            engine: "ollama".into(),
            endpoint: "http://127.0.0.1:11434/api/chat".into(),
            model: "gemma4:e4b".into(),
            timeout_seconds: 30,
            keep_alive: "24h".into(),
            think: false,
            temperature: 0.0,
            context_max_chars: 4_000,
            num_ctx: 16_384,
            num_predict: -1,
            stop_sequences: Vec::new(),
            use_window_context: true,
            use_clipboard_context: false,
            custom_vocabulary: Vec::new(),
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
        let mut merged: toml::Value =
            toml::from_str(include_str!("../../../config/config.toml"))
                .map_err(|error| format!("invalid bundled OmaFlow defaults: {error}"))?;
        let bundled_prompt = merged["cleanup"]["system_prompt"]
            .as_str()
            .unwrap()
            .to_string();
        if path.exists() {
            let text = fs::read_to_string(&path)
                .map_err(|e| format!("could not read {}: {e}", path.display()))?;
            let overrides: toml::Value =
                toml::from_str(&text).map_err(|e| format!("invalid {}: {e}", path.display()))?;
            merge_toml(&mut merged, overrides);
        }
        let mut config: Self = merged
            .try_into()
            .map_err(|error| format!("invalid effective OmaFlow configuration: {error}"))?;
        if is_previous_bundled_cleanup_prompt(&config.cleanup.system_prompt) {
            config.cleanup.system_prompt = bundled_prompt;
        }
        if config.todos.prompt.trim() == PREVIOUS_TODO_PROMPT {
            config.todos.prompt = TODO_PROMPT.trim().to_string();
        }
        if config.cleanup.engine == "ollama"
            && config.cleanup.model.trim_end_matches(":latest") == "gemma4:e4b"
            && config.cleanup.stop_sequences == ["</think>"]
        {
            config.cleanup.stop_sequences.clear();
        }
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
        if key == "paste_delivery" {
            let delivery: PasteDelivery =
                serde_json::from_value(value).map_err(|e| e.to_string())?;
            delivery.shortcut.validate()?;
            return Self::write_values(&[
                (
                    "behavior",
                    "paste_mode",
                    toml::Value::String(delivery.mode.as_str().into()),
                ),
                (
                    "behavior",
                    "paste_shortcut",
                    toml::Value::try_from(delivery.shortcut).map_err(|e| e.to_string())?,
                ),
            ])
            .and_then(|_| Self::load());
        }
        if key == "shortcut" {
            // The window and journal bindings are saved on their own, so only
            // the fields that were sent are written.
            let fields = value.as_object().ok_or("Expected shortcut settings")?;
            let mut updates = Vec::new();
            for field in ["window", "journal", "open_journal", "todo", "open_todos"] {
                if let Some(binding) = fields.get(field) {
                    let binding = binding.as_str().ok_or("Expected a key binding")?;
                    updates.push(("shortcut", field, toml::Value::String(binding.into())));
                }
            }
            if !fields.contains_key("keys") {
                if updates.is_empty() {
                    return Err("No shortcut settings supplied".into());
                }
                Self::write_values(&updates)?;
                return Self::load();
            }
            let shortcut: Shortcut = serde_json::from_value(value).map_err(|e| e.to_string())?;
            updates.push((
                "shortcut",
                "keys",
                toml::Value::try_from(shortcut.keys).map_err(|e| e.to_string())?,
            ));
            updates.push((
                "shortcut",
                "consumed",
                toml::Value::try_from(shortcut.consumed).map_err(|e| e.to_string())?,
            ));
            Self::write_values(&updates)?;
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
                    "cleanup_engine" => ("cleanup", "engine"),
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
        if key == "todos_folder" {
            let folder = value.as_str().ok_or("Enter a folder")?.trim();
            if folder.is_empty()
                || folder.len() > 1024
                || folder.chars().any(char::is_control)
                || !(folder.starts_with('/') || folder.starts_with('~'))
            {
                return Err("Enter a full folder path, such as ~/Documents/To-dos".into());
            }
            Self::write_values(&[("todos", "folder", toml::Value::String(folder.into()))])?;
            return Self::load();
        }
        if let Some(field) = key.strip_prefix("journal_") {
            let value = match field {
                "folder" => {
                    let folder = value.as_str().ok_or("Enter a folder")?.trim();
                    if folder.is_empty()
                        || folder.len() > 1024
                        || folder.chars().any(char::is_control)
                        || !(folder.starts_with('/') || folder.starts_with('~'))
                    {
                        return Err("Enter a full folder path, such as ~/Documents/Journal".into());
                    }
                    toml::Value::String(folder.into())
                }
                "cleanup" => match value.as_str() {
                    Some(level @ ("off" | "light" | "medium")) => toml::Value::String(level.into()),
                    _ => return Err("Choose off, light or medium".into()),
                },
                "keep_recordings" | "empty_day_question" => {
                    toml::Value::Boolean(value.as_bool().ok_or("Expected on or off")?)
                }
                _ => return Err("Unknown setting".into()),
            };
            Self::write_values(&[("journal", field, value)])?;
            return Self::load();
        }
        if key == "cleanup_level" {
            let (enabled, light) = match value.as_str() {
                Some("off") => (false, false),
                Some("light") => (false, true),
                Some("medium") => (true, false),
                _ => return Err("Choose off, light or medium cleanup".into()),
            };
            Self::write_values(&[
                ("cleanup", "enabled", toml::Value::Boolean(enabled)),
                ("cleanup", "light", toml::Value::Boolean(light)),
            ])?;
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
            | "duck_audio_percent"
            | "keep_models_loaded"
            | "keep_dictation_audio" => "behavior",
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
        let mut merged: toml::Value = toml::from_str(include_str!("../../../config/config.toml"))
            .map_err(|e| e.to_string())?;
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
        self.behavior.paste_shortcut.validate()?;
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
        match self.cleanup.engine.as_str() {
            "ollama" if !self.cleanup.endpoint.ends_with("/api/chat") => {
                return Err("Ollama cleanup endpoint must end in /api/chat".into());
            }
            "openai" if !self.cleanup.endpoint.ends_with("/v1/chat/completions") => {
                return Err(
                    "OpenAI-compatible cleanup endpoint must end in /v1/chat/completions".into(),
                );
            }
            "ollama" | "openai" => {}
            _ => return Err("Cleanup engine must be ollama or openai".into()),
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
    let defaults = include_str!("../../../config/config.toml")
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
            // A real [shortcut] table, so the defaults below can fill it in.
            document["shortcut"] = toml_edit::table();
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
        let uses_default_engine = cleanup
            .get("engine")
            .and_then(toml_edit::Item::as_str)
            .is_none_or(|engine| engine == "ollama");
        let uses_gemma = cleanup
            .get("model")
            .and_then(toml_edit::Item::as_str)
            .is_none_or(|model| model.trim_end_matches(":latest") == "gemma4:e4b");
        let obsolete_stop = uses_default_engine
            && uses_gemma
            && cleanup
                .get("stop_sequences")
                .and_then(toml_edit::Item::as_array)
                .is_some_and(|values| {
                    values.len() == 1
                        && values.get(0).and_then(toml_edit::Value::as_str) == Some("</think>")
                });
        if obsolete_stop {
            cleanup.remove("stop_sequences");
        }
        if cleanup
            .get("system_prompt")
            .and_then(toml_edit::Item::as_str)
            .is_some_and(is_previous_bundled_cleanup_prompt)
        {
            cleanup["system_prompt"] = defaults["cleanup"]["system_prompt"].clone();
        }
    }
    if let Some(todos) = document
        .get_mut("todos")
        .and_then(toml_edit::Item::as_table_mut)
        && todos
            .get("prompt")
            .and_then(toml_edit::Item::as_str)
            .is_some_and(|prompt| prompt.trim() == PREVIOUS_TODO_PROMPT)
    {
        todos["prompt"] = defaults["todos"]["prompt"].clone();
    }
    for (section, item) in defaults.iter() {
        if document.get(section).is_none() {
            document[section] = item.clone();
            continue;
        }
        // Older writers left some sections as inline tables; make them real
        // tables so new defaults can be added to them.
        if let Some(inline) = document[section].as_inline_table() {
            let table = inline.clone().into_table();
            document.remove(section);
            document.insert(section, toml_edit::Item::Table(table));
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
    use super::{
        Config, PREVIOUS_TODO_PROMPT, PasteModifier, PasteShortcut, TODO_PROMPT, complete_config,
        replace_toml_key,
    };

    #[test]
    fn custom_paste_shortcut_rejects_unsafe_or_ambiguous_values() {
        let valid = PasteShortcut {
            modifiers: vec![PasteModifier::Shift, PasteModifier::Ctrl],
            key: "F8".into(),
        };
        assert!(valid.validate().is_ok());
        assert_eq!(valid.hyprland_modifiers(), "CTRL SHIFT");

        for key in [
            "",
            "V\" }); os.execute('touch /tmp/pwned') --",
            "V\nX",
            "V X",
        ] {
            let shortcut = PasteShortcut {
                modifiers: vec![PasteModifier::Ctrl],
                key: key.into(),
            };
            assert!(shortcut.validate().is_err());
        }

        let duplicate = PasteShortcut {
            modifiers: vec![PasteModifier::Ctrl, PasteModifier::Ctrl],
            key: "V".into(),
        };
        assert!(duplicate.validate().is_err());
    }

    #[test]
    fn every_setting_is_in_the_shipped_config() {
        // A setting only the code knows about cannot be changed by editing
        // the file, so each one needs a line in config/config.toml.
        let shipped: toml::Value =
            toml::from_str(include_str!("../../../config/config.toml")).unwrap();
        let known = serde_json::to_value(Config::default()).unwrap();
        for (section, values) in known.as_object().unwrap() {
            let Some(values) = values.as_object() else {
                continue;
            };
            for key in values.keys() {
                assert!(
                    shipped
                        .get(section)
                        .and_then(|table| table.get(key))
                        .is_some(),
                    "[{section}] {key} is missing from config/config.toml"
                );
            }
        }
    }

    #[test]
    fn inline_shortcut_table_gains_the_window_and_journal_defaults() {
        let text = complete_config("shortcut = { keys = [\"F9\"], consumed = [] }\n").unwrap();
        assert!(text.contains("[shortcut]\n"), "{text}");
        let value: toml::Value = toml::from_str(&text).unwrap();
        assert_eq!(value["shortcut"]["keys"][0].as_str(), Some("F9"));
        assert_eq!(
            value["shortcut"]["window"].as_str(),
            Some("SUPER + SHIFT + V")
        );
        assert_eq!(value["shortcut"]["journal"].as_str(), Some(""));
        assert_eq!(value["shortcut"]["open_journal"].as_str(), Some(""));
    }

    #[test]
    fn legacy_behavior_gets_a_safe_custom_paste_default() {
        let behavior: super::Behavior = toml::from_str("paste_mode = 'auto'").unwrap();
        assert_eq!(behavior.paste_shortcut, PasteShortcut::default());
    }

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
    fn cleanup_engine_defaults_to_ollama_and_requires_its_matching_path() {
        let mut config = Config::default();
        assert_eq!(config.cleanup.engine, "ollama");
        assert!(config.validate().is_ok());

        config.cleanup.engine = "openai".into();
        assert!(config.validate().is_err());
        config.cleanup.endpoint = "https://gateway.example/v1/chat/completions".into();
        assert!(config.validate().is_ok());

        config.cleanup.engine = "unknown".into();
        assert!(config.validate().is_err());
    }

    #[test]
    fn obsolete_gemma_think_stop_is_removed_from_saved_overrides() {
        let completed =
            complete_config("[cleanup]\nmodel = 'gemma4:e4b'\nstop_sequences = ['</think>']\n")
                .unwrap();
        let config: Config = toml::from_str(&completed).unwrap();
        assert!(config.cleanup.stop_sequences.is_empty());
        assert!(!completed.contains("</think>"));
    }

    #[test]
    fn the_shipped_to_do_prompt_replaces_the_old_one_but_never_a_custom_one() {
        let old = format!("[todos]\nprompt = {:?}\n", PREVIOUS_TODO_PROMPT);
        let completed = complete_config(&old).unwrap();
        let config: Config = toml::from_str(&completed).unwrap();
        assert_eq!(config.todos.prompt.trim(), TODO_PROMPT.trim());
        let custom = complete_config("[todos]\nprompt = 'My own to-do rules'\n").unwrap();
        let config: Config = toml::from_str(&custom).unwrap();
        assert_eq!(config.todos.prompt, "My own to-do rules");
        // The shipped config and the built-in default are the same prompt.
        let shipped: Config = toml::from_str(include_str!("../../../config/config.toml")).unwrap();
        assert_eq!(shipped.todos.prompt.trim(), TODO_PROMPT.trim());
    }

    #[test]
    fn custom_model_think_stop_is_preserved() {
        let completed =
            complete_config("[cleanup]\nmodel = 'custom:model'\nstop_sequences = ['</think>']\n")
                .unwrap();
        let config: Config = toml::from_str(&completed).unwrap();
        assert_eq!(config.cleanup.stop_sequences, ["</think>"]);
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
        let config: Config = toml::from_str(include_str!("../../../config/config.toml")).unwrap();
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
        assert_eq!(config.cleanup.engine, "ollama");
        assert!(!config.cleanup.enabled);
    }
}
