mod backend;
mod catalog;
mod cleanup;
mod cli;
mod journal_cli;
mod todos_cli;
mod update;

// The core and platform crates are re-bound here so every module in this
// binary keeps addressing them as `crate::config`, `crate::process` and so on.
use omaflow_core::history::{self, HistoryEntry};
use omaflow_core::journal::{Journal, NewEntry};
use omaflow_core::todos::{NewTodo, TodoList};
use omaflow_core::{config, state, vocabulary};
use omaflow_platform::ducking as audio;
use omaflow_platform::process::{self, CommandExt};

use config::{Config, PasteDelivery, PasteMode};
use serde::{Deserialize, Serialize};
use state::{Action, Phase, StateMachine};
use std::{
    collections::HashMap,
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
    /// The card's own close button: closes it even mid-edit.
    Dismiss,
    /// Try again on a failed take, from its kept recording.
    Retry,
    /// Starts a journal entry, or saves the one being taken. With a later
    /// day, the entry is a note to yourself for that day.
    JournalToggle(Option<omaflow_core::date::Date>),
    /// The journal shortcut, pressed and let go: hold to talk, double-tap to
    /// keep going hands-free, exactly like the dictation key.
    JournalPress(Option<omaflow_core::date::Date>),
    JournalRelease,
    /// Throws away the journal entry or to-dos being taken.
    JournalDiscard,
    /// The to-do shortcut and button: hold, double-tap or toggle, like the
    /// journal's, but the words become tasks on the to-do list.
    TodoPress,
    TodoRelease,
    TodoToggle,
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
    JournalPlay(JournalPlayback),
    JournalStopPlayback,
    /// Takes back the to-dos the last capture added.
    UndoTodos,
    /// Where new to-dos go, picked in the pill or the composer. During a
    /// capture it also redirects that capture.
    TodoSetList(String),
    /// The card's list chip: moves the capture it announces to another list.
    TodoMoveCapture(String),
    /// A card that closes by itself waits while you point at it, open its
    /// list menu, or edit a to-do on it.
    CardHold(CardHold),
    /// Edits one of the to-dos the card announces.
    TodoCardEdit(TodoCardChange),
    /// Takes one of the to-dos the card announces back out.
    TodoCardRemove(TodoCardChange),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum CardHold {
    #[default]
    None,
    /// Pointed at, or its menu open: Esc still closes it.
    Hover,
    /// A to-do on it being edited: Esc ends the edit, not the card.
    Edit,
}

/// One of the card's to-dos, by its place and words, and for an edit, the
/// new words.
#[derive(Debug, Clone, Deserialize)]
struct TodoCardChange {
    index: usize,
    text: String,
    #[serde(default)]
    new_text: String,
}

/// How long a card that closes by itself has left.
#[derive(Debug, Serialize)]
struct CardTimer {
    total_ms: u64,
    /// None while it waits for you.
    remaining_ms: Option<u64>,
}

/// Where the Talk button in the To-dos tab sends a capture: the list it
/// shows, and on Today, a due date for to-dos that do not say one.
#[derive(Debug, Clone, Default, Deserialize)]
struct TodoTarget {
    #[serde(default)]
    list: Option<String>,
    #[serde(default)]
    due: Option<String>,
}

#[derive(Debug)]
enum Message {
    Session(SessionCommand),
    Panel(PanelCommand),
    PrepareUpdate(String),
    CancelUpdate(String, mpsc::Sender<bool>),
    Completed(u64, backend::StopOutcome),
    TodoToggleFor(TodoTarget),
    /// A take failed; true when its recording is kept for Try again.
    Failed(u64, String, bool),
    RuntimeStatus(RuntimeStatus),
    ModelProgress(String, DownloadProgress),
    Feedback(Result<(), String>, String),
    ResultCopied(u64, Result<(), String>),
    PlaybackFinished(u64),
}

#[derive(Debug)]
enum BackendJob {
    Start(u64),
    Stop(u64, backend::Take),
    /// Transcribe a failed take's kept recording again.
    Retry(u64, backend::Take),
    /// The failed take's card closed: drop its recording.
    Forget,
    Cancel,
    MeterPreviewStart,
    MeterPreviewStop,
    SetMeterGate(i32),
    SetPasteDelivery(PasteDelivery),
    SetCustomVocabulary(Vec<String>),
    ReloadConfig(Box<Config>),
}

#[derive(Debug, Clone, Default)]
struct RuntimeStatus {
    asr_running: bool,
    cleanup_loaded: bool,
    cleanup_available: bool,
    cleanup_runtime: CleanupRuntime,
    installed_speech: Vec<String>,
    installed_cleanup: Vec<String>,
    gpu_memory_mib: u64,
    hotkey_display: String,
    update: update::UpdateStatus,
}

/// What the panel needs to say about Ollama: install it, start it, or nothing.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum CleanupRuntime {
    Ready,
    Stopped,
    #[default]
    Missing,
}

impl CleanupRuntime {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Stopped => "stopped",
            Self::Missing => "missing",
        }
    }
}

/// One model download in flight, as reported by an `omaflow model-install`
/// process. `updated` is local bookkeeping: finished entries leave the panel
/// on their own, failures stay until the next attempt replaces them.
#[derive(Debug, Clone)]
struct DownloadProgress {
    state: String,
    percent: u8,
    message: String,
    updated: Instant,
}

/// Long enough for the panel to show a completed bar, short enough that the
/// list is empty again by the time the user looks back at it.
const DOWNLOAD_DONE_LINGER: Duration = Duration::from_secs(20);

#[derive(Debug, Clone, Copy, Default)]
enum ResultView {
    #[default]
    None,
    Success,
    Transcript,
    Notice,
    Error,
    JournalSaved,
    TodosSaved,
}

/// The to-dos the overlay announces after a capture, kept so Undo can take
/// exactly them back out.
#[derive(Debug, Clone, Serialize)]
struct TodosSaved {
    items: Vec<omaflow_core::todos::Todo>,
    /// Moved to another list from the card since.
    moved: bool,
}

/// The journal entry the overlay announces after a take is written down.
#[derive(Debug, Clone, Serialize)]
struct JournalSaved {
    date: String,
    id: u64,
    words: usize,
    duration_ms: u64,
}

/// A journal recording being played back. The panel draws progress from
/// `started_at_ms` and `offset_ms`; the daemon only says when it ends.
#[derive(Debug, Clone, Serialize, Deserialize)]
/// A recording being played back: a journal entry, or with an empty date a
/// kept dictation.
struct JournalPlayback {
    #[serde(default)]
    date: String,
    id: u64,
    #[serde(default)]
    offset_ms: u64,
    #[serde(default)]
    duration_ms: u64,
    #[serde(default)]
    started_at_ms: u64,
    #[serde(skip)]
    token: u64,
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
    duck_audio_percent: u8,
    paste_mode: &'a str,
    paste_shortcut: serde_json::Value,
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
    cleanup_runtime: &'a str,
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
    model_catalog: serde_json::Value,
    model_downloads: serde_json::Value,
    config_path: String,
    shortcut_settings: serde_json::Value,
    cleanup_enabled: bool,
    cleanup_level: &'static str,
    style: &'a str,
    use_window_context: bool,
    use_clipboard_context: bool,
    history_limit: usize,
    feedback: &'a str,
    feedback_error: bool,
    keep_models_loaded: bool,
    keep_dictation_audio: bool,
    paste_sent: bool,
    recording_elapsed_ms: u64,
    journal_take: bool,
    journal_saved: Option<&'a JournalSaved>,
    todo_take: bool,
    todos_saved: Option<&'a TodosSaved>,
    todos_revision: u64,
    /// Where the next to-do goes, or during a capture, where it is going.
    todo_list: &'a str,
    todo_settings: serde_json::Value,
    journal_revision: u64,
    journal_settings: serde_json::Value,
    journal_playback: Option<&'a JournalPlayback>,
    card_timer: Option<CardTimer>,
    /// A failed take's recording is kept: the card offers Try again.
    can_retry: bool,
    published_at_ms: u64,
    serial: u64,
}

