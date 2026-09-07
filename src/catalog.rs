//! The built-in model catalog: the short, curated list of speech and cleanup
//! models OmaFlow can download and switch to on its own.
//!
//! The list is compiled in rather than fetched, because a dictation tool that
//! cannot reach the network must still be able to tell the user what it can
//! run, and because every entry here is one we have actually tried.
use crate::config::Config;
use crate::process::CommandExt;
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    env, fs,
    io::{BufReader, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::Duration,
};

/// Managed NeMo is the only speech engine the catalog offers; a user who wants
/// their own server still has the free-text fields in Settings → Models.
pub const SPEECH_ENGINE: &str = "nemo";
pub const SPEECH_ENDPOINT: &str = "http://127.0.0.1:18103/v1/audio/transcriptions";
pub const CLEANUP_ENDPOINT: &str = "http://127.0.0.1:11434/api/chat";

#[derive(Debug, Clone, Copy, Serialize)]
pub struct CatalogEntry {
    pub id: &'static str,
    pub label: &'static str,
    pub detail: &'static str,
    /// What the download actually transfers, measured rather than copied off a
    /// model page: the q8_0 GGUF for speech, the sum of an Ollama tag's layers.
    pub size_mb: u32,
    pub hardware: &'static str,
    pub license: &'static str,
    pub tier: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Speech,
    Cleanup,
}

impl Kind {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "speech" => Some(Self::Speech),
            "cleanup" => Some(Self::Cleanup),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Speech => "speech",
            Self::Cleanup => "cleanup",
        }
    }
}

// Exactly the ASR repositories `nemo-speech model list` accepts. Offering a
// model the runtime cannot pull would put a Download button in the panel that
// can only ever fail. Sizes are the q8_0 GGUF, which is the file the runtime
// actually fetches, not the safetensors weights on the model page.
const SPEECH: &[CatalogEntry] = &[
    CatalogEntry {
        id: "nvidia/parakeet-tdt-0.6b-v3",
        label: "Parakeet TDT 0.6B v3",
        detail: "25 European languages, detected automatically. The most accurate of these on English and by far the fastest, which is why it is the default.",
        size_mb: 714,
        hardware: "Under 1 GB of GPU memory idle, about 2 GB after a long recording. Runs on CPU.",
        license: "CC-BY-4.0",
        tier: "recommended",
    },
    CatalogEntry {
        id: "nvidia/nemotron-3.5-asr-streaming-0.6b",
        label: "Nemotron 3.5 Streaming 0.6B",
        detail: "35 languages, including Japanese, Korean, Chinese, Arabic, Hindi and Turkish. Choose it for a language Parakeet does not cover; its English error rate is materially worse.",
        size_mb: 742,
        hardware: "About the same as Parakeet. Runs on CPU.",
        license: "OpenMDW-1.1",
        tier: "quality",
    },
    CatalogEntry {
        id: "nvidia/parakeet-ctc-1.1b",
        label: "Parakeet CTC 1.1B",
        detail: "English only, and the largest model here at nearly twice the parameters. Worth trying if English accuracy matters more to you than speed or memory.",
        size_mb: 1178,
        hardware: "Roughly twice Parakeet TDT. Runs on CPU, slowly.",
        license: "CC-BY-4.0",
        tier: "quality",
    },
    CatalogEntry {
        id: "nvidia/nemotron-speech-streaming-en-0.6b",
        label: "Nemotron Streaming English 0.6B",
        detail: "English only, built for streaming. The smallest download here, and the one to try on a machine without a usable GPU.",
        size_mb: 700,
        hardware: "The lightest of these. Runs on CPU.",
        license: "NVIDIA Open Model License",
        tier: "light",
    },
];

