mod cleanup;
mod cli;
use crate::process::CommandExt;
mod backend;
mod config;
mod process;
mod state;
mod update;
mod vocabulary;

use config::{Config, PasteMode};
use serde::{Deserialize, Serialize};
use state::{Action, Phase, StateMachine};
use std::{
    env, fs,
    io::{ErrorKind, Read, Write},
    os::unix::{
        fs::{OpenOptionsExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    process::{Command, ExitCode},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, RecvTimeoutError},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// Commands that drive the recording state machine. Keeping them in their own
/// type is what lets the session handler match exhaustively instead of ending
/// in an unreachable arm for every command that is not one of these.
#[derive(Debug, Clone, Copy)]
enum SessionCommand {
    Press,
    Release,
    Stop,
    Cancel,
    Close,
}

/// Everything the panel asks for that leaves the recording state untouched.
#[derive(Debug, Clone)]
enum PanelCommand {
    Copy,
    PasteLast,
    PasteHistory(u64),
    CopyHistory(u64),
    DeleteHistory(u64),
    UndoDelete,
    ClearHistory,
    MeterPreviewStart,
    MeterPreviewStop,
    PreviewMeterGate(i32),
    SetMeterGate(i32),
    SetPasteMode(PasteMode),
    AddVocabulary(String),
    RemoveVocabulary(String),
    RefreshUpdate,
    Configure(String, serde_json::Value),
    EditHistory(u64, String),
    CopyRaw(u64),
    EraseData,
    ReloadConfig,
}

#[derive(Debug)]
enum Message {
    Session(SessionCommand),
    Panel(PanelCommand),
    Completed(u64, backend::StopOutcome),
    Failed(u64, String),
    RuntimeStatus(RuntimeStatus),
    Feedback(Result<(), String>, String),
    ResultCopied(u64, Result<(), String>),
}

#[derive(Debug)]
enum BackendJob {
    Start(u64),
    Stop(u64),
    Cancel,
    MeterPreviewStart,
    MeterPreviewStop,
    SetMeterGate(i32),
    SetPasteMode(PasteMode),
    SetCustomVocabulary(Vec<String>),
    ReloadConfig(Box<Config>),
}

#[derive(Debug, Clone, Default)]
struct RuntimeStatus {
    asr_running: bool,
    cleanup_loaded: bool,
    cleanup_available: bool,
    gpu_memory_mib: u64,
    hotkey_display: String,
    update: update::UpdateStatus,
}

#[derive(Debug, Clone, Copy, Default)]
enum ResultView {
    #[default]
    None,
    Success,
    Transcript,
    Notice,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct HistoryEntry {
    id: u64,
    created_at_ms: u64,
    text: String,
    #[serde(default)]
    raw_text: String,
    #[serde(default)]
    cleanup_model: String,
    pasted: bool,
    #[serde(default)]
    cleanup_warning: String,
}

#[derive(Debug, Serialize)]
struct TrainingSample<'a> {
    schema_version: u8,
    created_at_ms: u64,
    raw_asr: &'a str,
    model_output: &'a str,
    cleanup_model: &'a str,
    cleanup_fallback: bool,
}

#[derive(Debug, Serialize)]
struct SurfaceState<'a> {
    phase: &'a str,
    latched: bool,
    text: &'a str,
    error: &'a str,
    history: &'a [HistoryEntry],
    meter_gate_db: i32,
    paste_mode: &'a str,
    clipboard_result_visible_ms: u64,
    error_visible_ms: u64,
    notice_visible_ms: u64,
    cleanup_model: &'a str,
    training_log_enabled: bool,
    hotkey_display: &'a str,
    custom_vocabulary: &'a [String],
    can_undo_delete: bool,
    asr_running: bool,
    cleanup_loaded: bool,
    cleanup_available: bool,
    gpu_memory_mib: u64,
    state_version: u32,
    running_version: &'a str,
    checkout_version: &'a str,
    needs_rebuild: bool,
    update_behind: u32,
    update_remote_version: &'a str,
    update_checked_at_ms: u64,
    update_error: &'a str,
    model_settings: serde_json::Value,
    config_path: String,
    shortcut_settings: serde_json::Value,
    cleanup_enabled: bool,
    style: &'a str,
    use_window_context: bool,
    use_clipboard_context: bool,
    history_limit: usize,
    feedback: &'a str,
    feedback_error: bool,
    reduced_motion: bool,
    keep_models_loaded: bool,
    paste_sent: bool,
    recording_elapsed_ms: u64,
    published_at_ms: u64,
    serial: u64,
}

struct Daemon {
    state: StateMachine,
    view: ResultView,
    transcript: String,
    error: String,
    close_at: Option<Duration>,
    serial: u64,
    state_path: PathBuf,
    history: Vec<HistoryEntry>,
    last_deleted: Option<Vec<HistoryEntry>>,
    history_path: PathBuf,
    training_log_path: PathBuf,
    history_limit: usize,
    training_log_enabled: bool,
    clipboard_result_visible_ms: u64,
    error_visible_ms: u64,
    notice_visible_ms: u64,
    cleanup_model: String,
    hotkey_display: String,
    custom_vocabulary: Vec<String>,
    runtime_status: RuntimeStatus,
    meter_gate_db: i32,
    paste_mode: PasteMode,
    generation: u64,
    update: update::UpdateStatus,
    effective_config: Config,
    message_tx: mpsc::Sender<Message>,
    feedback: String,
    feedback_error: bool,
    recording_started: Option<Instant>,
    paste_sent: bool,
}

fn main() -> ExitCode {
    cli::run()
}

fn run_daemon() -> ExitCode {
    let config = match Config::load() {
        Ok(config) => config,
        Err(error) => {
            eprintln!("omaflow: {error}");
            return ExitCode::FAILURE;
        }
    };
    if let Err(error) = backend::reset_meter() {
        eprintln!("omaflow: could not initialize microphone meter: {error}");
    }

    let socket = socket_path();
    if socket.exists() {
        if UnixStream::connect(&socket).is_ok() {
            eprintln!("omaflow: daemon is already running");
            return ExitCode::FAILURE;
        }
        if let Err(error) = fs::remove_file(&socket) {
            eprintln!("omaflow: could not remove stale socket: {error}");
            return ExitCode::FAILURE;
        }
    }

    let meter_gate_db = clamp_meter_gate(config.behavior.meter_gate_db);
    let paste_mode = config.behavior.paste_mode;
    let listener = match UnixListener::bind(&socket) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("omaflow: could not create {}: {error}", socket.display());
            return ExitCode::FAILURE;
        }
    };
    if let Err(error) = fs::set_permissions(&socket, fs::Permissions::from_mode(0o600)) {
        eprintln!("omaflow: could not protect {}: {error}", socket.display());
        let _ = fs::remove_file(&socket);
        return ExitCode::FAILURE;
    }

    let (message_tx, message_rx) = mpsc::channel::<Message>();
    let (job_tx, job_rx) = mpsc::channel::<BackendJob>();
    start_ipc(listener, message_tx.clone());
    start_backend_worker(config.clone(), meter_gate_db, job_rx, message_tx.clone());
    start_status_worker(config.clone(), message_tx.clone());

    let history_path = history_path();
    let history = load_history(&history_path, config.behavior.history_limit);
    let epoch = Instant::now();
    let mut daemon = Daemon {
        state: StateMachine::with_max_recording(
            config.behavior.double_tap_ms,
            config.behavior.max_recording_seconds,
        ),
        view: ResultView::None,
        transcript: String::new(),
        error: String::new(),
        close_at: None,
        serial: 0,
        state_path: surface_state_path(),
        history,
        last_deleted: None,
        history_path,
        training_log_path: training_log_path(),
        history_limit: config.behavior.history_limit,
        training_log_enabled: config.behavior.training_log_enabled,
        clipboard_result_visible_ms: config.behavior.clipboard_result_visible_ms,
        error_visible_ms: config.behavior.error_visible_ms,
        notice_visible_ms: config.behavior.notice_visible_ms,
        cleanup_model: config.cleanup.model.clone(),
        hotkey_display: read_hotkey_display(),
        custom_vocabulary: config.cleanup.custom_vocabulary.clone(),
        runtime_status: RuntimeStatus::default(),
        meter_gate_db,
        paste_mode,
        generation: 0,
        update: update::status(),
        effective_config: config.clone(),
        message_tx,
        feedback: String::new(),
        feedback_error: false,
        recording_started: None,
        paste_sent: false,
    };
    daemon.publish();

    loop {
        let now = epoch.elapsed();
        let next_deadline = earliest(
            earliest(daemon.state.next_deadline(), daemon.close_at),
            Some(now + Duration::from_secs(1)),
        );
        let received = match next_deadline {
            Some(deadline) => message_rx
                .recv_timeout(deadline.saturating_sub(now))
                .map(Some),
            None => message_rx
                .recv()
                .map(Some)
                .map_err(|_| RecvTimeoutError::Disconnected),
        };

        match received {
            Ok(Some(message)) => handle_message(message, epoch.elapsed(), &mut daemon, &job_tx),
            Ok(None) | Err(RecvTimeoutError::Timeout) => daemon.publish(),
            Err(RecvTimeoutError::Disconnected) => break,
        }

        let now = epoch.elapsed();
        let action = daemon.state.tick(now);
        run_action(action, &job_tx, &mut daemon);
        if daemon.close_at.is_some_and(|deadline| now >= deadline)
            && matches!(daemon.state.phase(), Phase::Result | Phase::Error)
        {
            daemon.close_at = None;
            daemon.view = ResultView::None;
            daemon.state.close();
            daemon.publish();
        }
    }

    let _ = fs::remove_file(socket);
    let _ = backend::reset_meter();
    ExitCode::SUCCESS
}