struct Daemon {
    state: StateMachine,
    view: ResultView,
    transcript: String,
    error: String,
    close_at: Option<Duration>,
    /// The whole time a self-closing card is shown for, 0 for one that stays.
    close_total_ms: u64,
    card_hold: CardHold,
    /// The last take sent for transcribing, so Try again can send it again.
    last_take: Option<backend::Take>,
    /// The failed take's recording is kept, and Try again can use it.
    can_retry: bool,
    /// The daemon's clock, the one `close_at` is measured on.
    epoch: Instant,
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
    paste_delivery: PasteDelivery,
    generation: u64,
    update: update::UpdateStatus,
    effective_config: Config,
    message_tx: mpsc::Sender<Message>,
    feedback: String,
    feedback_error: bool,
    recording_started: Option<Instant>,
    paste_sent: bool,
    audio_ducked: bool,
    model_downloads: HashMap<String, DownloadProgress>,
    pending_update: Option<String>,
    /// True while the recording, or its processing, is a journal entry.
    journal_take: bool,
    journal_saved: Option<JournalSaved>,
    /// True while the recording, or its processing, is a list of to-dos.
    todo_take: bool,
    todos_saved: Option<TodosSaved>,
    /// The current list, "" for the Inbox, and the list and default due date
    /// of the capture being taken.
    todo_current: String,
    todo_take_list: String,
    todo_take_due: Option<omaflow_core::date::Date>,
    todo_request: Option<TodoTarget>,
    /// Bumped whenever the daemon writes the to-do list.
    todos_revision: u64,
    /// Bumped whenever the daemon writes to the journal, so an open window
    /// knows to read the day again.
    journal_revision: u64,
    playback: Option<(JournalPlayback, Arc<AtomicBool>)>,
    playback_token: u64,
    journal_started: Option<(omaflow_core::date::Date, String)>,
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
    audio::start();
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
    let paste_delivery = config.behavior.paste_delivery();
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
    let history = history::load(&history_path, config.behavior.history_limit);
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
        close_total_ms: 0,
        card_hold: CardHold::None,
        last_take: None,
        can_retry: false,
        epoch,
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
        paste_delivery,
        generation: 0,
        update: update::status(),
        effective_config: config.clone(),
        message_tx,
        feedback: String::new(),
        feedback_error: false,
        recording_started: None,
        paste_sent: false,
        audio_ducked: false,
        model_downloads: HashMap::new(),
        pending_update: None,
        journal_take: false,
        journal_saved: None,
        todo_take: false,
        todos_saved: None,
        todo_current: String::new(),
        todo_take_list: String::new(),
        todo_take_due: None,
        todo_request: None,
        todos_revision: 0,
        journal_revision: 0,
        playback: None,
        playback_token: 0,
        journal_started: None,
    };
    daemon.todo_current = daemon.todos().current_list();
    if !config.behavior.keep_dictation_audio {
        for entry in &mut daemon.history {
            entry.audio = false;
        }
    }
    daemon.prune_audio();
    if let Err(error) = forget_journal_recordings(&config) {
        eprintln!("omaflow: {error}");
    }
    daemon.publish();
    if let Err(error) = update::finalize_recovery_for_running_daemon() {
        eprintln!("omaflow: could not finalize update recovery: {error}");
    }

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
        if finish_update_handoff(&mut daemon) {
            break;
        }
        if daemon.close_at.is_some_and(|deadline| now >= deadline)
            && matches!(daemon.state.phase(), Phase::Result | Phase::Error)
        {
            daemon.keep_open();
            daemon.view = ResultView::None;
            daemon.state.close();
            daemon.publish();
        }
    }

    let _ = fs::remove_file(socket);
    audio::restore_now();
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
        Message::TodoToggleFor(target) => {
            daemon.todo_request = Some(target);
            handle_message(
                Message::Session(SessionCommand::TodoToggle),
                now,
                daemon,
                jobs,
            );
            daemon.todo_request = None;
        }
        Message::PrepareUpdate(transaction_id) => {
            daemon.pending_update = Some(transaction_id);
            daemon.feedback = "Finishing your dictation before the update.".into();
            daemon.feedback_error = false;
            daemon.publish();
        }
        Message::CancelUpdate(transaction_id, acknowledgement) => {
            let cancelled = cancel_pending_update(&mut daemon.pending_update, &transaction_id);
            let _ = acknowledgement.send(cancelled);
            if cancelled {
                daemon.feedback = "The update wait was cancelled. You can retry it.".into();
                daemon.feedback_error = true;
                daemon.publish();
            }
        }
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
                    daemon.prune_audio();
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
            if let Err(error) = Config::write_behavior_preferences(next, daemon.paste_delivery.mode)
            {
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
            daemon.paste_delivery = daemon.effective_config.behavior.paste_delivery();
            let _ = jobs.send(BackendJob::SetPasteDelivery(daemon.paste_delivery.clone()));
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
            // The shell reloads after every change to the file, including the
            // ones this daemon just wrote for the Settings panel; those are
            // already applied, so they reload nothing and say nothing.
            Ok(config)
                if serde_json::to_value(&config).ok()
                    == serde_json::to_value(&daemon.effective_config).ok()
                    && config.backend.api_key == daemon.effective_config.backend.api_key
                    && config.cleanup.api_key == daemon.effective_config.cleanup.api_key => {}
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
            daemon.keep_open();
            run_action(action, jobs, daemon);
            let mut errors = Vec::new();
            for path in [&daemon.history_path, &daemon.training_log_path] {
                if let Err(error) = fs::remove_file(path)
                    && error.kind() != ErrorKind::NotFound
                {
                    errors.push(format!("{}: {error}", path.display()));
                }
            }
            if let Err(error) = fs::remove_dir_all(audio_dir())
                && error.kind() != ErrorKind::NotFound
            {
                errors.push(format!("{}: {error}", audio_dir().display()));
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
                "History, its audio and training data deleted. Your clipboard is unchanged.",
            );
        }
        Message::Panel(PanelCommand::RefreshUpdate) => {
            daemon.update = update::status();
            daemon.publish();
        }
        Message::Session(command) => {
            // Esc while a to-do on the card is being edited ends the edit; the
            // card stays.
            if matches!(command, SessionCommand::Close) && daemon.card_hold == CardHold::Edit {
                return;
            }
            if matches!(
                command,
                SessionCommand::Press
                    | SessionCommand::Stop
                    | SessionCommand::Cancel
                    | SessionCommand::Close
                    | SessionCommand::Dismiss
                    | SessionCommand::JournalToggle(_)
                    | SessionCommand::JournalPress(_)
                    | SessionCommand::JournalDiscard
                    | SessionCommand::TodoPress
                    | SessionCommand::TodoToggle
            ) {
                daemon.keep_open();
            }
            let phase_before = daemon.state.phase().clone();
            let action = match command {
                SessionCommand::Press => {
                    if daemon.pending_update.is_some() || update::blocks_new_dictation() {
                        daemon.feedback =
                            "OmaFlow is finishing an update. New dictation is paused.".into();
                        daemon.feedback_error = false;
                        daemon.publish();
                        return;
                    }
                    daemon.view = ResultView::None;
                    daemon.error.clear();
                    let action = daemon.state.press(now);
                    if action == Action::Start {
                        daemon.generation = daemon.generation.wrapping_add(1);
                        daemon.journal_take = false;
                        daemon.todo_take = false;
                        // The microphone would record the playback.
                        daemon.stop_playback();
                    }
                    action
                }
                SessionCommand::JournalPress(target) => match daemon.state.phase() {
                    // A second tap locks it; a press while locked saves it.
                    Phase::Recording { .. } if daemon.journal_take => daemon.state.press(now),
                    Phase::Processing if daemon.journal_take => Action::None,
                    Phase::Recording { .. } | Phase::Processing => {
                        daemon.feedback =
                            "Finish the dictation first, then start the journal entry.".into();
                        daemon.feedback_error = false;
                        Action::None
                    }
                    Phase::Idle | Phase::Result | Phase::Error => {
                        start_journal(daemon, target, now, false)
                    }
                },
                SessionCommand::JournalRelease => {
                    if daemon.journal_take {
                        daemon.state.release(now)
                    } else {
                        Action::None
                    }
                }
                SessionCommand::JournalToggle(target) => match daemon.state.phase() {
                    Phase::Recording { .. } if daemon.journal_take => daemon.state.stop(),
                    // A second press while the entry is being written down.
                    Phase::Processing if daemon.journal_take => Action::None,
                    Phase::Recording { .. } | Phase::Processing => {
                        daemon.feedback =
                            "Finish the dictation first, then start the journal entry.".into();
                        daemon.feedback_error = false;
                        Action::None
                    }
                    Phase::Idle | Phase::Result | Phase::Error => {
                        start_journal(daemon, target, now, true)
                    }
                },
                SessionCommand::TodoPress => match daemon.state.phase() {
                    Phase::Recording { .. } if daemon.todo_take => daemon.state.press(now),
                    Phase::Processing if daemon.todo_take => Action::None,
                    Phase::Recording { .. } | Phase::Processing => {
                        daemon.feedback = "Finish this take first, then add to-dos.".into();
                        daemon.feedback_error = false;
                        Action::None
                    }
                    Phase::Idle | Phase::Result | Phase::Error => start_todos(daemon, now, false),
                },
                SessionCommand::TodoRelease => {
                    if daemon.todo_take {
                        daemon.state.release(now)
                    } else {
                        Action::None
                    }
                }
                SessionCommand::TodoToggle => match daemon.state.phase() {
                    Phase::Recording { .. } if daemon.todo_take => daemon.state.stop(),
                    Phase::Processing if daemon.todo_take => Action::None,
                    Phase::Recording { .. } | Phase::Processing => {
                        daemon.feedback = "Finish this take first, then add to-dos.".into();
                        daemon.feedback_error = false;
                        Action::None
                    }
                    Phase::Idle | Phase::Result | Phase::Error => start_todos(daemon, now, true),
                },
                SessionCommand::JournalDiscard => {
                    if daemon.journal_take || daemon.todo_take {
                        daemon.view = ResultView::None;
                        daemon.state.cancel()
                    } else {
                        Action::None
                    }
                }
                SessionCommand::Release => daemon.state.release(now),
                SessionCommand::Stop => daemon.state.stop(),
                SessionCommand::Cancel => {
                    daemon.view = ResultView::None;
                    daemon.state.cancel()
                }
                // Esc is bound in every app and never consumed, so it only ever
                // dismisses a card. Throwing a take away takes a deliberate
                // Discard or Cancel.
                SessionCommand::Close | SessionCommand::Dismiss => {
                    if matches!(daemon.state.phase(), Phase::Result | Phase::Error) {
                        daemon.view = ResultView::None;
                        daemon.state.close();
                        daemon.forget_failed_take(jobs);
                    }
                    Action::None
                }
                SessionCommand::Retry => {
                    if let (true, Some(take)) = (daemon.can_retry, daemon.last_take)
                        && daemon.state.retry()
                    {
                        daemon.can_retry = false;
                        daemon.view = ResultView::None;
                        daemon.error.clear();
                        if jobs
                            .send(BackendJob::Retry(daemon.generation, take))
                            .is_err()
                        {
                            daemon.state.failed();
                            daemon.view = ResultView::Error;
                            daemon.error = "speech backend worker stopped".into();
                        }
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
            let transcript = match outcome {
                backend::StopOutcome::NoSpeech => {
                    daemon.state.completed();
                    daemon.view = ResultView::Notice;
                    daemon.close_after(now, daemon.notice_visible_ms);
                    daemon.publish();
                    return;
                }
                backend::StopOutcome::Journal(entry) => {
                    daemon.save_journal(entry, now);
                    return;
                }
                backend::StopOutcome::Todos(todos) => {
                    daemon.save_todos(todos, now);
                    return;
                }
                backend::StopOutcome::Transcript(transcript) => transcript,
            };
            daemon.state.completed();
            daemon.transcript = transcript.text.clone();
            daemon.paste_sent = transcript.pasted;
            daemon.error = transcript.delivery_error.clone();
            daemon.feedback = transcript.cleanup_warning.clone();
            daemon.feedback_error = !transcript.cleanup_warning.is_empty();
            daemon.remember_transcript(&transcript);
            daemon.view = if transcript.pasted && !daemon.feedback_error {
                daemon.close_after(now, daemon.effective_config.behavior.success_visible_ms);
                ResultView::Success
            } else {
                daemon.keep_open();
                ResultView::Transcript
            };
            daemon.publish();
        }
        Message::Failed(generation, error, kept) => {
            if generation != daemon.generation
                || !matches!(
                    daemon.state.phase(),
                    Phase::Recording { .. } | Phase::Processing
                )
            {
                return;
            }
            eprintln!("omaflow: dictation failed: {error}");
            daemon.can_retry = kept && daemon.last_take.is_some();
            // With the recording kept, the card waits for Try again; your
            // words are at stake, so it does not leave on a timer.
            if daemon.can_retry {
                daemon.keep_open();
            } else {
                daemon.close_after(now, daemon.effective_config.behavior.error_visible_ms);
            }
            daemon.state.failed();
            daemon.view = ResultView::Error;
            daemon.error = failure_text(&error, daemon.can_retry);
            daemon.publish();
        }
        Message::PlaybackFinished(token) => {
            if daemon
                .playback
                .as_ref()
                .is_some_and(|(playback, _)| playback.token == token)
            {
                daemon.playback = None;
                daemon.publish();
            }
        }
        Message::Panel(PanelCommand::JournalPlay(request)) => daemon.play(request),
        Message::Panel(PanelCommand::UndoTodos) => daemon.undo_todos(),
        Message::Panel(PanelCommand::TodoSetList(list)) => daemon.set_todo_list(list),
        Message::Panel(PanelCommand::TodoMoveCapture(list)) => daemon.move_capture(list, now),
        Message::Panel(PanelCommand::CardHold(hold)) => {
            daemon.hold_card(hold, now);
            daemon.publish();
        }
        Message::Panel(PanelCommand::TodoCardEdit(change)) => daemon.edit_card_todo(change),
        Message::Panel(PanelCommand::TodoCardRemove(change)) => daemon.remove_card_todo(change),
        Message::Panel(PanelCommand::JournalStopPlayback) => {
            daemon.stop_playback();
            daemon.publish();
        }
        Message::ModelProgress(id, progress) => {
            daemon.model_downloads.insert(id, progress);
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
    match action {
        Action::Start => {
            daemon.recording_started = Some(Instant::now());
            audio::duck(daemon.effective_config.behavior.duck_audio_percent);
            daemon.audio_ducked = true;
        }
        Action::Stop | Action::Cancel => daemon.unduck(),
        Action::None => {}
    }
    if matches!(action, Action::Start) {
        daemon.can_retry = false;
    }
    let take = if daemon.todo_take {
        backend::Take::Todos
    } else if daemon.journal_take {
        backend::Take::Journal(backend::JournalTake {
            cleanup: daemon.effective_config.journal.cleanup,
            keep_recording: daemon.effective_config.journal.keep_recordings,
        })
    } else {
        backend::Take::Paste
    };
    let Some(job) = (match action {
        Action::Start => Some(BackendJob::Start(daemon.generation)),
        Action::Stop => {
            daemon.last_take = Some(take);
            Some(BackendJob::Stop(daemon.generation, take))
        }
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
/// The card's sentence for a failure. With the recording kept, the advice
/// to try again is the Try again button, and it says the words are safe.
fn failure_text(error: &str, kept: bool) -> String {
    let text = friendly_error(error);
    if !kept {
        return text;
    }
    let text = text
        .trim_end_matches(" Try again.")
        .replace(" — try again in a moment.", ".")
        .replace(
            " Try again, or restart it from the bar.",
            " If it keeps failing, restart OmaFlow from the bar.",
        );
    format!("{text} Your recording is kept.")
}

fn friendly_error(error: &str) -> String {
    let lowered = error.to_lowercase();
    let matches = |needles: &[&str]| needles.iter().any(|needle| lowered.contains(needle));

    if matches(&["speech model is not configured"]) {
        "The speech model is missing or ambiguous. Set an installed GGUF path in Settings → Advanced → Your own model."
    } else if matches(&["models not configured"]) {
        "Models not configured. Open Settings → Advanced → Models to finish setup."
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
    fn journal(&self) -> Journal {
        Journal::new(self.effective_config.journal.folder_path())
    }

    /// Writes a finished take into today's file. If that fails the words must
    /// not be lost, so they go to the clipboard and the card says so.
    fn save_journal(&mut self, entry: backend::JournalTranscript, now: Duration) {
        let (date, time) = self
            .journal_started
            .take()
            .unwrap_or_else(omaflow_platform::clock::local_now);
        let clock_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let words = entry.text.split_whitespace().count();
        let saved = self.journal().add(
            date,
            NewEntry {
                id: clock_ms,
                time: &time,
                text: &entry.text,
                typed: false,
                raw_text: &entry.raw_text,
                duration_ms: entry.duration_ms,
                peaks: entry.peaks,
                recording: entry.wav.as_deref(),
            },
        );
        match saved {
            Ok(saved) => {
                self.state.completed();
                self.journal_revision = self.journal_revision.wrapping_add(1);
                self.journal_saved = Some(JournalSaved {
                    date: date.to_string(),
                    id: saved.id,
                    words,
                    duration_ms: entry.duration_ms,
                });
                self.view = ResultView::JournalSaved;
                self.close_after(now, self.notice_visible_ms);
                self.feedback_error = !entry.cleanup_warning.is_empty();
                self.feedback = entry.cleanup_warning;
            }
            Err(error) => {
                eprintln!("omaflow: could not save journal entry: {error}");
                let text = entry.text;
                thread::spawn(move || {
                    let _ = backend::copy_text(&text);
                });
                self.state.failed();
                self.view = ResultView::Error;
                self.error = format!(
                    "The entry could not be saved, so its text is on your clipboard. {error}"
                );
                self.keep_open();
            }
        }
        self.publish();
    }

    /// Shows a finished card for `ms`, then closes it.
    fn close_after(&mut self, now: Duration, ms: u64) {
        self.close_at = Some(now + Duration::from_millis(ms));
        self.close_total_ms = ms;
        self.card_hold = CardHold::None;
    }

    /// The card stays until it is closed.
    fn keep_open(&mut self) {
        self.close_at = None;
        self.close_total_ms = 0;
        self.card_hold = CardHold::None;
    }

    /// A self-closing card waits while held, and when let go, gets its whole
    /// time again, so you are never cut off mid-read.
    fn hold_card(&mut self, hold: CardHold, now: Duration) {
        if self.close_total_ms == 0 || !matches!(self.state.phase(), Phase::Result | Phase::Error) {
            return;
        }
        self.card_hold = hold;
        self.close_at = match hold {
            CardHold::None => Some(now + Duration::from_millis(self.close_total_ms)),
            CardHold::Hover | CardHold::Edit => None,
        };
    }

    /// Long enough to read what was added: a second more per to-do.
    fn todo_card_ms(&self) -> u64 {
        let count = self
            .todos_saved
            .as_ref()
            .map_or(1, |saved| saved.items.len()) as u64;
        (self.notice_visible_ms + 1_000 * count.saturating_sub(1)).min(15_000)
    }

    fn edit_card_todo(&mut self, change: TodoCardChange) {
        let todos = self.todos();
        let result = todos
            .edit(change.index, &change.text, &change.new_text)
            .and_then(|()| todos.list());
        match result {
            Ok(listed) => {
                if let Some(saved) = self.todos_saved.as_mut() {
                    let fresh = listed.into_iter().find(|todo| todo.index == change.index);
                    if let (Some(item), Some(fresh)) = (
                        saved
                            .items
                            .iter_mut()
                            .find(|item| item.index == change.index),
                        fresh,
                    ) {
                        *item = fresh;
                    }
                }
                self.todos_revision = self.todos_revision.wrapping_add(1);
                self.publish();
            }
            Err(error) => self.operation_feedback(Err(error), ""),
        }
    }

    /// One wrong to-do out of a capture; the last one going closes the card,
    /// the same as Undo.
    fn remove_card_todo(&mut self, change: TodoCardChange) {
        let result = self
            .todos()
            .remove(&[(change.index, change.text.clone())], false);
        match result {
            Ok(_) => {
                self.todos_revision = self.todos_revision.wrapping_add(1);
                let mut empty = false;
                if let Some(saved) = self.todos_saved.as_mut() {
                    saved
                        .items
                        .retain(|item| !(item.index == change.index && item.text == change.text));
                    for item in saved.items.iter_mut() {
                        if item.index > change.index {
                            item.index -= 1;
                        }
                    }
                    empty = saved.items.is_empty();
                }
                if empty {
                    self.todos_saved = None;
                    if matches!(self.view, ResultView::TodosSaved) {
                        self.view = ResultView::None;
                        self.state.close();
                    }
                    self.keep_open();
                }
                self.publish();
            }
            Err(error) => self.operation_feedback(Err(error), ""),
        }
    }

    /// The failed take's card is gone, so its kept recording goes too.
    fn forget_failed_take(&mut self, jobs: &mpsc::Sender<BackendJob>) {
        if self.can_retry {
            self.can_retry = false;
            let _ = jobs.send(BackendJob::Forget);
        }
    }

    fn todos(&self) -> TodoList {
        TodoList::new(self.effective_config.todos.folder_path())
    }

    /// Adds a capture's tasks to the list. Like a journal entry, words that
    /// cannot be saved go to the clipboard rather than being lost.
    fn save_todos(&mut self, todos: backend::TodoTranscript, now: Duration) {
        let (today, clock) = omaflow_platform::clock::local_now();
        let list = self.todo_take_list.clone();
        // "Move the backups before Friday" is due Friday; without a date of
        // its own, a to-do captured on Today is due today.
        let items: Vec<NewTodo> = todos
            .items
            .iter()
            .map(|item| {
                let (text, due, time) = omaflow_core::todos::due(item, today, &clock);
                NewTodo {
                    text,
                    due: due.or(self.todo_take_due),
                    time,
                }
            })
            .collect();
        match self.todos().add(&items, &list) {
            Ok(items) => {
                self.state.completed();
                self.todos_revision = self.todos_revision.wrapping_add(1);
                self.todos_saved = Some(TodosSaved {
                    items,
                    moved: false,
                });
                // Adding to a list makes it the current one.
                self.remember_todo_list(&list);
                self.view = ResultView::TodosSaved;
                self.close_after(now, self.todo_card_ms());
                self.feedback_error = !todos.cleanup_warning.is_empty();
                self.feedback = todos.cleanup_warning;
            }
            Err(error) => {
                eprintln!("omaflow: could not save to-dos: {error}");
                let text = todos
                    .items
                    .iter()
                    .map(|item| format!("- [ ] {item}"))
                    .collect::<Vec<_>>()
                    .join("\n");
                thread::spawn(move || {
                    let _ = backend::copy_text(&text);
                });
                self.state.failed();
                self.view = ResultView::Error;
                self.error = format!(
                    "The to-dos could not be saved, so they are on your clipboard. {error}"
                );
                self.keep_open();
            }
        }
        self.publish();
    }

    fn remember_todo_list(&mut self, list: &str) {
        if let Err(error) = self.todos().set_current_list(list) {
            eprintln!("omaflow: could not remember the to-do list: {error}");
        }
        self.todo_current = list.to_string();
    }

    /// Picks where to-dos go. A capture still being taken goes there too.
    fn set_todo_list(&mut self, list: String) {
        self.remember_todo_list(&list);
        if self.todo_take
            && matches!(
                self.state.phase(),
                Phase::Recording { .. } | Phase::Processing
            )
        {
            self.todo_take_list = list;
        }
        self.publish();
    }

    /// The card's list chip: the capture moves, and that list becomes current.
    fn move_capture(&mut self, list: String, now: Duration) {
        let Some(saved) = self.todos_saved.as_ref() else {
            return;
        };
        let tasks: Vec<(usize, String)> = saved
            .items
            .iter()
            .map(|todo| (todo.index, todo.text.clone()))
            .collect();
        match self.todos().move_to(&tasks, &list) {
            Ok(items) => {
                self.todos_saved = Some(TodosSaved { items, moved: true });
                self.todos_revision = self.todos_revision.wrapping_add(1);
                self.remember_todo_list(&list);
                if matches!(self.view, ResultView::TodosSaved) {
                    let hold = self.card_hold;
                    self.close_after(now, self.todo_card_ms());
                    self.hold_card(hold, now);
                }
                self.publish();
            }
            Err(error) => self.operation_feedback(Err(error), ""),
        }
    }

    /// Undo on the "to-dos added" card: the capture's tasks come back out.
    fn undo_todos(&mut self) {
        let Some(saved) = self.todos_saved.take() else {
            return;
        };
        let tasks: Vec<(usize, String)> = saved
            .items
            .iter()
            .map(|todo| (todo.index, todo.text.clone()))
            .collect();
        let result = self.todos().remove(&tasks, false);
        self.todos_revision = self.todos_revision.wrapping_add(1);
        if matches!(self.view, ResultView::TodosSaved) {
            self.view = ResultView::None;
            self.state.close();
        }
        self.keep_open();
        match result {
            Ok(_) => {
                self.feedback.clear();
                self.feedback_error = false;
                self.publish();
            }
            Err(error) => self.operation_feedback(Err(error), ""),
        }
    }

    /// Plays a journal recording, or with an empty date a kept dictation.
    fn play(&mut self, mut request: JournalPlayback) {
        self.stop_playback();
        let path = if request.date.is_empty() {
            audio_path(request.id)
        } else {
            let Ok(date) = request.date.parse() else {
                return;
            };
            self.journal().recording_path(date, request.id)
        };
        let duration_ms = omaflow_platform::sound::wav_duration_ms(&path).unwrap_or(0);
        if duration_ms == 0 {
            self.operation_feedback(Err("That recording is no longer on disk.".into()), "");
            return;
        }
        self.playback_token = self.playback_token.wrapping_add(1);
        request.token = self.playback_token;
        request.duration_ms = duration_ms;
        request.offset_ms = request.offset_ms.min(duration_ms.saturating_sub(1));
        request.started_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let messages = self.message_tx.clone();
        let (token, offset_ms) = (request.token, request.offset_ms);
        thread::spawn(move || {
            if let Err(error) = omaflow_platform::sound::play_wav(&path, offset_ms, worker_stop) {
                eprintln!("omaflow: could not play journal recording: {error}");
            }
            let _ = messages.send(Message::PlaybackFinished(token));
        });
        self.playback = Some((request, stop));
        self.publish();
    }

    fn stop_playback(&mut self) {
        if let Some((_, stop)) = self.playback.take() {
            stop.store(true, Ordering::Release);
        }
    }

    /// Deletes kept recordings whose dictation is gone. A deletion that can
    /// still be undone keeps its recording until the undo is no longer offered.
    fn prune_audio(&self) {
        let Ok(files) = fs::read_dir(audio_dir()) else {
            return;
        };
        let kept = |id: u64| {
            self.history
                .iter()
                .any(|entry| entry.id == id && entry.audio)
                || self
                    .last_deleted
                    .iter()
                    .flatten()
                    .any(|entry| entry.id == id && entry.audio)
        };
        for file in files.flatten() {
            let path = file.path();
            let id = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .and_then(|stem| stem.parse::<u64>().ok());
            if id.is_none_or(|id| !kept(id)) {
                let _ = fs::remove_file(path);
            }
        }
    }

    fn save_history_change(&mut self, next: Vec<HistoryEntry>, undo: bool, label: &str) -> bool {
        let result = history::write(&self.history_path, &next);
        let saved = result.is_ok();
        if saved {
            if undo {
                self.last_deleted = Some(self.history.clone());
            }
            self.history = next;
            self.prune_audio();
        }
        self.operation_feedback(result, label);
        saved
    }

    fn paste_async(&self, text: String) {
        let messages = self.message_tx.clone();
        let delivery = self.paste_delivery.clone();
        thread::spawn(move || {
            let result = backend::paste_text_now(&text, &delivery);
            let label = if delivery.mode == PasteMode::Clipboard {
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
        // Turning dictation audio off deletes what was kept, as the setting says.
        if !config.behavior.keep_dictation_audio {
            for entry in self
                .history
                .iter_mut()
                .chain(self.last_deleted.iter_mut().flatten())
            {
                entry.audio = false;
            }
        }
        let retained = history::write(&self.history_path, &self.history);
        self.prune_audio();
        let recordings = forget_journal_recordings(&config);
        self.clipboard_result_visible_ms = config.behavior.clipboard_result_visible_ms;
        self.error_visible_ms = config.behavior.error_visible_ms;
        self.notice_visible_ms = config.behavior.notice_visible_ms;
        self.meter_gate_db = clamp_meter_gate(config.behavior.meter_gate_db);
        self.paste_delivery = config.behavior.paste_delivery();
        self.custom_vocabulary = config.cleanup.custom_vocabulary.clone();
        self.cleanup_model = config.cleanup.model.clone();
        self.state.configure(
            config.behavior.double_tap_ms,
            config.behavior.max_recording_seconds,
        );
        self.effective_config = config;
        self.todo_current = self.todos().current_list();
        self.journal_revision = self.journal_revision.wrapping_add(1);
        retained
            .map_err(|error| {
                format!("Settings saved, but stored history could not be updated: {error}")
            })
            .and(recordings.map_err(|error| {
                format!("Settings saved, but journal recordings could not be deleted: {error}")
            }))
    }
    fn operation_feedback(&mut self, outcome: Result<(), String>, success: &str) {
        self.feedback_error = outcome.is_err();
        self.feedback = outcome.err().unwrap_or_else(|| success.into());
        self.publish();
    }

    /// Idempotent: restore is cheap and a duck that is never undone leaves the
    /// user's speakers turned down, which is the worst way for this to fail.
    fn unduck(&mut self) {
        if self.audio_ducked {
            self.audio_ducked = false;
            audio::restore();
        }
    }

    fn publish(&mut self) {
        if !matches!(self.state.phase(), Phase::Recording { .. }) {
            self.unduck();
        }
        self.model_downloads.retain(|_, progress| {
            progress.state != "done" || progress.updated.elapsed() < DOWNLOAD_DONE_LINGER
        });
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
                    ResultView::JournalSaved => "journal-saved",
                    ResultView::TodosSaved => "todos-saved",
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
            duck_audio_percent: self.effective_config.behavior.duck_audio_percent,
            paste_mode: self.paste_delivery.mode.as_str(),
            paste_shortcut: serde_json::to_value(&self.paste_delivery.shortcut).unwrap_or_default(),
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
            cleanup_runtime: self.runtime_status.cleanup_runtime.as_str(),
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
                "cleanup_engine": self.effective_config.cleanup.engine,
                "cleanup_model": self.effective_config.cleanup.model,
                "cleanup_endpoint": self.effective_config.cleanup.endpoint,
                // The keys themselves never leave the process: this file is a
                // world of other readers, and the panel only needs to know
                // whether to draw a set field or an empty one.
                "speech_api_key_set": !self.effective_config.backend.api_key.is_empty(),
                "cleanup_api_key_set": !self.effective_config.cleanup.api_key.is_empty(),
            }),
            model_catalog: catalog::to_json(
                &self.effective_config,
                &self.runtime_status.installed_speech,
                &self.runtime_status.installed_cleanup,
            ),
            model_downloads: downloads_json(&self.model_downloads),
            cleanup_enabled: self.effective_config.cleanup.enabled,
            cleanup_level: self.effective_config.cleanup.level(),
            style: &self.effective_config.cleanup.style,
            use_window_context: self.effective_config.cleanup.use_window_context,
            use_clipboard_context: self.effective_config.cleanup.use_clipboard_context,
            history_limit: self.history_limit,
            feedback: &self.feedback,
            feedback_error: self.feedback_error,
            keep_models_loaded: self.effective_config.behavior.keep_models_loaded,
            keep_dictation_audio: self.effective_config.behavior.keep_dictation_audio,
            paste_sent: self.paste_sent,
            recording_elapsed_ms: if matches!(self.state.phase(), Phase::Recording { .. }) {
                self.recording_started
                    .map_or(0, |started| started.elapsed().as_millis() as u64)
            } else {
                0
            },
            journal_take: self.journal_take,
            journal_saved: self.journal_saved.as_ref(),
            todo_take: self.todo_take,
            todos_saved: self.todos_saved.as_ref(),
            todos_revision: self.todos_revision,
            todo_list: if self.todo_take
                && matches!(
                    self.state.phase(),
                    Phase::Recording { .. } | Phase::Processing
                ) {
                &self.todo_take_list
            } else {
                &self.todo_current
            },
            todo_settings: serde_json::json!({
                "folder": self.effective_config.todos.folder,
                "folder_path": self.effective_config.todos.folder_path(),
                "file_path": self.todos().path(),
            }),
            journal_revision: self.journal_revision,
            journal_settings: serde_json::json!({
                "folder": self.effective_config.journal.folder,
                "folder_path": self.effective_config.journal.folder_path(),
                "cleanup": self.effective_config.journal.cleanup.as_str(),
                "keep_recordings": self.effective_config.journal.keep_recordings,
                "empty_day_question": self.effective_config.journal.empty_day_question,
            }),
            journal_playback: self.playback.as_ref().map(|(playback, _)| playback),
            can_retry: self.can_retry,
            card_timer: (self.close_total_ms > 0).then(|| CardTimer {
                total_ms: self.close_total_ms,
                remaining_ms: self.close_at.map(|deadline| {
                    deadline.saturating_sub(self.epoch.elapsed()).as_millis() as u64
                }),
            }),
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
            let audio = transcript.wav.as_deref().is_some_and(|wav| {
                omaflow_core::fsutil::private_dir(&audio_dir())
                    .and_then(|()| omaflow_core::fsutil::write_private(&audio_path(id), wav))
                    .inspect_err(|error| {
                        eprintln!("omaflow: could not keep dictation audio: {error}")
                    })
                    .is_ok()
            });
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
                    audio,
                },
            );
            self.history.truncate(self.history_limit);
            self.persist_history();
            self.prune_audio();
        }
    }

    fn persist_history(&mut self) {
        if let Err(error) = history::write(&self.history_path, &self.history) {
            self.feedback_error = true;
            self.feedback = format!(
                "History could not be saved to disk: {error}. Keep a copy of this dictation before quitting."
            );
        }
    }
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
                        let _ = messages.send(Message::Failed(recording_generation, error, false));
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
                        let _ = messages.send(Message::Failed(generation, error, false));
                    }
                }
                BackendJob::Forget => runtime.forget_kept(),
                BackendJob::Stop(generation, take) | BackendJob::Retry(generation, take) => {
                    runtime.touch();
                    let retrying = matches!(job, BackendJob::Retry(..));
                    let kept = runtime.kept_recording();
                    match if retrying {
                        runtime.retry(take)
                    } else {
                        runtime.stop(take)
                    } {
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
                                        let kept = kept.lock().is_ok_and(|kept| kept.is_some());
                                        let _ = completion_messages
                                            .send(Message::Failed(generation, error, kept));
                                    }
                                }
                                busy.store(false, Ordering::Release);
                            });
                        }
                        Err(error) => {
                            let _ = messages.send(Message::Failed(generation, error, false));
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
                BackendJob::SetPasteDelivery(delivery) => {
                    runtime.set_paste_delivery(delivery);
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
        let mut installed_cleanup: Option<(Vec<String>, Instant)> = None;
        loop {
            let current = Config::load().unwrap_or_else(|_| config.clone());
            // Nothing here may reach for a model the user has not asked for.
            // Cleanup is opt-in, so until it is switched on the daemon neither
            // probes the Ollama endpoint nor enumerates what it holds.
            let endpoint_answers =
                current.cleanup.enabled && cleanup_server_available(&current.cleanup);
            // Asking Ollama about every catalog model spawns a process each,
            // so it runs far less often than the rest of this poll.
            if current.cleanup.engine != "ollama" {
                installed_cleanup = None;
            } else if current.cleanup.enabled
                && installed_cleanup
                    .as_ref()
                    .is_none_or(|(_, checked): &(Vec<String>, Instant)| {
                        checked.elapsed() >= Duration::from_secs(30)
                    })
            {
                installed_cleanup = Some((
                    catalog::installed_cleanup_ids(&current.cleanup.endpoint),
                    Instant::now(),
                ));
            }
            let status = RuntimeStatus {
                asr_running: current.behavior.models_configured
                    && backend::speech_server_ready(&current.backend),
                cleanup_loaded: current.behavior.models_configured
                    && cleanup_model_loaded(&current.cleanup),
                cleanup_available: current.behavior.models_configured && endpoint_answers,
                // Reported only while cleanup is on, for the same reason: with
                // it off the panel has no notice to show and no question to ask.
                cleanup_runtime: cleanup_runtime(
                    current.cleanup.enabled,
                    endpoint_answers,
                    catalog::endpoint_is_local(&current.cleanup.endpoint),
                    current.cleanup.engine != "ollama" || catalog::ollama_on_path(),
                ),
                installed_speech: catalog::installed_speech_ids(),
                installed_cleanup: installed_cleanup
                    .as_ref()
                    .map(|(ids, _)| ids.clone())
                    .unwrap_or_default(),
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

/// A server that answers is running, whoever installed it and wherever it is.
/// Only a loopback endpoint that nothing answers can be a missing local
/// install; a remote one that is silent is simply not reachable right now.
fn cleanup_runtime(
    enabled: bool,
    endpoint_answers: bool,
    endpoint_is_local: bool,
    binary_on_path: bool,
) -> CleanupRuntime {
    if !enabled || endpoint_answers {
        CleanupRuntime::Ready
    } else if endpoint_is_local && !binary_on_path {
        CleanupRuntime::Missing
    } else {
        CleanupRuntime::Stopped
    }
}

fn cleanup_server_available(config: &crate::config::Cleanup) -> bool {
    let endpoint = if config.engine == "openai" {
        config.endpoint.clone()
    } else {
        let Some((base, _)) = config.endpoint.split_once("/api/") else {
            return false;
        };
        format!("{base}/api/tags")
    };
    let Ok(auth) = crate::process::CurlAuth::new(&config.api_key) else {
        return false;
    };
    auth.apply(&mut Command::new("curl"))
        .args([
            "--silent",
            "--max-time",
            "1",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            &endpoint,
        ])
        .bounded_output()
        .ok()
        .is_some_and(|output| {
            let code = String::from_utf8_lossy(&output.stdout);
            output.status.success()
                && (code.starts_with('2') || (config.engine == "openai" && code == "405"))
        })
}

fn cleanup_model_loaded(config: &crate::config::Cleanup) -> bool {
    if config.engine != "ollama" {
        return false;
    }
    let Some(base) = config.endpoint.strip_suffix("/api/chat") else {
        return false;
    };
    let Ok(auth) = crate::process::CurlAuth::new(&config.api_key) else {
        return false;
    };
    auth.apply(&mut Command::new("curl"))
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
            if let Some(expected) = value.strip_prefix("health:") {
                if update::running_release_commit().as_deref() == Some(expected) {
                    let _ = stream.write_all(format!("ready:{expected}\n").as_bytes());
                }
                continue;
            }
            if let Some(id) = value.strip_prefix("cancel-update:") {
                if valid_transaction_id(id) {
                    let (acknowledgement, received) = mpsc::channel();
                    if messages
                        .send(Message::CancelUpdate(id.into(), acknowledgement))
                        .is_ok()
                        && received.recv_timeout(Duration::from_secs(2)) == Ok(true)
                    {
                        let _ = stream.write_all(format!("cancelled:{id}\n").as_bytes());
                    }
                }
                continue;
            }
            let command = match value {
                "press" => Some(Message::Session(SessionCommand::Press)),
                "release" => Some(Message::Session(SessionCommand::Release)),
                "stop" => Some(Message::Session(SessionCommand::Stop)),
                "cancel" => Some(Message::Session(SessionCommand::Cancel)),
                "close" => Some(Message::Session(SessionCommand::Close)),
                "dismiss" => Some(Message::Session(SessionCommand::Dismiss)),
                "retry" => Some(Message::Session(SessionCommand::Retry)),
                "journal-toggle" => Some(Message::Session(SessionCommand::JournalToggle(None))),
                "journal-press" => Some(Message::Session(SessionCommand::JournalPress(None))),
                "journal-release" => Some(Message::Session(SessionCommand::JournalRelease)),
                value if value.starts_with("journal-toggle:") => value["journal-toggle:".len()..]
                    .parse()
                    .ok()
                    .map(|day| Message::Session(SessionCommand::JournalToggle(Some(day)))),
                "journal-discard" | "todo-discard" => {
                    Some(Message::Session(SessionCommand::JournalDiscard))
                }
                "todo-press" => Some(Message::Session(SessionCommand::TodoPress)),
                "todo-release" => Some(Message::Session(SessionCommand::TodoRelease)),
                "todo-toggle" => Some(Message::Session(SessionCommand::TodoToggle)),
                value if value.starts_with("todo-toggle:") => {
                    serde_json::from_str::<TodoTarget>(&value["todo-toggle:".len()..])
                        .ok()
                        .map(Message::TodoToggleFor)
                }
                value if value.starts_with("todo-list:") => Some(Message::Panel(
                    PanelCommand::TodoSetList(value["todo-list:".len()..].trim().to_string()),
                )),
                value if value.starts_with("todo-move:") => Some(Message::Panel(
                    PanelCommand::TodoMoveCapture(value["todo-move:".len()..].trim().to_string()),
                )),
                "card-hold" => Some(Message::Panel(PanelCommand::CardHold(CardHold::Hover))),
                "card-edit" => Some(Message::Panel(PanelCommand::CardHold(CardHold::Edit))),
                "card-resume" => Some(Message::Panel(PanelCommand::CardHold(CardHold::None))),
                value if value.starts_with("todo-card-edit:") => {
                    serde_json::from_str(&value["todo-card-edit:".len()..])
                        .ok()
                        .map(|change| Message::Panel(PanelCommand::TodoCardEdit(change)))
                }
                value if value.starts_with("todo-card-remove:") => {
                    serde_json::from_str(&value["todo-card-remove:".len()..])
                        .ok()
                        .map(|change| Message::Panel(PanelCommand::TodoCardRemove(change)))
                }
                "todo-undo" => Some(Message::Panel(PanelCommand::UndoTodos)),
                "journal-stop-playback" => Some(Message::Panel(PanelCommand::JournalStopPlayback)),
                value if value.starts_with("history-play:") => {
                    serde_json::from_str::<JournalPlayback>(&value["history-play:".len()..])
                        .ok()
                        .map(|request| {
                            Message::Panel(PanelCommand::JournalPlay(JournalPlayback {
                                date: String::new(),
                                ..request
                            }))
                        })
                }
                value if value.starts_with("journal-play:") => {
                    serde_json::from_str::<JournalPlayback>(&value["journal-play:".len()..])
                        .ok()
                        .map(|request| Message::Panel(PanelCommand::JournalPlay(request)))
                }
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
                value if value.starts_with("prepare-update:") => {
                    let id = &value["prepare-update:".len()..];
                    if valid_transaction_id(id) {
                        Some(Message::PrepareUpdate(id.into()))
                    } else {
                        None
                    }
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
                value if value.starts_with("model-progress:") => {
                    parse_model_progress(&value["model-progress:".len()..])
                }
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

fn valid_transaction_id(id: &str) -> bool {
    id.len() <= 96
        && !id.is_empty()
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn cancel_pending_update(pending: &mut Option<String>, id: &str) -> bool {
    if pending.as_deref() != Some(id) {
        return false;
    }
    *pending = None;
    true
}

fn finish_update_handoff(daemon: &mut Daemon) -> bool {
    if !matches!(
        daemon.state.phase(),
        Phase::Idle | Phase::Result | Phase::Error
    ) {
        return false;
    }
    let Some(transaction_id) = daemon.pending_update.take() else {
        return false;
    };
    let marker = runtime_dir().join(format!("omaflow-update-ready-{transaction_id}"));
    let result = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&marker)
        .and_then(|mut file| file.write_all(b"ready\n"))
        .and_then(|_| fs::File::open(runtime_dir())?.sync_all());
    if let Err(error) = result {
        eprintln!("omaflow: could not prepare update handoff: {error}");
        return false;
    }
    true
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
        eprintln!("omaflow: paste-mode must be auto, ctrl-v, shift-insert, clipboard, or custom");
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

/// The panel only ever renders these, so anything malformed is dropped rather
/// than shown: a stray socket write must not put text in front of the user.
fn parse_model_progress(payload: &str) -> Option<Message> {
    let value: serde_json::Value = serde_json::from_str(payload).ok()?;
    let id = value.get("id")?.as_str()?;
    let state = value.get("state")?.as_str()?;
    if id.is_empty()
        || id.len() > 512
        || !matches!(state, "downloading" | "done" | "failed")
        || id.chars().any(char::is_control)
    {
        return None;
    }
    let message: String = value
        .get("message")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .chars()
        .filter(|character| !character.is_control())
        .take(300)
        .collect();
    Some(Message::ModelProgress(
        id.to_owned(),
        DownloadProgress {
            state: state.to_owned(),
            percent: value
                .get("percent")
                .and_then(serde_json::Value::as_u64)
                .unwrap_or(0)
                .min(100) as u8,
            message,
            updated: Instant::now(),
        },
    ))
}

fn downloads_json(downloads: &HashMap<String, DownloadProgress>) -> serde_json::Value {
    serde_json::Value::Object(
        downloads
            .iter()
            .map(|(id, progress)| {
                (
                    id.clone(),
                    serde_json::json!({
                        "state": progress.state,
                        "percent": progress.percent,
                        "message": progress.message,
                    }),
                )
            })
            .collect(),
    )
}

/// Best-effort delivery for callers that must keep working with no daemon:
/// true when the command reached one, false when none was listening.
pub fn send_command_quiet(command: &str) -> bool {
    UnixStream::connect(socket_path())
        .and_then(|mut stream| {
            stream.set_write_timeout(Some(Duration::from_secs(1)))?;
            stream.write_all(command.as_bytes())
        })
        .is_ok()
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

use omaflow_platform::runtime_dir;

fn socket_path() -> PathBuf {
    runtime_dir().join("omaflow.sock")
}

fn surface_state_path() -> PathBuf {
    runtime_dir().join("omaflow-state.json")
}

/// Starts a journal entry: `latched` for the Talk button and the old toggle,
/// otherwise held like the dictation key. Filed under when you started
/// talking, so a take that crosses midnight stays on the day it began; a take
/// for a later day is a note, headed with when it was written.
fn start_journal(
    daemon: &mut Daemon,
    target: Option<omaflow_core::date::Date>,
    now: Duration,
    latched: bool,
) -> Action {
    if daemon.pending_update.is_some() || update::blocks_new_dictation() {
        daemon.feedback = "OmaFlow is finishing an update. New entries are paused.".into();
        daemon.feedback_error = false;
        return Action::None;
    }
    daemon.view = ResultView::None;
    daemon.error.clear();
    daemon.stop_playback();
    let action = if latched {
        daemon.state.start_latched(now)
    } else {
        daemon.state.press(now)
    };
    if action == Action::Start {
        daemon.generation = daemon.generation.wrapping_add(1);
        daemon.journal_take = true;
        daemon.todo_take = false;
        let (today, time) = omaflow_platform::clock::local_now();
        daemon.journal_started = Some(match target {
            Some(day) if day > today => (day, omaflow_core::journal::note_heading(today, &time)),
            _ => (today, time),
        });
    }
    action
}

/// Starts a to-do capture: `latched` for the Talk button, otherwise held
/// like the dictation key.
fn start_todos(daemon: &mut Daemon, now: Duration, latched: bool) -> Action {
    if daemon.pending_update.is_some() || update::blocks_new_dictation() {
        daemon.feedback = "OmaFlow is finishing an update. New to-dos are paused.".into();
        daemon.feedback_error = false;
        return Action::None;
    }
    let request = daemon.todo_request.take().unwrap_or_default();
    daemon.view = ResultView::None;
    daemon.error.clear();
    daemon.stop_playback();
    let action = if latched {
        daemon.state.start_latched(now)
    } else {
        daemon.state.press(now)
    };
    if action == Action::Start {
        daemon.generation = daemon.generation.wrapping_add(1);
        daemon.journal_take = false;
        daemon.todo_take = true;
        daemon.todos_saved = None;
        // The list the Talk button showed, or the current list; a list
        // deleted since falls back to the Inbox.
        let lists = daemon.todos().lists().unwrap_or_default();
        daemon.todo_take_list = request
            .list
            .filter(|list| list.is_empty() || lists.contains(list))
            .unwrap_or_else(|| daemon.todos().current_list());
        daemon.todo_take_due = request.due.and_then(|due| due.parse().ok());
    }
    action
}

fn state_dir() -> PathBuf {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .unwrap_or_else(|| env::temp_dir().join("omaflow-state"))
        .join("omaflow")
}

/// Kept dictation recordings, one WAV per history entry id.
/// Turning journal recordings off deletes the ones already kept, as the
/// setting says.
fn forget_journal_recordings(config: &Config) -> Result<(), String> {
    if config.journal.keep_recordings {
        return Ok(());
    }
    omaflow_core::journal::Journal::new(config.journal.folder_path()).delete_recordings()
}

fn audio_dir() -> PathBuf {
    state_dir().join("audio")
}

fn audio_path(id: u64) -> PathBuf {
    audio_dir().join(format!("{id}.wav"))
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
    fn update_cancel_only_clears_the_matching_handoff() {
        let mut pending = Some("tx-one".to_string());
        assert!(!super::cancel_pending_update(&mut pending, "tx-two"));
        assert_eq!(pending.as_deref(), Some("tx-one"));
        assert!(super::cancel_pending_update(&mut pending, "tx-one"));
        assert!(pending.is_none());
    }

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
    fn a_reachable_cleanup_server_is_ready_wherever_it_runs() {
        use super::{CleanupRuntime, cleanup_runtime};
        // Remote endpoint, no local ollama: answering wins, silence is stopped.
        assert_eq!(
            cleanup_runtime(true, true, false, false),
            CleanupRuntime::Ready
        );
        assert_eq!(
            cleanup_runtime(true, false, false, false),
            CleanupRuntime::Stopped
        );
        // Loopback: installed but silent is stopped, absent is missing.
        assert_eq!(
            cleanup_runtime(true, false, true, true),
            CleanupRuntime::Stopped
        );
        assert_eq!(
            cleanup_runtime(true, false, true, false),
            CleanupRuntime::Missing
        );
        // Cleanup off asks the user nothing at all.
        assert_eq!(
            cleanup_runtime(false, false, true, false),
            CleanupRuntime::Ready
        );
    }

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