// Sizes are the sum of the layers in each tag's Ollama manifest, so they are
// what `ollama pull` actually transfers.
const CLEANUP: &[CatalogEntry] = &[
    CatalogEntry {
        id: "gemma4:e4b",
        label: "Gemma 4 E4B",
        detail: "Passed 29 of 32 cases in OmaFlow's own multilingual cleanup benchmark, more than anything else tested. By far the largest download.",
        size_mb: 9163,
        hardware: "About 10 GB of GPU memory",
        license: "Gemma Terms of Use",
        tier: "recommended",
    },
    CatalogEntry {
        id: "gemma3:4b",
        label: "Gemma 3 4B",
        detail: "The previous Gemma generation at a third of E4B's size. A reasonable middle ground for German, French, Spanish, Italian and Dutch.",
        size_mb: 3184,
        hardware: "About 5 GB of GPU memory",
        license: "Gemma Terms of Use",
        tier: "quality",
    },
    CatalogEntry {
        id: "nemotron-3-nano:4b",
        label: "Nemotron 3 Nano 4B",
        detail: "NVIDIA's small reasoning model, with a 256K context. English is well covered; its support for other languages is not documented.",
        size_mb: 2706,
        hardware: "About 5 GB of GPU memory",
        license: "NVIDIA Open Model License",
        tier: "quality",
    },
    CatalogEntry {
        id: "qwen3:4b",
        label: "Qwen3 4B",
        detail: "A quarter of Gemma 4 E4B's download and Apache licensed. Qwen models translated text in OmaFlow's cleanup benchmark rather than editing it, so check your own languages before relying on it.",
        size_mb: 2382,
        hardware: "About 5 GB of GPU memory",
        license: "Apache-2.0",
        tier: "light",
    },
    CatalogEntry {
        id: "qwen3:1.7b",
        label: "Qwen3 1.7B",
        detail: "Lighter and faster. Punctuation and fillers are reliable; it misses more of the harder self-corrections.",
        size_mb: 1296,
        hardware: "About 3 GB of GPU memory, or CPU",
        license: "Apache-2.0",
        tier: "light",
    },
    CatalogEntry {
        id: "qwen3:0.6b",
        label: "Qwen3 0.6B",
        detail: "The smallest option, for machines without a usable GPU. Expect punctuation and filler removal, not spoken formatting commands.",
        size_mb: 498,
        hardware: "Runs on CPU",
        license: "Apache-2.0",
        tier: "light",
    },
];
pub fn entries(kind: Kind) -> &'static [CatalogEntry] {
    match kind {
        Kind::Speech => SPEECH,
        Kind::Cleanup => CLEANUP,
    }
}

pub fn find(kind: Kind, id: &str) -> Option<&'static CatalogEntry> {
    entries(kind).iter().find(|entry| entry.id == id)
}

/// One actionable sentence, with the ids spelled out, because the person who
/// mistyped this is at a shell prompt and wants the right word to type next.
pub fn unknown_id(kind: Kind, id: &str) -> String {
    format!(
        "No {} model named {id:?} in the catalog. Choose one of: {}.",
        kind.as_str(),
        entries(kind)
            .iter()
            .map(|entry| entry.id)
            .collect::<Vec<_>>()
            .join(", ")
    )
}

/// The config fields that selecting this entry writes, shaped for the
/// `models` setting so the daemon validates and reloads it the usual way.
pub fn selection_settings(kind: Kind, entry: &CatalogEntry) -> Value {
    match kind {
        // Managed NeMo derives its own health URL, and a URL left behind by a
        // previous engine would otherwise keep answering for it.
        Kind::Speech => json!({
            "speech_engine": SPEECH_ENGINE,
            "speech_model": entry.id,
            "speech_endpoint": SPEECH_ENDPOINT,
            "speech_health_endpoint": "",
        }),
        Kind::Cleanup => json!({
            "cleanup_model": entry.id,
            "cleanup_endpoint": CLEANUP_ENDPOINT,
        }),
    }
}

/// Writes the selection. The running daemon owns the config file while it is
/// up, so the change goes through the same IPC path as `omaflow configure`;
/// with no daemon (first install, a systemd unit) the write happens here.
pub fn select(kind: Kind, entry: &CatalogEntry) -> Result<(), String> {
    apply_setting("models", selection_settings(kind, entry))?;
    if kind == Kind::Speech {
        // models_configured means "a speech model is ready to use", so it
        // follows the weights on disk rather than the choice of model.
        apply_setting("models_configured", json!(speech_installed(entry.id)))?;
    }
    Ok(())
}

fn apply_setting(key: &str, value: Value) -> Result<(), String> {
    let command = format!("configure:{}", json!({"key": key, "value": value}));
    if crate::send_command_quiet(&command) {
        return Ok(());
    }
    Config::save_setting(key, value).map(|_| ())
}

fn cache_dir() -> PathBuf {
    env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".cache"))
}

/// Mirrors how the speech server resolves weights: an absolute GGUF path the
/// user typed themselves, or a file NeMo unpacked into its model cache.
pub fn speech_installed(id: &str) -> bool {
    if Path::new(id).is_file() {
        return true;
    }
    contains_gguf(&cache_dir().join("nemo-speech/models").join(id), 3)
}