fn earliest(left: Option<Duration>, right: Option<Duration>) -> Option<Duration> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left.min(right)),
        (Some(value), None) | (None, Some(value)) => Some(value),
        (None, None) => None,
    }
}

fn handle_message(
    message: Message,
    now: Duration,
    daemon: &mut Daemon,
    jobs: &mpsc::Sender<BackendJob>,
) {
    match message {
        Message::Feedback(result, label) => daemon.operation_feedback(result, &label),
        Message::ResultCopied(generation, result) => {
            if generation == daemon.generation {
                daemon.error = result.as_ref().err().cloned().unwrap_or_default();
                daemon.operation_feedback(result, "Copied to clipboard");
            }
        }
        Message::Panel(PanelCommand::Copy) => {
            if !daemon.transcript.is_empty() {
                let text = daemon.transcript.clone();
                let generation = daemon.generation;
                let messages = daemon.message_tx.clone();
                thread::spawn(move || {
                    let _ =
                        messages.send(Message::ResultCopied(generation, backend::copy_text(&text)));
                });
            }
        }
        Message::Panel(PanelCommand::PasteLast) => {
            let text = if daemon.transcript.is_empty() {
                daemon.history.first().map(|entry| entry.text.as_str())
            } else {
                Some(daemon.transcript.as_str())
            };
            if let Some(text) = text {
                daemon.paste_async(text.to_owned());
            }
        }
        Message::Panel(PanelCommand::PasteHistory(id)) => {
            if let Some(entry) = daemon.history.iter().find(|entry| entry.id == id) {
                daemon.paste_async(entry.text.clone());
            }
        }
        Message::Panel(PanelCommand::CopyHistory(id)) => {
            if let Some(entry) = daemon.history.iter().find(|entry| entry.id == id) {
                daemon.copy_async(entry.text.clone(), "Copied to clipboard");
            }
        }
        Message::Panel(PanelCommand::DeleteHistory(id)) => {
            let mut next = daemon.history.clone();
            next.retain(|entry| entry.id != id);
            if next.len() != daemon.history.len() {
                daemon.save_history_change(next, true, "Dictation deleted. Undo is available.");
            }
        }
        Message::Panel(PanelCommand::UndoDelete) => {
            if let Some(entries) = daemon.last_deleted.clone() {
                let mut next = daemon.history.clone();
                for entry in entries {
                    if !next.iter().any(|current| current.id == entry.id) {
                        next.push(entry);
                    }
                }
                next.sort_by_key(|entry| std::cmp::Reverse(entry.id));
                next.truncate(daemon.history_limit);
                if daemon.save_history_change(next, false, "History restored") {
                    daemon.last_deleted = None;
                    daemon.publish();
                }
            }
        }
        Message::Panel(PanelCommand::ClearHistory) => {
            if !daemon.history.is_empty() {
                daemon.save_history_change(Vec::new(), true, "History cleared. Undo is available.");
            }
        }
        Message::Panel(PanelCommand::MeterPreviewStart) => {
            let _ = jobs.send(BackendJob::MeterPreviewStart);
        }
        Message::Panel(PanelCommand::MeterPreviewStop) => {
            let _ = jobs.send(BackendJob::MeterPreviewStop);
        }
        Message::Panel(PanelCommand::PreviewMeterGate(gate_db)) => {
            daemon.meter_gate_db = clamp_meter_gate(gate_db);
            let _ = jobs.send(BackendJob::SetMeterGate(daemon.meter_gate_db));
            daemon.publish();
        }
        Message::Panel(PanelCommand::SetMeterGate(gate_db)) => {
            let next = clamp_meter_gate(gate_db);
            if let Err(error) = Config::write_behavior_preferences(next, daemon.paste_mode) {
                daemon.meter_gate_db =
                    clamp_meter_gate(daemon.effective_config.behavior.meter_gate_db);
                let _ = jobs.send(BackendJob::SetMeterGate(daemon.meter_gate_db));
                daemon.operation_feedback(Err(error), "");
                return;
            }
            daemon.effective_config.behavior.meter_gate_db = next;
            daemon.meter_gate_db = next;
            let _ = jobs.send(BackendJob::SetMeterGate(daemon.meter_gate_db));
            daemon.publish();
        }
        Message::Panel(PanelCommand::SetPasteMode(paste_mode)) => {
            if let Err(error) = Config::write_behavior_preferences(daemon.meter_gate_db, paste_mode)
            {
                daemon.operation_feedback(Err(error), "");
                return;
            }
            daemon.effective_config.behavior.paste_mode = paste_mode;
            daemon.paste_mode = paste_mode;
            let _ = jobs.send(BackendJob::SetPasteMode(paste_mode));
            daemon.publish();
        }
        Message::Panel(PanelCommand::AddVocabulary(value)) => {
            if let Some(value) = normalize_vocabulary_entry(&value)
                && !daemon
                    .custom_vocabulary
                    .iter()
                    .any(|entry| entry.eq_ignore_ascii_case(&value))
            {
                let mut vocabulary = daemon.custom_vocabulary.clone();
                vocabulary.push(value);
                vocabulary.sort_by_key(|entry| entry.to_lowercase());
                if let Err(error) = Config::write_custom_vocabulary(&vocabulary) {
                    daemon.operation_feedback(Err(error), "");
                } else {
                    daemon.effective_config.cleanup.custom_vocabulary = vocabulary.clone();
                    daemon.custom_vocabulary = vocabulary;
                    let _ = jobs.send(BackendJob::SetCustomVocabulary(
                        daemon.custom_vocabulary.clone(),
                    ));
                    daemon.publish();
                }
            }
        }
        Message::Panel(PanelCommand::RemoveVocabulary(value)) => {
            let mut vocabulary = daemon.custom_vocabulary.clone();
            let old_len = vocabulary.len();
            vocabulary.retain(|entry| !entry.eq_ignore_ascii_case(value.trim()));
            if vocabulary.len() != old_len {
                if let Err(error) = Config::write_custom_vocabulary(&vocabulary) {
                    daemon.operation_feedback(Err(error), "");
                } else {
                    daemon.effective_config.cleanup.custom_vocabulary = vocabulary.clone();
                    daemon.custom_vocabulary = vocabulary;
                    let _ = jobs.send(BackendJob::SetCustomVocabulary(
                        daemon.custom_vocabulary.clone(),
                    ));
                    daemon.publish();
                }
            }
        }
        Message::Panel(PanelCommand::Configure(key, value)) => {
            if matches!(key.as_str(), "models" | "models_configured")
                && matches!(
                    daemon.state.phase(),
                    Phase::Recording { .. } | Phase::Processing
                )
            {
                daemon.operation_feedback(
                    Err("Finish or discard dictation before changing models".into()),
                    "",
                );
                return;
            }
            match Config::save_setting(&key, value) {
                Ok(config) => {
                    let result = daemon.apply_config(config.clone());
                    let _ = jobs.send(BackendJob::ReloadConfig(Box::new(config)));
                    daemon.operation_feedback(result, "Settings saved");
                }
                Err(error) => daemon.operation_feedback(Err(error), ""),
            }
        }
        Message::Panel(PanelCommand::ReloadConfig) => match Config::load() {
            Ok(config) => {
                let result = daemon.apply_config(config.clone());
                let _ = jobs.send(BackendJob::ReloadConfig(Box::new(config)));
                daemon.operation_feedback(result, "Settings reloaded");
            }
            Err(error) => daemon.operation_feedback(Err(error), ""),
        },
        Message::Panel(PanelCommand::CopyRaw(id)) => {
            if let Some(entry) = daemon.history.iter().find(|entry| entry.id == id) {
                daemon.copy_async(entry.raw_text.clone(), "Original transcription copied");
            }
        }
        Message::Panel(PanelCommand::EditHistory(id, text)) => {
            if text.trim().is_empty() || text.len() > 60_000 {
                daemon.operation_feedback(Err("Enter 1–60,000 bytes of text".into()), "");
            } else {
                let mut next = daemon.history.clone();
                if let Some(entry) = next.iter_mut().find(|entry| entry.id == id) {
                    entry.text = text;
                    daemon.save_history_change(next, false, "Transcript saved");
                }
            }
        }
        Message::Panel(PanelCommand::EraseData) => {
            daemon.generation = daemon.generation.wrapping_add(1);
            let action = daemon.state.cancel();
            daemon.state.close();
            daemon.close_at = None;
            run_action(action, jobs, daemon);
            let mut errors = Vec::new();
            for path in [&daemon.history_path, &daemon.training_log_path] {
                if let Err(error) = fs::remove_file(path)
                    && error.kind() != ErrorKind::NotFound
                {
                    errors.push(format!("{}: {error}", path.display()));
                }
            }
            if !daemon.history_path.exists() {
                daemon.history.clear();
                daemon.last_deleted = None;
            }
            daemon.transcript.clear();
            daemon.view = ResultView::None;
            let result = if errors.is_empty() {
                Ok(())
            } else {
                Err(format!(
                    "Some saved data could not be deleted: {}",
                    errors.join("; ")
                ))
            };
            daemon.operation_feedback(
                result,
                "History and training data deleted. Your clipboard is unchanged.",
            );
        }
        Message::Panel(PanelCommand::RefreshUpdate) => {
            daemon.update = update::status();
            daemon.publish();
        }
        Message::Session(command) => {
            if matches!(
                command,
                SessionCommand::Press
                    | SessionCommand::Stop
                    | SessionCommand::Cancel
                    | SessionCommand::Close
            ) {
                daemon.close_at = None;
            }
            let phase_before = daemon.state.phase().clone();
            let action = match command {
                SessionCommand::Press => {
                    daemon.view = ResultView::None;
                    daemon.error.clear();
                    let action = daemon.state.press(now);
                    if action == Action::Start {
                        daemon.generation = daemon.generation.wrapping_add(1);
                    }
                    action
                }
                SessionCommand::Release => daemon.state.release(now),
                SessionCommand::Stop => daemon.state.stop(),
                SessionCommand::Cancel => {
                    daemon.view = ResultView::None;
                    daemon.state.cancel()
                }
                SessionCommand::Close => {
                    if matches!(daemon.state.phase(), Phase::Result | Phase::Error) {
                        daemon.view = ResultView::None;
                        daemon.state.close();
                    }
                    Action::None
                }
            };
            if !matches!(phase_before, Phase::Idle | Phase::Result | Phase::Error)
                || !matches!(
                    daemon.state.phase(),
                    Phase::Idle | Phase::Result | Phase::Error
                )
            {
                eprintln!(
                    "omaflow: control={command:?} before={phase_before:?} action={action:?} after={:?}",
                    daemon.state.phase()
                );
            }
            run_action(action, jobs, daemon);
            daemon.publish();
        }
        Message::Completed(generation, outcome) => {
            if generation != daemon.generation || !matches!(daemon.state.phase(), Phase::Processing)
            {
                return;
            }
            let backend::StopOutcome::Transcript(transcript) = outcome else {
                daemon.state.completed();
                daemon.view = ResultView::Notice;
                daemon.close_at = Some(now + Duration::from_millis(daemon.notice_visible_ms));
                daemon.publish();
                return;
            };
            daemon.state.completed();
            daemon.transcript = transcript.text.clone();
            daemon.paste_sent = transcript.pasted;
            daemon.error = transcript.delivery_error.clone();
            daemon.feedback = transcript.cleanup_warning.clone();
            daemon.feedback_error = !transcript.cleanup_warning.is_empty();
            daemon.remember_transcript(&transcript);
            daemon.view = if transcript.pasted && !daemon.feedback_error {
                daemon.close_at = Some(
                    now + Duration::from_millis(
                        daemon.effective_config.behavior.success_visible_ms,
                    ),
                );
                ResultView::Success
            } else {
                daemon.close_at = None;
                ResultView::Transcript
            };
            daemon.publish();
        }
        Message::Failed(generation, error) => {
            if generation != daemon.generation
                || !matches!(
                    daemon.state.phase(),
                    Phase::Recording { .. } | Phase::Processing
                )
            {
                return;
            }
            eprintln!("omaflow: dictation failed: {error}");
            daemon.close_at = Some(
                now + Duration::from_millis(daemon.effective_config.behavior.error_visible_ms),
            );
            daemon.state.failed();
            daemon.view = ResultView::Error;
            daemon.error = friendly_error(&error);
            daemon.publish();
        }
        Message::RuntimeStatus(status) => {
            daemon.hotkey_display = status.hotkey_display.clone();
            daemon.update = status.update.clone();
            daemon.runtime_status = status;
            daemon.publish();
        }
    }
}

fn run_action(action: Action, jobs: &mpsc::Sender<BackendJob>, daemon: &mut Daemon) {
    if action == Action::Start {
        daemon.recording_started = Some(Instant::now());
    }
    let Some(job) = (match action {
        Action::Start => Some(BackendJob::Start(daemon.generation)),
        Action::Stop => Some(BackendJob::Stop(daemon.generation)),
        Action::Cancel => Some(BackendJob::Cancel),
        Action::None => None,
    }) else {
        return;
    };
    if jobs.send(job).is_err() {
        daemon.state.failed();
        daemon.view = ResultView::Error;
        daemon.error = "speech backend worker stopped".into();
    }
    daemon.publish();
}

/// Backend failures are written for a log. The card shows one sentence for
/// what happened and one for what to do about it, because the person reading
/// it is mid-sentence and wants their words back, not a diagnosis.
fn friendly_error(error: &str) -> String {
    let lowered = error.to_lowercase();
    let matches = |needles: &[&str]| needles.iter().any(|needle| lowered.contains(needle));

    if matches(&["speech model is not configured"]) {
        "The speech model is missing or ambiguous. Set an installed GGUF path in Settings → Models."
    } else if matches(&["models not configured"]) {
        "Models not configured. Open Settings → Models to finish setup."
    } else if matches(&["asr.service", "could not connect", "did not start"]) {
        "The transcription engine is not answering. It may still be loading — try again in a moment."
    } else if matches(&["too large"]) {
        "That recording was too long to transcribe. Dictate in shorter passages."
    // Checked before the microphone bucket: finalizing timed out after the
    // device was already open, so it is a stall, not a device problem.
    } else if matches(&["timed out finalizing", "worker stopped"]) {
        "Transcription stalled and was stopped. Try again."
    } else if matches(&["pipewire", "microphone", "capture"]) {
        "OmaFlow could not reach the microphone. Check the input device in your sound settings."
    } else if matches(&["empty transcript", "contained no text", "no microphone audio"]) {
        "Nothing was recognised in that recording."
    } else if matches(&["timed out"]) {
        "That took too long and was stopped. Try again."
    } else if matches(&["paste", "shortcut", "focused window"]) {
        "Your text is on the clipboard. OmaFlow could not paste it into the focused window."
    } else if matches(&["wl-copy", "clipboard"]) {
        "OmaFlow could not reach the clipboard, so the text was not copied."
    } else if matches(&["cleanup", "ollama"]) {
        "The cleanup model was unavailable, so the raw transcription was used."
    } else {
        "OmaFlow could not finish this dictation. Try again, or restart it from the bar."
    }
    .to_string()
}