fn contains_gguf(directory: &Path, depth: u8) -> bool {
    let Ok(children) = fs::read_dir(directory) else {
        return false;
    };
    for child in children.flatten() {
        let path = child.path();
        if path.is_file() {
            if path
                .extension()
                .is_some_and(|extension| extension == "gguf")
            {
                return true;
            }
        } else if depth > 0 && contains_gguf(&path, depth - 1) {
            return true;
        }
    }
    false
}

pub fn installed_speech_ids() -> Vec<String> {
    SPEECH
        .iter()
        .filter(|entry| speech_installed(entry.id))
        .map(|entry| entry.id.to_string())
        .collect()
}

/// Shells out once per model, so callers cache the answer instead of asking
/// on every publish.
pub fn installed_cleanup_ids(endpoint: &str) -> Vec<String> {
    // A local `ollama show` says nothing about what a server on another
    // machine holds, and answering from the wrong host is worse than silence.
    if !endpoint_is_local(endpoint) || !ollama_on_path() {
        return Vec::new();
    }
    CLEANUP
        .iter()
        .filter(|entry| {
            Command::new("ollama")
                .args(["show", entry.id])
                .bounded_status()
                .is_ok_and(|status| status.success())
        })
        .map(|entry| entry.id.to_string())
        .collect()
}

/// True when a URL points at this machine, so a local binary and a local
/// model list are actually the right things to look at.
pub fn endpoint_is_local(endpoint: &str) -> bool {
    let Some(authority) = endpoint
        .split_once("://")
        .and_then(|(_, rest)| rest.split(['/', '?', '#']).next())
    else {
        return false;
    };
    let host = authority
        .rsplit_once(':')
        .filter(|(head, _)| !head.ends_with(']'))
        .map_or(authority, |(head, _)| head);
    matches!(
        host.trim_matches(['[', ']']),
        "127.0.0.1" | "::1" | "localhost"
    ) || host.starts_with("127.")
}

pub fn ollama_on_path() -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };
    env::split_paths(&path).any(|directory| directory.join("ollama").is_file())
}

/// The catalog as the panel sees it: every entry, plus whether the weights are
/// on disk and whether it is the model the config currently points at.
pub fn to_json(
    config: &Config,
    installed_speech: &[String],
    installed_cleanup: &[String],
) -> Value {
    let selected_cleanup = config.cleanup.model.trim_end_matches(":latest");
    json!({
        "speech": serialize(SPEECH, installed_speech, config.backend.nemo_model()),
        "cleanup": serialize(CLEANUP, installed_cleanup, selected_cleanup),
    })
}

fn serialize(entries: &[CatalogEntry], installed: &[String], selected: &str) -> Value {
    Value::Array(
        entries
            .iter()
            .map(|entry| {
                let mut value = serde_json::to_value(entry).unwrap_or_else(|_| json!({}));
                if let Some(object) = value.as_object_mut() {
                    object.insert(
                        "installed".into(),
                        json!(installed.iter().any(|id| id == entry.id)),
                    );
                    object.insert("selected".into(), json!(selected == entry.id));
                }
                value
            })
            .collect(),
    )
}

/// Runs the downloader for one catalog entry, calling `report` for every line
/// the child writes. `percent` is None while the child says nothing we can
/// read a number out of, which the panel shows as an indeterminate bar.
pub fn download(
    kind: Kind,
    entry: &CatalogEntry,
    mut report: impl FnMut(Option<u8>, &str),
) -> Result<(), String> {
    let (command, probe) = match kind {
        Kind::Speech => {
            let binary = speech_downloader()?;
            // Nothing installs the runtime ahead of us any more: the user may
            // be pressing Download on a machine where it was never set up.
            if !speech_runtime_ready(&binary) {
                install_speech_runtime(&mut report)?;
                if !speech_runtime_ready(&binary) {
                    return Err(format!(
                        "The speech runtime is still not usable at {}; run ./install from the OmaFlow checkout.",
                        binary.display()
                    ));
                }
            }
            let mut command = Command::new(binary);
            command.args(["pull", entry.id]);
            // nemo-speech prints nothing but two banner lines when its output
            // is not a terminal, so the only progress available is the file it
            // is writing. The announced size replaces the estimate below as
            // soon as the banner arrives.
            (
                command,
                Some(DiskProbe {
                    directory: speech_cache_directory(entry.id),
                    total_bytes: u64::from(entry.size_mb) * 1_000_000,
                }),
            )
        }
        Kind::Cleanup => {
            if !ollama_on_path() {
                return Err(
                    "Ollama is not installed, so cleanup models cannot be downloaded.".into(),
                );
            }
            let mut command = Command::new("ollama");
            command.args(["pull", entry.id]);
            (command, None)
        }
    };
    stream(
        command,
        &format!("Downloading {}", entry.label),
        &mut report,
        probe,
    )
}