impl Daemon {
    fn save_history_change(&mut self, next: Vec<HistoryEntry>, undo: bool, label: &str) -> bool {
        let result = write_history(&self.history_path, &next);
        let saved = result.is_ok();
        if saved {
            if undo {
                self.last_deleted = Some(self.history.clone());
            }
            self.history = next;
        }
        self.operation_feedback(result, label);
        saved
    }

    fn paste_async(&self, text: String) {
        let messages = self.message_tx.clone();
        let mode = self.paste_mode;
        thread::spawn(move || {
            let result = backend::paste_text_now(&text, mode);
            let label = if mode == PasteMode::Clipboard {
                "Copied to clipboard"
            } else {
                "Paste shortcut sent; text also on clipboard"
            };
            let _ = messages.send(Message::Feedback(result, label.into()));
        });
    }
    fn copy_async(&self, text: String, label: &str) {
        let messages = self.message_tx.clone();
        let label = label.to_string();
        thread::spawn(move || {
            let result = backend::copy_text(&text);
            let _ = messages.send(Message::Feedback(result, label));
        });
    }

    fn apply_config(&mut self, config: Config) -> Result<(), String> {
        self.training_log_enabled = config.behavior.training_log_enabled;
        self.history_limit = config.behavior.history_limit;
        self.history.truncate(self.history_limit);
        let retained = write_history(&self.history_path, &self.history);
        self.clipboard_result_visible_ms = config.behavior.clipboard_result_visible_ms;
        self.error_visible_ms = config.behavior.error_visible_ms;
        self.notice_visible_ms = config.behavior.notice_visible_ms;
        self.meter_gate_db = clamp_meter_gate(config.behavior.meter_gate_db);
        self.paste_mode = config.behavior.paste_mode;
        self.custom_vocabulary = config.cleanup.custom_vocabulary.clone();
        self.cleanup_model = config.cleanup.model.clone();
        self.state.configure(
            config.behavior.double_tap_ms,
            config.behavior.max_recording_seconds,
        );
        self.effective_config = config;
        retained.map_err(|error| {
            format!("Settings saved, but stored history could not be updated: {error}")
        })
    }
    fn operation_feedback(&mut self, outcome: Result<(), String>, success: &str) {
        self.feedback_error = outcome.is_err();
        self.feedback = outcome.err().unwrap_or_else(|| success.into());
        self.publish();
    }

    fn publish(&mut self) {
        self.serial = self.serial.wrapping_add(1);
        let (phase, latched) = match self.state.phase() {
            Phase::Idle => ("idle", false),
            Phase::Recording { latched, .. } => ("recording", *latched),
            Phase::Processing => ("processing", false),
            Phase::Result => (
                match self.view {
                    ResultView::Success => "success",
                    ResultView::Transcript => "result",
                    ResultView::Notice => "notice",
                    _ => "result",
                },
                false,
            ),
            Phase::Error => ("error", false),
        };
        let payload = SurfaceState {
            phase,
            latched,
            text: if matches!(self.view, ResultView::Transcript) {
                &self.transcript
            } else {
                ""
            },
            error: if matches!(self.view, ResultView::Error | ResultView::Transcript) {
                &self.error
            } else {
                ""
            },
            history: &self.history,
            meter_gate_db: self.meter_gate_db,
            paste_mode: self.paste_mode.as_str(),
            clipboard_result_visible_ms: self.clipboard_result_visible_ms,
            error_visible_ms: self.error_visible_ms,
            notice_visible_ms: self.notice_visible_ms,
            cleanup_model: &self.cleanup_model,
            training_log_enabled: self.training_log_enabled,
            hotkey_display: &self.hotkey_display,
            custom_vocabulary: &self.custom_vocabulary,
            can_undo_delete: self.last_deleted.is_some(),
            asr_running: self.runtime_status.asr_running,
            cleanup_loaded: self.runtime_status.cleanup_loaded,
            cleanup_available: self.runtime_status.cleanup_available,
            gpu_memory_mib: self.runtime_status.gpu_memory_mib,
            state_version: update::STATE_VERSION,
            running_version: update::RUNNING_VERSION,
            checkout_version: &self.update.checkout_version,
            needs_rebuild: self.update.needs_rebuild,
            update_behind: self.update.remote.behind,
            update_remote_version: &self.update.remote.remote_version,
            update_checked_at_ms: self.update.remote.checked_at_ms,
            update_error: &self.update.remote.error,
            config_path: Config::path().to_string_lossy().into_owned(),
            shortcut_settings: serde_json::to_value(&self.effective_config.shortcut)
                .unwrap_or_default(),
            model_settings: serde_json::json!({
                "configured": self.effective_config.behavior.models_configured,
                "speech_engine": self.effective_config.backend.engine,
                "speech_model": self.effective_config.backend.model,
                "speech_endpoint": self.effective_config.backend.endpoint,
                "speech_health_endpoint": self.effective_config.backend.health_endpoint,
                "speech_language": self.effective_config.backend.language,
                "speech_device": self.effective_config.backend.device,
                "cleanup_model": self.effective_config.cleanup.model,
                "cleanup_endpoint": self.effective_config.cleanup.endpoint,
            }),
            cleanup_enabled: self.effective_config.cleanup.enabled,
            style: &self.effective_config.cleanup.style,
            use_window_context: self.effective_config.cleanup.use_window_context,
            use_clipboard_context: self.effective_config.cleanup.use_clipboard_context,
            history_limit: self.history_limit,
            feedback: &self.feedback,
            feedback_error: self.feedback_error,
            reduced_motion: self.effective_config.behavior.reduced_motion,
            keep_models_loaded: self.effective_config.behavior.keep_models_loaded,
            paste_sent: self.paste_sent,
            recording_elapsed_ms: if matches!(self.state.phase(), Phase::Recording { .. }) {
                self.recording_started
                    .map_or(0, |started| started.elapsed().as_millis() as u64)
            } else {
                0
            },
            published_at_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64,
            serial: self.serial,
        };
        if let Err(error) = write_surface_state(&self.state_path, &payload) {
            eprintln!("omaflow: could not update Quickshell overlay: {error}");
        }
    }

    fn remember_transcript(&mut self, transcript: &backend::Transcript) {
        if transcript.text.trim().is_empty() {
            return;
        }
        let clock_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let id = self
            .history
            .first()
            .map_or(clock_ms, |entry| clock_ms.max(entry.id.saturating_add(1)));
        if self.training_log_enabled {
            let sample = TrainingSample {
                schema_version: 2,
                created_at_ms: clock_ms,
                raw_asr: &transcript.raw_text,
                model_output: &transcript.text,
                cleanup_model: &self.cleanup_model,
                cleanup_fallback: !transcript.cleanup_warning.is_empty(),
            };
            if let Err(error) = append_training_sample(&self.training_log_path, &sample) {
                eprintln!("omaflow: could not append fine-tuning sample: {error}");
            }
        }
        if self.history_limit > 0 {
            self.history.insert(
                0,
                HistoryEntry {
                    id,
                    created_at_ms: clock_ms,
                    text: transcript.text.clone(),
                    raw_text: transcript.raw_text.clone(),
                    cleanup_model: self.cleanup_model.clone(),
                    pasted: transcript.pasted,
                    cleanup_warning: transcript.cleanup_warning.clone(),
                },
            );
            self.history.truncate(self.history_limit);
            self.persist_history();
        }
    }

    fn persist_history(&mut self) {
        if let Err(error) = write_history(&self.history_path, &self.history) {
            self.feedback_error = true;
            self.feedback = format!(
                "History could not be saved to disk: {error}. Keep a copy of this dictation before quitting."
            );
        }
    }
}