/// Records a model the panel downloaded, so `./uninstall` removes it again.
/// Bookkeeping is best effort: the weights are on disk either way, and a
/// receipt that could not be written is not a failed download.
pub fn record_receipt(kind: Kind, entry: &CatalogEntry) {
    let Some(script) = crate::update::repo_root()
        .map(|root| root.join("tools/install_receipt.py"))
        .filter(|script| script.is_file())
    else {
        return;
    };
    let (receipt_kind, value) = match kind {
        Kind::Speech => (
            "speech-cache",
            speech_cache_directory(entry.id)
                .to_string_lossy()
                .into_owned(),
        ),
        Kind::Cleanup => ("cleanup-model", entry.id.to_owned()),
    };
    let _ = Command::new("python3")
        .arg(script)
        .args([receipt_kind, &value])
        .bounded_status();
}

fn speech_cache_directory(id: &str) -> PathBuf {
    cache_dir().join("nemo-speech/models").join(id)
}

fn speech_downloader() -> Result<PathBuf, String> {
    let home = env::var_os("HOME").ok_or("HOME is not set, so the download cannot start")?;
    Ok(PathBuf::from(home).join(".local/lib/nemo-speech/bin/nemo-speech"))
}

/// The binary existing is not enough: a half-finished install leaves a file
/// that cannot run, and the pull would fail with a much worse message.
fn speech_runtime_ready(binary: &Path) -> bool {
    binary.is_file()
        && Command::new(binary)
            .arg("--version")
            .bounded_status()
            .is_ok_and(|status| status.success())
}

fn install_speech_runtime(report: &mut impl FnMut(Option<u8>, &str)) -> Result<(), String> {
    report(None, "Installing the speech runtime");
    let root = crate::update::repo_root().ok_or(
        "The OmaFlow checkout could not be found, so the speech runtime cannot be installed.",
    )?;
    let script = root.join("scripts/install-nemo.sh");
    if !script.is_file() {
        return Err(format!(
            "The speech runtime installer is missing at {}; update your OmaFlow checkout.",
            script.display()
        ));
    }
    let mut command = Command::new(&script);
    command.current_dir(&root);
    stream(command, "Installing the speech runtime", report, None)
}

/// Progress read off the disk, for a downloader that reports none itself.
struct DiskProbe {
    directory: PathBuf,
    total_bytes: u64,
}

impl DiskProbe {
    fn bytes(&self) -> u64 {
        directory_bytes(&self.directory, 4)
    }

    /// Capped below 100: only the child exiting cleanly means finished, and a
    /// bar that reaches the end and then waits is a bar that looks stuck.
    fn percent(&self, bytes: u64) -> Option<u8> {
        (self.total_bytes > 0).then(|| (bytes.saturating_mul(100) / self.total_bytes).min(99) as u8)
    }
}

fn directory_bytes(directory: &Path, depth: u8) -> u64 {
    let Ok(children) = fs::read_dir(directory) else {
        return 0;
    };
    children
        .flatten()
        .map(|child| match child.metadata() {
            Ok(metadata) if metadata.is_file() => metadata.len(),
            Ok(metadata) if metadata.is_dir() && depth > 0 => {
                directory_bytes(&child.path(), depth - 1)
            }
            _ => 0,
        })
        .sum()
}

/// Runs a child to completion, forwarding whatever it prints. Downloads and
/// runtime installs both take minutes, so nothing here imposes a deadline.
fn stream(
    mut command: Command,
    label: &str,
    report: &mut impl FnMut(Option<u8>, &str),
    mut probe: Option<DiskProbe>,
) -> Result<(), String> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("{label} could not be started: {error}"))?;

    let (lines, receiver) = mpsc::channel::<String>();
    for pipe in [
        child.stdout.take().map(PipeSource::Out),
        child.stderr.take().map(PipeSource::Err),
    ]
    .into_iter()
    .flatten()
    {
        let lines = lines.clone();
        thread::spawn(move || pipe.forward(&lines));
    }
    drop(lines);

    let mut last = String::new();
    let mut highest: Option<u8> = None;
    loop {
        match receiver.recv_timeout(Duration::from_millis(500)) {
            Ok(line) => {
                // The raw child output is the log; the panel gets a summary.
                eprintln!("{line}");
                if let Some(probe) = probe.as_mut()
                    && let Some(total) = parse_total_bytes(&line)
                {
                    probe.total_bytes = total;
                }
                // A multi-layer pull restarts at 0% for every layer, and a bar
                // that jumps backwards reads as a fault.
                highest = highest.max(parse_percent(&line));
                last = line;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
        let mut message = label.to_string();
        if let Some(probe) = probe.as_ref() {
            let bytes = probe.bytes();
            highest = highest.max(probe.percent(bytes));
            if bytes > 0 {
                message = format!(
                    "{label} ({} of {})",
                    human_bytes(bytes),
                    human_bytes(probe.total_bytes)
                );
            }
        }
        report(highest, &message);
    }

    let status = child
        .wait()
        .map_err(|error| format!("{label} could not be waited on: {error}"))?;
    if status.success() {
        return Ok(());
    }
    let reason = last.trim();
    if reason.is_empty() {
        Err(format!("{label} failed ({status})."))
    } else {
        Err(format!("{label} failed: {reason}"))
    }
}

fn human_bytes(bytes: u64) -> String {
    let value = bytes as f64;
    if value >= 1_000_000_000.0 {
        format!("{:.1} GB", value / 1_000_000_000.0)
    } else {
        format!("{:.0} MB", value / 1_000_000.0)
    }
}

enum PipeSource {
    Out(std::process::ChildStdout),
    Err(std::process::ChildStderr),
}

impl PipeSource {
    fn forward(self, lines: &mpsc::Sender<String>) {
        match self {
            Self::Out(pipe) => forward_lines(pipe, lines),
            Self::Err(pipe) => forward_lines(pipe, lines),
        }
    }
}

/// Progress bars separate their updates with carriage returns and repaint with
/// escape sequences, so this splits on both terminators and drops the escapes;
/// a plain line reader would hold the whole download in one unfinished line.
fn forward_lines(pipe: impl Read, lines: &mpsc::Sender<String>) {
    let mut reader = BufReader::new(pipe);
    let mut buffer = [0_u8; 4096];
    let mut pending = Vec::new();
    loop {
        let count = match reader.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(count) => count,
        };
        for byte in &buffer[..count] {
            if matches!(byte, b'\r' | b'\n') {
                if !send_line(&mut pending, lines) {
                    return;
                }
            } else if pending.len() < 8192 {
                pending.push(*byte);
            }
        }
    }
    send_line(&mut pending, lines);
}

fn send_line(pending: &mut Vec<u8>, lines: &mpsc::Sender<String>) -> bool {
    let text = strip_escapes(&String::from_utf8_lossy(pending));
    pending.clear();
    let text = text.trim();
    text.is_empty() || lines.send(text.to_string()).is_ok()
}