fn load_history(path: &Path, limit: usize) -> Vec<HistoryEntry> {
    if limit == 0 {
        return Vec::new();
    }
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut entries: Vec<HistoryEntry> = match serde_json::from_str(&text) {
        Ok(entries) => entries,
        Err(error) => {
            eprintln!("omaflow: ignoring invalid {}: {error}", path.display());
            return Vec::new();
        }
    };
    entries.retain(|entry| !entry.text.trim().is_empty());
    entries.truncate(limit);
    entries
}

fn write_history(path: &Path, history: &[HistoryEntry]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not protect {}: {error}", parent.display()))?;

    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(history).map_err(|error| error.to_string())?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| format!("{}: {error}", temporary.display()))?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("could not protect {}: {error}", temporary.display()))?;
    file.write_all(&bytes)
        .map_err(|error| format!("{}: {error}", temporary.display()))?;
    fs::rename(&temporary, path)
        .map_err(|error| format!("{} -> {}: {error}", temporary.display(), path.display()))
}

fn append_training_sample(path: &Path, sample: &TrainingSample<'_>) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not protect {}: {error}", parent.display()))?;

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("could not protect {}: {error}", path.display()))?;
    serde_json::to_writer(&mut file, sample).map_err(|error| error.to_string())?;
    file.write_all(b"\n")
        .map_err(|error| format!("{}: {error}", path.display()))
}

fn clamp_meter_gate(gate_db: i32) -> i32 {
    gate_db.clamp(-70, -35)
}

fn write_surface_state(path: &Path, state: &SurfaceState<'_>) -> Result<(), String> {
    let bytes = serde_json::to_vec(state).map_err(|error| error.to_string())?;
    let temporary = path.with_extension("json.tmp");
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| format!("{}: {error}", temporary.display()))?;
    file.write_all(&bytes)
        .map_err(|error| format!("{}: {error}", temporary.display()))?;
    fs::rename(&temporary, path)
        .map_err(|error| format!("{} -> {}: {error}", temporary.display(), path.display()))
}

fn start_backend_worker(
    config: Config,
    meter_gate_db: i32,
    jobs: mpsc::Receiver<BackendJob>,
    messages: mpsc::Sender<Message>,
) {
    thread::spawn(move || {
        // Warm-up runs on its own thread so audio commands stay responsive;
        // by the time a normal dictation ends the cleanup model is resident.
        let warm_config = config.clone();
        thread::spawn(move || {
            if warm_config.backend.managed() && warm_config.behavior.keep_models_loaded {
                let _ = backend::ensure_speech_server(&warm_config);
            }
            backend::warm_cleanup(&warm_config);
        });
        let mut runtime = backend::Runtime::new(config, meter_gate_db);
        let mut active_processing: Option<Arc<AtomicBool>> = None;
        // True from Stop until the transcription and cleanup of that
        // recording have finished, so idle release never races a job.
        let mut processing_busy: Option<Arc<AtomicBool>> = None;
        let mut recording_generation = 0;
        loop {
            let job = match jobs.recv_timeout(Duration::from_millis(50)) {
                Ok(job) => job,
                Err(RecvTimeoutError::Timeout) => {
                    if let Some(error) = runtime.capture_error() {
                        let _ = messages.send(Message::Failed(recording_generation, error));
                    }
                    let busy = processing_busy
                        .as_ref()
                        .is_some_and(|b| b.load(Ordering::Acquire));
                    if !busy && processing_busy.take().is_some() {
                        runtime.touch();
                    }
                    runtime.release_idle_models(busy);
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => break,
            };
            match job {
                BackendJob::ReloadConfig(config) => {
                    if let Err(error) = runtime.reload_config(*config) {
                        let _ = messages.send(Message::Feedback(Err(error), String::new()));
                    }
                }
                BackendJob::Start(generation) => {
                    recording_generation = generation;
                    runtime.touch();
                    if let Some(cancel) = active_processing.take() {
                        cancel.store(true, Ordering::Release);
                    }
                    if let Err(error) = runtime.start() {
                        let _ = messages.send(Message::Failed(generation, error));
                    }
                }
                BackendJob::Stop(generation) => {
                    runtime.touch();
                    match runtime.stop() {
                        Ok(session) => {
                            let cancel = Arc::clone(&session.cancel);
                            active_processing = Some(cancel);
                            let busy = Arc::new(AtomicBool::new(true));
                            processing_busy = Some(Arc::clone(&busy));
                            let completion_messages = messages.clone();
                            thread::spawn(move || {
                                match session.wait() {
                                    Ok(outcome) => {
                                        let _ = completion_messages
                                            .send(Message::Completed(generation, outcome));
                                    }
                                    Err(error) => {
                                        let _ = completion_messages
                                            .send(Message::Failed(generation, error));
                                    }
                                }
                                busy.store(false, Ordering::Release);
                            });
                        }
                        Err(error) => {
                            let _ = messages.send(Message::Failed(generation, error));
                        }
                    }
                }
                BackendJob::Cancel => {
                    runtime.cancel();
                    if let Some(cancel) = active_processing.take() {
                        cancel.store(true, Ordering::Release);
                    }
                }
                BackendJob::MeterPreviewStart => {
                    if let Err(error) = runtime.start_preview() {
                        eprintln!("omaflow: could not start microphone preview: {error}");
                    }
                }
                BackendJob::MeterPreviewStop => {
                    runtime.stop_preview();
                }
                BackendJob::SetMeterGate(gate_db) => {
                    runtime.set_meter_gate(gate_db);
                }
                BackendJob::SetPasteMode(paste_mode) => {
                    runtime.set_paste_mode(paste_mode);
                }
                BackendJob::SetCustomVocabulary(vocabulary) => {
                    runtime.set_custom_vocabulary(vocabulary);
                }
            }
        }
    });
}

fn start_status_worker(config: Config, messages: mpsc::Sender<Message>) {
    thread::spawn(move || {
        loop {
            let current = Config::load().unwrap_or_else(|_| config.clone());
            let status = RuntimeStatus {
                asr_running: current.behavior.models_configured
                    && backend::speech_server_ready(&current.backend),
                cleanup_loaded: current.behavior.models_configured
                    && cleanup_model_loaded(&current.cleanup),
                cleanup_available: current.behavior.models_configured
                    && cleanup_server_available(&current.cleanup.endpoint),
                update: update::status(),
                gpu_memory_mib: omaflow_gpu_memory_mib(),
                hotkey_display: read_hotkey_display(),
            };
            if messages.send(Message::RuntimeStatus(status)).is_err() {
                break;
            }
            thread::sleep(Duration::from_secs(5));
        }
    });
}

fn cleanup_server_available(endpoint: &str) -> bool {
    let Some((base, _)) = endpoint.split_once("/api/") else {
        return false;
    };
    Command::new("curl")
        .args([
            "--silent",
            "--fail",
            "--max-time",
            "1",
            &format!("{base}/api/tags"),
        ])
        .bounded_status()
        .is_ok_and(|status| status.success())
}

fn cleanup_model_loaded(config: &crate::config::Cleanup) -> bool {
    let Some(base) = config.endpoint.strip_suffix("/api/chat") else {
        return false;
    };
    Command::new("curl")
        .args([
            "--silent",
            "--fail",
            "--max-time",
            "1",
            &format!("{base}/api/ps"),
        ])
        .bounded_output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| serde_json::from_slice::<serde_json::Value>(&out.stdout).ok())
        .and_then(|body| body["models"].as_array().cloned())
        .is_some_and(|models| {
            models.iter().any(|model| {
                model["name"].as_str().is_some_and(|name| {
                    name == config.model || name.trim_end_matches(":latest") == config.model
                })
            })
        })
}

fn omaflow_gpu_memory_mib() -> u64 {
    let Some(output) = Command::new("nvidia-smi")
        .args([
            "--query-compute-apps=process_name,used_memory",
            "--format=csv,noheader,nounits",
        ])
        .bounded_output()
        .ok()
        .filter(|output| output.status.success())
    else {
        return 0;
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| line.contains("llama-server") || line.contains("nemo-speech"))
        .filter_map(|line| line.rsplit_once(',')?.1.trim().parse::<u64>().ok())
        .sum()
}

fn read_hotkey_display() -> String {
    let base = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_default();
    // The personal override wins, exactly as the adapter resolves it.
    [
        "omaflow/shortcut.lua",
        "hypr/omaflow-hotkey.lua",
        "hypr/omaflow.lua",
    ]
    .into_iter()
    .find_map(|name| {
        fs::read_to_string(base.join(name))
            .ok()
            .and_then(|text| parse_hotkey_display(&text))
    })
    .unwrap_or_else(|| "Custom binding".into())
}

fn parse_hotkey_display(text: &str) -> Option<String> {
    let line = text
        .lines()
        .find(|line| line.trim_start().starts_with("local omaflow_hotkey"))?;
    let keys: Vec<&str> = line
        .split('"')
        .enumerate()
        .filter_map(|(index, value)| (index % 2 == 1).then_some(value))
        .collect();
    if keys.is_empty() {
        return None;
    }
    Some(
        keys.into_iter()
            .map(|key| match key {
                "ISO_Level3_Shift" => "AltGr",
                "Control_L" | "Control_R" => "Ctrl",
                "Shift_L" | "Shift_R" => "Shift",
                "Super_L" | "Super_R" => "Super",
                other => other,
            })
            .collect::<Vec<_>>()
            .join(" + "),
    )
}

fn start_ipc(listener: UnixListener, messages: mpsc::Sender<Message>) {
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
            let mut value = String::new();
            if (&mut stream)
                .take(2_097_153)
                .read_to_string(&mut value)
                .is_err()
                || value.len() > 2_097_152
            {
                continue;
            }
            let value = value.trim();
            let command = match value {
                "press" => Some(Message::Session(SessionCommand::Press)),
                "release" => Some(Message::Session(SessionCommand::Release)),
                "stop" => Some(Message::Session(SessionCommand::Stop)),
                "cancel" => Some(Message::Session(SessionCommand::Cancel)),
                "close" => Some(Message::Session(SessionCommand::Close)),
                "copy" => Some(Message::Panel(PanelCommand::Copy)),
                "paste-last" => Some(Message::Panel(PanelCommand::PasteLast)),
                "history-undo" => Some(Message::Panel(PanelCommand::UndoDelete)),
                "refresh-update" => Some(Message::Panel(PanelCommand::RefreshUpdate)),
                "history-clear" => Some(Message::Panel(PanelCommand::ClearHistory)),
                "erase-data" => Some(Message::Panel(PanelCommand::EraseData)),
                "reload-config" => Some(Message::Panel(PanelCommand::ReloadConfig)),
                value if value.starts_with("configure:") => {
                    serde_json::from_str::<serde_json::Value>(&value[10..])
                        .ok()
                        .and_then(|v| {
                            Some(Message::Panel(PanelCommand::Configure(
                                v.get("key")?.as_str()?.into(),
                                v.get("value")?.clone(),
                            )))
                        })
                }
                value if value.starts_with("history-edit:") => {
                    serde_json::from_str::<serde_json::Value>(&value[13..])
                        .ok()
                        .and_then(|v| {
                            Some(Message::Panel(PanelCommand::EditHistory(
                                v.get("id")?.as_u64()?,
                                v.get("text")?.as_str()?.into(),
                            )))
                        })
                }
                value if value.starts_with("history-raw:") => value[12..]
                    .parse()
                    .ok()
                    .map(|id| Message::Panel(PanelCommand::CopyRaw(id))),
                "meter-preview-start" => Some(Message::Panel(PanelCommand::MeterPreviewStart)),
                "meter-preview-stop" => Some(Message::Panel(PanelCommand::MeterPreviewStop)),
                value if value.starts_with("meter-gate-preview:") => value
                    .strip_prefix("meter-gate-preview:")
                    .and_then(|gate| gate.parse().ok())
                    .map(|value| Message::Panel(PanelCommand::PreviewMeterGate(value))),
                value if value.starts_with("meter-gate:") => value
                    .strip_prefix("meter-gate:")
                    .and_then(|gate| gate.parse().ok())
                    .map(|value| Message::Panel(PanelCommand::SetMeterGate(value))),
                value if value.starts_with("paste-mode:") => value
                    .strip_prefix("paste-mode:")
                    .and_then(|mode| mode.parse().ok())
                    .map(|value| Message::Panel(PanelCommand::SetPasteMode(value))),
                value if value.starts_with("history-copy:") => value
                    .strip_prefix("history-copy:")
                    .and_then(|id| id.parse().ok())
                    .map(|value| Message::Panel(PanelCommand::CopyHistory(value))),
                value if value.starts_with("history-paste:") => value
                    .strip_prefix("history-paste:")
                    .and_then(|id| id.parse().ok())
                    .map(|value| Message::Panel(PanelCommand::PasteHistory(value))),
                value if value.starts_with("history-delete:") => value
                    .strip_prefix("history-delete:")
                    .and_then(|id| id.parse().ok())
                    .map(|value| Message::Panel(PanelCommand::DeleteHistory(value))),
                value if value.starts_with("vocabulary-add:") => value
                    .strip_prefix("vocabulary-add:")
                    .map(ToOwned::to_owned)
                    .map(|value| Message::Panel(PanelCommand::AddVocabulary(value))),
                value if value.starts_with("vocabulary-remove:") => value
                    .strip_prefix("vocabulary-remove:")
                    .map(ToOwned::to_owned)
                    .map(|value| Message::Panel(PanelCommand::RemoveVocabulary(value))),
                _ => None,
            };
            if let Some(command) = command {
                let _ = messages.send(command);
            }
        }
    });
}