/// Terminal repaint codes (`ESC[K`, `ESC[?25h`, `ESC]…BEL`) would otherwise
/// end up in the panel and in error messages.
fn strip_escapes(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut characters = text.chars();
    while let Some(character) = characters.next() {
        if character != '\u{1b}' {
            if !character.is_control() {
                output.push(character);
            }
            continue;
        }
        match characters.next() {
            Some('[') => {
                for byte in characters.by_ref() {
                    if ('@'..='~').contains(&byte) {
                        break;
                    }
                }
            }
            Some(']') => {
                for byte in characters.by_ref() {
                    if byte == '\u{7}' || byte == '\u{1b}' {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    output
}

/// Reads the announced download size out of a banner such as
/// "[model] downloading nvidia/… (asr, 667.5 MiB)".
fn parse_total_bytes(line: &str) -> Option<u64> {
    for (unit, scale) in [
        ("GiB", 1_073_741_824.0),
        ("MiB", 1_048_576.0),
        ("KiB", 1024.0),
        ("GB", 1_000_000_000.0),
        ("MB", 1_000_000.0),
        ("KB", 1000.0),
    ] {
        let Some(index) = line.rfind(unit) else {
            continue;
        };
        let head = line[..index].trim_end();
        let start = head
            .rfind(|character: char| !character.is_ascii_digit() && character != '.')
            .map_or(0, |position| position + 1);
        if let Ok(value) = head[start..].parse::<f64>()
            && value > 0.0
        {
            return Some((value * scale) as u64);
        }
    }
    None
}

fn parse_percent(line: &str) -> Option<u8> {
    let bytes = line.as_bytes();
    let mut latest = None;
    for (index, byte) in bytes.iter().enumerate() {
        if *byte != b'%' {
            continue;
        }
        let mut start = index;
        while start > 0 && (bytes[start - 1].is_ascii_digit() || bytes[start - 1] == b'.') {
            start -= 1;
        }
        if let Ok(value) = line[start..index].parse::<f64>() {
            latest = Some(value.clamp(0.0, 100.0) as u8);
        }
    }
    latest
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_entry_is_unique_and_described() {
        for kind in [Kind::Speech, Kind::Cleanup] {
            let list = entries(kind);
            assert!(
                list.iter()
                    .any(|entry| entry.tier == "recommended" && entry.detail.len() > 40)
            );
            for (index, entry) in list.iter().enumerate() {
                assert!(list[..index].iter().all(|other| other.id != entry.id));
                assert!(["recommended", "quality", "light"].contains(&entry.tier));
                assert!(entry.size_mb > 0 && !entry.license.is_empty());
                assert!(find(kind, entry.id).is_some());
            }
        }
        assert!(find(Kind::Speech, "qwen3:4b").is_none());
    }

    #[test]
    fn reads_a_percentage_out_of_downloader_chatter() {
        assert_eq!(parse_percent("pulling 1a2b3c:  47% ▕███  ▏"), Some(47));
        assert_eq!(parse_percent("downloading 12.5% of 2.5 GB"), Some(12));
        assert_eq!(parse_percent("done 100%"), Some(100));
        assert_eq!(parse_percent("pulling manifest"), None);
        assert_eq!(parse_percent("100% then 3%"), Some(3));
        assert_eq!(parse_percent("weird %"), None);
    }

    #[test]
    fn reads_the_announced_download_size_from_a_banner() {
        assert_eq!(
            parse_total_bytes("[model] downloading nvidia/x@abc (asr, 667.5 MiB)"),
            Some(699_924_480)
        );
        assert_eq!(parse_total_bytes("(asr, 1.5 GiB)"), Some(1_610_612_736));
        assert_eq!(parse_total_bytes("pulled 500 MB"), Some(500_000_000));
        assert_eq!(parse_total_bytes("[model] license: CC-BY-4.0"), None);
    }

    #[test]
    fn splits_progress_bars_on_carriage_returns_without_escape_codes() {
        let (sender, receiver) = mpsc::channel();
        let raw = "pulling manifest\u{1b}[K\rpulling abc: 42% \u{1b}[?25h\rsuccess\n";
        forward_lines(raw.as_bytes(), &sender);
        drop(sender);
        let lines: Vec<String> = receiver.iter().collect();
        assert_eq!(lines, ["pulling manifest", "pulling abc: 42%", "success"]);
        assert_eq!(parse_percent(&lines[1]), Some(42));
    }

    #[test]
    fn selection_writes_only_known_model_settings() {
        for kind in [Kind::Speech, Kind::Cleanup] {
            let entry = &entries(kind)[0];
            let settings = selection_settings(kind, entry);
            let object = settings.as_object().unwrap();
            assert!(!object.is_empty());
            for key in object.keys() {
                assert!(
                    [
                        "speech_engine",
                        "speech_model",
                        "speech_endpoint",
                        "speech_health_endpoint",
                        "cleanup_model",
                        "cleanup_endpoint"
                    ]
                    .contains(&key.as_str())
                );
            }
        }
    }

    #[test]
    fn published_entries_carry_installed_and_selected() {
        let chosen = "nvidia/parakeet-ctc-1.1b";
        let mut config = Config::default();
        config.backend.model = chosen.into();
        config.cleanup.model = "gemma4:e4b".into();
        let value = to_json(&config, &[chosen.to_string()], &[]);
        let speech = value["speech"].as_array().unwrap();
        let entry = speech.iter().find(|entry| entry["id"] == chosen).unwrap();
        assert_eq!(entry["installed"], true);
        assert_eq!(entry["selected"], true);
        assert_eq!(speech[0]["selected"], false);
        assert_eq!(value["cleanup"][0]["selected"], true);
        assert_eq!(value["cleanup"][0]["installed"], false);
    }
}