fn history_command(command: &str, id: Option<String>) -> ExitCode {
    let Some(id) = id.and_then(|value| value.parse::<u64>().ok()) else {
        eprintln!("omaflow: {command} requires a numeric history ID");
        return ExitCode::FAILURE;
    };
    send_command(&format!("{command}:{id}"))
}

fn meter_gate_command(command: &str, gate_db: Option<String>) -> ExitCode {
    let Some(gate_db) = gate_db.and_then(|value| value.parse::<i32>().ok()) else {
        eprintln!("omaflow: {command} requires an integer from -70 to -35 dB");
        return ExitCode::FAILURE;
    };
    if !(-70..=-35).contains(&gate_db) {
        eprintln!("omaflow: {command} must be from -70 to -35 dB");
        return ExitCode::FAILURE;
    }
    send_command(&format!("{command}:{gate_db}"))
}

fn paste_mode_command(paste_mode: Option<String>) -> ExitCode {
    let Some(paste_mode) = paste_mode.and_then(|value| value.parse::<PasteMode>().ok()) else {
        eprintln!("omaflow: paste-mode must be auto, ctrl-v, shift-insert, or clipboard");
        return ExitCode::FAILURE;
    };
    send_command(&format!("paste-mode:{}", paste_mode.as_str()))
}

fn vocabulary_command(command: &str, value: Option<String>) -> ExitCode {
    let Some(value) = value.and_then(|value| normalize_vocabulary_entry(&value)) else {
        eprintln!("omaflow: {command} requires a term of at most 80 characters");
        return ExitCode::FAILURE;
    };
    send_command(&format!("{command}:{value}"))
}

fn normalize_vocabulary_entry(value: &str) -> Option<String> {
    let value = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if value.is_empty() || value.chars().count() > 80 || value.chars().any(char::is_control) {
        None
    } else {
        Some(value)
    }
}

fn send_command(command: &str) -> ExitCode {
    let path = socket_path();
    let deadline = Instant::now() + Duration::from_millis(300);
    let stream = loop {
        match UnixStream::connect(&path) {
            Ok(stream) => break Ok(stream),
            Err(error)
                if Instant::now() < deadline
                    && matches!(
                        error.kind(),
                        ErrorKind::NotFound | ErrorKind::ConnectionRefused
                    ) =>
            {
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => break Err(error),
        }
    };
    match stream {
        Ok(mut stream) => match stream
            .set_write_timeout(Some(Duration::from_secs(1)))
            .and_then(|_| stream.write_all(command.as_bytes()))
        {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("omaflow: could not send command: {error}");
                ExitCode::FAILURE
            }
        },
        Err(_) => {
            eprintln!("omaflow: daemon is not running");
            ExitCode::FAILURE
        }
    }
}

fn runtime_dir() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            env::temp_dir().join(format!("omaflow-{}", env::var("USER").unwrap_or_default()))
        })
}

fn socket_path() -> PathBuf {
    runtime_dir().join("omaflow.sock")
}

fn surface_state_path() -> PathBuf {
    runtime_dir().join("omaflow-state.json")
}

fn state_dir() -> PathBuf {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .unwrap_or_else(|| env::temp_dir().join("omaflow-state"))
        .join("omaflow")
}

fn history_path() -> PathBuf {
    state_dir().join("history.json")
}

fn training_log_path() -> PathBuf {
    state_dir().join("training.jsonl")
}

#[cfg(test)]
mod tests {

    #[test]
    fn every_backend_failure_becomes_one_actionable_sentence() {
        use super::friendly_error;
        let cases = [
            ("omaflow-asr.service did not start", "not answering"),
            (
                "could not connect to the managed speech server at http://x",
                "not answering",
            ),
            ("could not read microphone audio: broken pipe", "microphone"),
            (
                "timed out starting PipeWire microphone capture",
                "microphone",
            ),
            (
                "speech server returned an empty transcript",
                "Nothing was recognised",
            ),
            ("recording is too large for a standard WAV file", "too long"),
            ("dictation worker stopped unexpectedly", "stalled"),
            ("timed out finalizing microphone capture", "stalled"),
            ("Hyprland could not send the paste shortcut", "clipboard"),
            ("wl-copy failed", "clipboard"),
            ("local cleanup failed: connection refused", "cleanup model"),
            ("something nobody predicted", "Try again"),
        ];
        for (raw, expected) in cases {
            let friendly = friendly_error(raw);
            assert!(
                friendly.contains(expected),
                "{raw:?} produced {friendly:?}, expected it to mention {expected:?}"
            );
            assert!(!friendly.contains("curl") && !friendly.contains("service"));
        }
    }
    use super::*;

    #[test]
    fn displays_the_configured_hotkey_in_readable_form() {
        let lua = r#"local omaflow_hotkey = { "ISO_Level3_Shift", "Menu" }"#;
        assert_eq!(parse_hotkey_display(lua).as_deref(), Some("AltGr + Menu"));
    }

    #[test]
    fn normalizes_vocabulary_without_accepting_unsafe_values() {
        assert_eq!(
            normalize_vocabulary_entry("  QuickShell\tplugin  ").as_deref(),
            Some("QuickShell plugin")
        );
        assert!(normalize_vocabulary_entry("").is_none());
        assert!(normalize_vocabulary_entry(&"x".repeat(81)).is_none());
        assert!(normalize_vocabulary_entry("line\nbreak").is_some());
        assert!(normalize_vocabulary_entry("bad\u{0000}value").is_none());
    }

    #[test]
    fn training_samples_are_jsonl_and_owner_only() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = env::temp_dir().join(format!(
            "omaflow-training-test-{}-{nonce}",
            std::process::id()
        ));
        let path = directory.join("training.jsonl");
        let sample = TrainingSample {
            schema_version: 1,
            created_at_ms: 42,
            raw_asr: "uh ship on tuesday",
            model_output: "Ship on Tuesday.",
            cleanup_model: "test-model",
            cleanup_fallback: false,
        };

        append_training_sample(&path, &sample).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        let value: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
        assert_eq!(value["raw_asr"], "uh ship on tuesday");
        assert_eq!(value["model_output"], "Ship on Tuesday.");
        assert!(text.ends_with('\n'));
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );

        fs::remove_file(path).unwrap();
        fs::remove_dir(directory).unwrap();
    }
}
