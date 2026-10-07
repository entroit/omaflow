//! Command-line entry points. Interactive requests use the daemon IPC channel.
use crate::catalog::{self, CatalogEntry, Kind};
use crate::process::CommandExt;
use crate::surface_state_path;
use crate::{
    backend, config::Config, history_command, meter_gate_command, notify, paste_mode_command,
    press_key, read_hotkey_display, run_daemon, send_command, send_command_quiet, send_press,
    update, vocabulary_command,
};
use std::{
    env, fs,
    io::Read,
    process::{Command, ExitCode, Stdio},
    time::{Duration, Instant},
};

pub fn run() -> ExitCode {
    let mut args = env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "daemon".into());
    match command.as_str() {
        "daemon" => run_daemon(),
        "config-init" => match Config::initialize() {
            Ok(_) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("{error}");
                ExitCode::FAILURE
            }
        },
        "config-shortcut" => {
            let result = args
                .next()
                .ok_or("Expected shortcut JSON".to_string())
                .and_then(|value| serde_json::from_str(&value).map_err(|e| e.to_string()))
                .and_then(|value| Config::save_setting("shortcut", value));
            match result {
                Ok(_) => ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("{error}");
                    ExitCode::FAILURE
                }
            }
        }
        "model-setup" => {
            let configured = match args.next().as_deref() {
                Some("pending") => false,
                Some("ready") => true,
                _ => {
                    eprintln!(
                        "Usage: omaflow model-setup pending|ready (offline installer command)"
                    );
                    return ExitCode::FAILURE;
                }
            };
            match Config::save_setting("models_configured", serde_json::json!(configured)) {
                Ok(_) => ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("{error}");
                    ExitCode::FAILURE
                }
            }
        }
        "model-catalog" => model_catalog(),
        "model-select" => model_select(args.next(), args.next()),
        "model-install" => model_install(args.next(), args.next()),
        "model-cancel" => model_cancel(args.next(), args.next()),
        "serve-asr" => match backend::serve_speech() {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("{error}");
                if error.starts_with("Speech model is not configured") {
                    ExitCode::from(78)
                } else {
                    ExitCode::FAILURE
                }
            }
        },
        "launch" => launch_omaflow(),
        "quit" => quit_omaflow(),
        // The hotkeys start the daemon when it is down; see send_press.
        "press" | "journal-press" | "todo-press" => send_press(&command, &press_key(&command)),
        "release" => send_command("release"),
        "stop" | "toggle" => send_command("stop"),
        "cancel" => send_command("cancel"),
        "close" => send_command("close"),
        "dismiss" => send_command("dismiss"),
        "retry" => send_command("retry"),
        "discard" => send_command("discard"),
        "restart-speech" => restart_speech(),
        "journal" => crate::journal_cli::run(args),
        // The journal shortcut, down and up: hold to talk, double-tap to lock.
        "journal-release" => send_command("journal-release"),
        "journal-toggle" => match args.next() {
            // With a later day: a spoken note to yourself for that day. With a
            // past day: an entry added to that day.
            Some(day) => send_command(&format!("journal-toggle:{day}")),
            None => send_command("journal-toggle"),
        },
        "history-play" => {
            let id = args.next().and_then(|id| id.parse::<u64>().ok());
            let offset_ms = args
                .next()
                .and_then(|offset| offset.parse::<u64>().ok())
                .unwrap_or(0);
            match id {
                Some(id) => send_command(&format!(
                    "history-play:{}",
                    serde_json::json!({"id": id, "offset_ms": offset_ms})
                )),
                None => {
                    eprintln!("Usage: omaflow history-play ID [OFFSET_MS]");
                    ExitCode::FAILURE
                }
            }
        }
        "journal-discard" => send_command("journal-discard"),
        "todos" => crate::todos_cli::run(args),
        // The to-do shortcut, down and up, and the Talk button's toggle.
        "todo-release" => send_command("todo-release"),
        // With JSON such as {"list":"Infra","due":"2026-10-02"}: where the
        // To-dos tab's Talk button sends the capture.
        "todo-toggle" => match args.next() {
            Some(target) => send_command(&format!("todo-toggle:{target}")),
            None => send_command("todo-toggle"),
        },
        // Where to-dos go from now on; "" is the Inbox.
        "todo-list" => send_command(&format!("todo-list:{}", args.next().unwrap_or_default())),
        // Moves the capture the card announces to another list.
        "todo-move" => send_command(&format!("todo-move:{}", args.next().unwrap_or_default())),
        "card-hold" => send_command("card-hold"),
        "card-edit" => send_command("card-edit"),
        "card-resume" => send_command("card-resume"),
        "todo-card-edit" | "todo-card-remove" => {
            let index = args.next().and_then(|index| index.parse::<usize>().ok());
            match (index, args.next()) {
                (Some(index), Some(text)) => send_command(&format!(
                    "{command}:{}",
                    serde_json::json!({"index": index, "text": text, "new_text": args.next().unwrap_or_default()})
                )),
                _ => {
                    eprintln!(
                        "Usage: omaflow {command} INDEX TEXT{}",
                        if command == "todo-card-edit" {
                            " NEW_TEXT"
                        } else {
                            ""
                        }
                    );
                    ExitCode::FAILURE
                }
            }
        }
        "todo-discard" => send_command("todo-discard"),
        "todo-undo" => send_command("todo-undo"),
        "journal-stop-playback" => send_command("journal-stop-playback"),
        "journal-play" => {
            let date = args.next().unwrap_or_default();
            let id = args.next().and_then(|id| id.parse::<u64>().ok());
            let offset_ms = args
                .next()
                .and_then(|offset| offset.parse::<u64>().ok())
                .unwrap_or(0);
            match id {
                Some(id) => send_command(&format!(
                    "journal-play:{}",
                    serde_json::json!({"date": date, "id": id, "offset_ms": offset_ms})
                )),
                None => {
                    eprintln!("Usage: omaflow journal-play DATE ID [OFFSET_MS]");
                    ExitCode::FAILURE
                }
            }
        }
        "copy" => send_command("copy"),
        "paste-last" => send_command("paste-last"),
        "history-paste" => history_command("history-paste", args.next()),
        "history-copy" => history_command("history-copy", args.next()),
        "history-delete" => history_command("history-delete", args.next()),
        "history-retry" => history_command("history-retry", args.next()),
        "history-undo" => send_command("history-undo"),
        "history-clear" => send_command("history-clear"),
        "erase-data" => send_command("erase-data"),
        "reload-config" => {
            let result = update::repo_root()
                .ok_or("Cannot find the OmaFlow folder".to_string())
                .and_then(|root| {
                    let mut sync = Command::new("python3");
                    // The shortcuts are written by this very binary.
                    if let Ok(binary) = env::current_exe() {
                        sync.env("OMAFLOW_BINARY", binary);
                    }
                    sync.arg(root.join("tools/set_hotkey.py"))
                        .arg("--sync")
                        .bounded_output()
                        .map_err(|e| e.to_string())
                });
            match result {
                Ok(output) if output.status.success() => match crate::deliver("reload-config") {
                    // A stopped OmaFlow reads the file when it starts, so a
                    // valid file is not an error then.
                    Err(None) => ExitCode::SUCCESS,
                    Ok(()) => ExitCode::SUCCESS,
                    Err(Some(error)) => {
                        eprintln!("omaflow: could not send command: {error}");
                        ExitCode::FAILURE
                    }
                },
                // The shell shows this line in its notification, so it is
                // the script's reason, not the exit status.
                Ok(output) => {
                    eprintln!("{}", sync_failure(&output.stdout));
                    ExitCode::FAILURE
                }
                Err(error) => {
                    eprintln!("{error}");
                    ExitCode::FAILURE
                }
            }
        }
        "history-raw" => history_command("history-raw", args.next()),
        "history-edit" => {
            let id = args.next().and_then(|id| id.parse::<u64>().ok());
            match (id, args.next()) {
                (Some(id), Some(text)) => send_command(&format!(
                    "history-edit:{}",
                    serde_json::json!({"id":id,"text":text})
                )),
                _ => ExitCode::FAILURE,
            }
        }
        "configure" => {
            // `-` reads the value from stdin, so API keys never appear in the
            // process arguments, which other local users can read in /proc.
            let key = args.next();
            let value = args.next().and_then(|value| {
                let value = if value == "-" {
                    // One line, so a caller that keeps stdin open still works.
                    let mut input = String::new();
                    std::io::BufRead::read_line(
                        &mut std::io::BufReader::new(std::io::stdin().take(64 * 1024)),
                        &mut input,
                    )
                    .ok()?;
                    input
                } else {
                    value
                };
                serde_json::from_str::<serde_json::Value>(value.trim()).ok()
            });
            match (key, value) {
                (Some(key), Some(value)) => send_command(&format!(
                    "configure:{}",
                    serde_json::json!({"key":key,"value":value})
                )),
                _ => ExitCode::FAILURE,
            }
        }
        "meter-preview-start" => send_command("meter-preview-start"),
        "meter-preview-stop" => send_command("meter-preview-stop"),
        "meter-gate" => meter_gate_command("meter-gate", args.next()),
        "meter-gate-preview" => meter_gate_command("meter-gate-preview", args.next()),
        "paste-mode" => paste_mode_command(args.next()),
        "vocabulary-add" => vocabulary_command("vocabulary-add", args.next()),
        "vocabulary-remove" => vocabulary_command("vocabulary-remove", args.next()),
        // `--version` is the flag people try first.
        "version" | "--version" | "-V" => {
            if args.next().as_deref() == Some("--json") {
                println!("{}", update::version_json());
            } else {
                println!("{}", update::RUNNING_VERSION);
            }
            ExitCode::SUCCESS
        }
        "health" => {
            let result = match (args.next().as_deref(), args.next()) {
                (Some("--expect-commit"), Some(commit)) => update::health(&commit),
                _ => Err("Usage: omaflow health --expect-commit FULL_SHA".into()),
            };
            command_result(result)
        }
        "update" => {
            let result = match args.next().as_deref() {
                // The daily timer runs this too; its log then says how it went.
                Some("check") => {
                    return match update::check() {
                        Ok(offer) => match offer.error {
                            Some(error) => {
                                eprintln!(
                                    "Could not check for updates: {}",
                                    update::sentence(&error)
                                );
                                ExitCode::FAILURE
                            }
                            None => {
                                println!("{}", check_outcome(&offer));
                                ExitCode::SUCCESS
                            }
                        },
                        Err(error) => {
                            eprintln!("Could not check for updates: {}", update::sentence(&error));
                            ExitCode::FAILURE
                        }
                    };
                }
                // The window shows what these print, so each is a sentence
                // for a person, not a log line.
                Some("request") => {
                    return match update::request() {
                        Ok(doing) => {
                            println!("{doing}");
                            ExitCode::SUCCESS
                        }
                        Err(error) => {
                            eprintln!("{}", update::refusal(&error));
                            ExitCode::FAILURE
                        }
                    };
                }
                Some("later") => {
                    return match update::later() {
                        Ok(version) => {
                            println!(
                                "OmaFlow {version} can wait. You are reminded again tomorrow."
                            );
                            ExitCode::SUCCESS
                        }
                        Err(error) if error == "no update is available" => {
                            eprintln!("There is no update to put off right now.");
                            ExitCode::FAILURE
                        }
                        Err(error) => {
                            eprintln!(
                                "The update could not be put off: {}.",
                                error.trim_end_matches('.')
                            );
                            ExitCode::FAILURE
                        }
                    };
                }
                Some("status") => update::transaction_json().map(|value| println!("{value}")),
                Some("run") => update::run(),
                Some("reconcile") => update::reconcile(),
                _ => Err("Usage: omaflow update check|request|later|status|run|reconcile".into()),
            };
            command_result(result)
        }
        "check-update" => match update::check_remote() {
            Ok(status) => {
                if !status.error.is_empty() {
                    eprintln!("omaflow: update check failed: {}", status.error);
                }
                // Best effort: a running daemon republishes with the new
                // numbers, a stopped one picks them up on its next start.
                let _ = send_command("refresh-update");
                if status.error.is_empty() {
                    ExitCode::SUCCESS
                } else {
                    ExitCode::FAILURE
                }
            }
            Err(error) => {
                eprintln!("omaflow: {error}");
                ExitCode::FAILURE
            }
        },
        "effective-config" => match Config::load() {
            Ok(config) => {
                println!("{}", serde_json::to_string(&config).unwrap());
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("{error}");
                ExitCode::FAILURE
            }
        },
        "evaluate" => {
            let mut input = String::new();
            let result = std::io::stdin()
                .read_to_string(&mut input)
                .map_err(|e| e.to_string())
                .and_then(|_| {
                    serde_json::from_str::<serde_json::Value>(&input).map_err(|e| e.to_string())
                })
                .and_then(|value| {
                    let mut config = Config::load()?;
                    if let Some(prompt) = value.get("prompt").and_then(serde_json::Value::as_str) {
                        config.cleanup.system_prompt = prompt.into();
                    }
                    if let Some(model) = value.get("model").and_then(serde_json::Value::as_str) {
                        config.cleanup.model = model.into();
                    }
                    if let Some(vocabulary) = value.get("vocabulary") {
                        config.cleanup.custom_vocabulary =
                            serde_json::from_value(vocabulary.clone())
                                .map_err(|e| e.to_string())?;
                    }
                    let text = value
                        .get("transcript")
                        .and_then(serde_json::Value::as_str)
                        .ok_or("Missing transcript")?;
                    let clip = value
                        .get("clipboard")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    Ok(backend::evaluate_text(
                        &config,
                        text,
                        clip,
                        value.get("window"),
                    ))
                });
            match result {
                Ok(value) => {
                    println!("{value}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("{error}");
                    ExitCode::FAILURE
                }
            }
        }
        "transcribe-file" => {
            let result = args
                .next()
                .ok_or_else(|| "usage: omaflow transcribe-file FILE.wav".to_string())
                .and_then(|path| {
                    Config::load().and_then(|config| {
                        backend::transcribe_file(&config, std::path::Path::new(&path))
                    })
                });
            match result {
                Ok(text) => {
                    println!("{text}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("omaflow: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        "test-cleanup" => {
            // With `-`, the fields as typed in Settings, before they are
            // saved: {"cleanup_engine","cleanup_model","cleanup_endpoint",
            // "cleanup_api_key"?}. Without a key, the saved one is used.
            let typed = if args.next().as_deref() == Some("-") {
                let mut input = String::new();
                match std::io::stdin()
                    .take(64 * 1024)
                    .read_to_string(&mut input)
                    .ok()
                    .and_then(|_| serde_json::from_str::<serde_json::Value>(&input).ok())
                {
                    Some(value) => Some(value),
                    None => {
                        println!(
                            "{}",
                            serde_json::json!({"ok":false,"kind":"configuration","message":"The test did not receive the cleanup fields."})
                        );
                        return ExitCode::FAILURE;
                    }
                }
            } else {
                None
            };
            let report = match Config::load() {
                Ok(mut config) => {
                    if let Some(typed) = typed {
                        let field =
                            |name: &str| typed.get(name).and_then(serde_json::Value::as_str);
                        if let Some(engine) = field("cleanup_engine") {
                            config.cleanup.engine = engine.trim().into();
                        }
                        if let Some(model) = field("cleanup_model") {
                            config.cleanup.model = model.trim().into();
                        }
                        if let Some(endpoint) = field("cleanup_endpoint") {
                            config.cleanup.endpoint = endpoint.trim().into();
                        }
                        if let Some(key) = field("cleanup_api_key").filter(|key| !key.is_empty()) {
                            config.cleanup.api_key = key.trim().into();
                        }
                    }
                    crate::cleanup::test_connection(&config)
                }
                Err(_) => {
                    serde_json::json!({"ok":false,"kind":"configuration","message":"Could not load saved configuration. Fix the configuration before testing."})
                }
            };
            println!("{report}");
            if report["ok"] == true {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        // The to-do pipeline on one transcript, as a take would run it, with
        // dates read on a fixed day: {"transcript", "todo_prompt"?, "model"?,
        // "today"?, "now"?}. Prints the tasks; nothing is added.
        "evaluate-todos" => {
            let mut input = String::new();
            let result = std::io::stdin()
                .read_to_string(&mut input)
                .map_err(|e| e.to_string())
                .and_then(|_| serde_json::from_str::<serde_json::Value>(&input).map_err(|e| e.to_string()))
                .and_then(|value| {
                    let mut config = Config::load()?;
                    config.cleanup.enabled = value.get("cleanup").and_then(serde_json::Value::as_bool).unwrap_or(true);
                    if let Some(prompt) = value.get("todo_prompt").and_then(serde_json::Value::as_str) {
                        config.todos.prompt = prompt.into();
                    }
                    if let Some(model) = value.get("model").and_then(serde_json::Value::as_str) {
                        config.cleanup.model = model.into();
                    }
                    let transcript = value.get("transcript").and_then(serde_json::Value::as_str).ok_or("Missing transcript")?;
                    let (local_today, local_now) = omaflow_platform::clock::local_now();
                    let today = match value.get("today").and_then(serde_json::Value::as_str) {
                        Some(day) => day.parse().map_err(|_| format!("Not a date: {day}"))?,
                        None => local_today,
                    };
                    let now = value.get("now").and_then(serde_json::Value::as_str).map_or(local_now, str::to_string);
                    let (items, warning) = backend::evaluate_todos(&config, transcript)?;
                    let items: Vec<serde_json::Value> = items
                        .iter()
                        .map(|item| {
                            let said = omaflow_core::todos::due(item, today, &now);
                            let remind = match said.remind {
                                omaflow_core::todos::Remind::Default => serde_json::Value::Null,
                                omaflow_core::todos::Remind::Off => "off".into(),
                                omaflow_core::todos::Remind::Before(minutes) => minutes.into(),
                                omaflow_core::todos::Remind::At(at) => at.into(),
                            };
                            serde_json::json!({"text": said.text, "due": said.date.map(|due| due.to_string()), "time": said.time, "remind": remind, "line": item})
                        })
                        .collect();
                    Ok(serde_json::json!({"items": items, "warning": warning}))
                });
            match result {
                Ok(value) => {
                    println!("{value}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("omaflow: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        "cleanup" => {
            let mut input = String::new();
            let result = std::io::stdin()
                .read_to_string(&mut input)
                .map_err(|error| format!("could not read stdin: {error}"))
                .and_then(|_| Config::load())
                .and_then(|config| backend::cleanup_text(&config, &input));
            match result {
                Ok(text) => {
                    print!("{text}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("omaflow: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        "--help" | "-h" | "help" => {
            print_help();
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("omaflow: unknown command: {other}");
            print_help();
            ExitCode::FAILURE
        }
    }
}

fn print_help() {
    println!(
        "OmaFlow: local voice dictation for Omarchy

Usage: omaflow COMMAND

Commands you might run yourself:
  launch                        Start OmaFlow and open its window
  quit                          Stop OmaFlow and unload its models
  version [--json]              Show the installed version
  update check|request|later    Check for an update, install it, or put it off a day
  journal add TEXT [DATE]       Add a typed entry to the journal
  todos add TEXT [LIST [DUE]]   Add to-dos, one per line
  effective-config              Print the settings in use, or why config.toml is invalid
  restart-speech                Start the speech model again after it stopped

The keys, the bar icon and the window run the rest:
  Recording: press, release, stop, cancel, retry, discard, close, dismiss, card-hold, card-edit, card-resume
  Journal: journal-toggle [DATE], journal-press, journal-release, journal-discard, journal-play DATE ID [MS],
           journal-stop-playback, journal day|month|stats|search|year-ago|due|edit|delete|restore|
           forget-deleted|move-folder|export
  To-dos: todo-press, todo-release, todo-toggle [JSON], todo-discard, todo-undo, todo-list LIST, todo-move LIST,
          todo-card-edit, todo-card-remove, todos list|done|undone|edit|due|remind|snooze|reminders|move|
          delete|clear-done|new-list|rename-list|delete-list|restore|forget-deleted|move-folder
  Delivery: copy, paste-last, paste-mode auto|ctrl-v|shift-insert|clipboard|custom
  History: history-copy, history-raw, history-paste, history-play, history-retry, history-edit,
           history-delete, history-undo, history-clear, erase-data
  Settings: configure KEY JSON|-, vocabulary-add, vocabulary-remove, reload-config, meter-gate DB
  Models: model-catalog, model-select, model-install, model-cancel
  Evaluation: cleanup, evaluate, evaluate-todos, transcribe-file, test-cleanup
  Updates: check-update, update status|run|reconcile

Every command, with what it does: {}",
        update::repo_root().map_or_else(
            || "docs/commands.md in the OmaFlow folder.".to_string(),
            |root| root.join("docs/commands.md").display().to_string()
        )
    );
}

/// What a check found, and the next step when there is one.
fn check_outcome(offer: &update::UpdateOffer) -> String {
    if let Some(warning) = &offer.external_checkout_warning {
        format!("The OmaFlow folder changed outside OmaFlow. {warning}")
    } else if let Some(target) = &offer.target {
        format!(
            "OmaFlow {} is ready to install. Run omaflow update request, or choose Update and restart in Settings, Advanced, Updates and app.",
            target.version
        )
    } else {
        format!(
            "OmaFlow is up to date. You have {}.",
            update::RUNNING_VERSION
        )
    }
}

fn command_result(result: Result<(), String>) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("omaflow: {error}");
            ExitCode::FAILURE
        }
    }
}

fn resolve_entry(
    kind: Option<String>,
    id: Option<String>,
) -> Result<(Kind, &'static CatalogEntry), String> {
    let kind = kind
        .as_deref()
        .and_then(Kind::parse)
        .ok_or("Name a catalog to choose from: speech or cleanup.")?;
    let id = id.ok_or_else(|| {
        format!(
            "Name a {} model from the catalog; `omaflow model-catalog` lists them.",
            kind.as_str()
        )
    })?;
    catalog::find(kind, &id)
        .map(|entry| (kind, entry))
        .ok_or_else(|| catalog::unknown_id(kind, &id))
}

fn model_catalog() -> ExitCode {
    let result = Config::load().and_then(|config| {
        let installed_cleanup = if config.cleanup.engine == "ollama" {
            catalog::installed_cleanup_ids(&config.cleanup.endpoint)
        } else {
            Vec::new()
        };
        serde_json::to_string(&catalog::to_json(
            &config,
            &catalog::installed_speech_ids(),
            &installed_cleanup,
        ))
        .map_err(|error| error.to_string())
    });
    match result {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("omaflow: {error}");
            ExitCode::FAILURE
        }
    }
}

fn model_select(kind: Option<String>, id: Option<String>) -> ExitCode {
    match resolve_entry(kind, id).and_then(|(kind, entry)| catalog::select(kind, entry)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("omaflow: {error}");
            ExitCode::FAILURE
        }
    }
}

/// Also runs headless from a systemd unit on a fresh install, so it never
/// needs a daemon, a terminal, or an answer from either.
fn model_install(kind: Option<String>, id: Option<String>) -> ExitCode {
    let (kind, entry) = match resolve_entry(kind, id) {
        Ok(resolved) => resolved,
        Err(error) => {
            eprintln!("omaflow: {error}");
            return ExitCode::FAILURE;
        }
    };
    // Its own process group, so model-cancel can stop the downloader and
    // the runtime installer with it.
    // SAFETY: setpgid on this process changes no memory.
    unsafe {
        libc::setpgid(0, 0);
    }
    let marker = download_marker(kind, entry);
    let fresh = kind == Kind::Speech && !catalog::speech_installed(entry.id);
    let _ = fs::write(&marker, format!("{}\n{fresh}\n", std::process::id()));
    let mut reporter = DownloadReporter::new(entry.id);
    reporter.publish("downloading", None, &format!("Downloading {}", entry.label));
    let downloaded = catalog::download(kind, entry, |percent, line| {
        reporter.progress(percent, line);
    });
    let _ = fs::remove_file(&marker);
    if downloaded.is_ok() {
        catalog::record_receipt(kind, entry);
    }
    // A download takes minutes and the window may be closed by the end, so
    // its outcome also arrives as a notification.
    match downloaded.and_then(|()| catalog::select(kind, entry)) {
        Ok(()) => {
            reporter.publish("done", Some(100), &format!("{} is ready", entry.label));
            notify(
                &format!("{} is ready", entry.label),
                &ready_next_step(kind, Config::load().ok().as_ref()),
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            reporter.publish("failed", None, &error);
            eprintln!("omaflow: {error}");
            // A click lands where the body says to go.
            let page = if error.starts_with("Ollama is not installed") {
                "cleanup"
            } else {
                "models"
            };
            notify_opening(
                &format!("{} did not download", entry.label),
                &download_failed_body(&error),
                page,
            );
            ExitCode::FAILURE
        }
    }
}

/// A notification that opens OmaFlow on a Settings page when clicked, as
/// the update notices do; a plain one where Omarchy's sender is missing.
/// `page` names the shell's handler: "models" or "cleanup".
fn notify_opening(title: &str, body: &str, page: &str) {
    let sent = Command::new("/usr/share/omarchy/bin/omarchy-notification-send")
        .args(["--app-name", "OmaFlow", title, body, "--exec"])
        .args([
            "/usr/share/omarchy/bin/omarchy-shell",
            "-q",
            "entroit.omaflow",
            page,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .bounded_status()
        .is_ok_and(|status| status.success());
    if !sent {
        notify(title, body);
    }
}

/// What to do with a model that just arrived. Choosing a cleanup model does
/// not turn cleanup on, so it is only in use once Cleanup is Medium.
fn ready_next_step(kind: Kind, config: Option<&Config>) -> String {
    match kind {
        Kind::Speech => format!(
            "Hold {} in any app to dictate.",
            crate::key_name(&read_hotkey_display())
        ),
        Kind::Cleanup if config.is_some_and(|config| config.cleanup.level() == "medium") => {
            "Cleanup uses it from your next dictation.".into()
        }
        Kind::Cleanup => "To use it, set Cleanup to Medium in Settings, Basics.".into(),
    }
}

/// Trying again only helps once nothing is missing: without Ollama, the
/// Cleanup page shows the command that installs it.
fn download_failed_body(error: &str) -> String {
    let error = error.trim_end_matches('.');
    if error.starts_with("Ollama is not installed") {
        format!("{error}. Settings, Advanced, Cleanup in OmaFlow shows how to install it.")
    } else {
        format!("{error}. To try again, open Settings, Advanced, Models in OmaFlow.")
    }
}

/// Where a running download leaves its process id, and whether its files
/// are new, for model-cancel.
fn download_marker(kind: Kind, entry: &CatalogEntry) -> std::path::PathBuf {
    let name: String = entry
        .id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    omaflow_platform::runtime_dir().join(format!("omaflow-download-{}-{name}", kind.as_str()))
}

/// Stops a catalog download that is running, and removes what it wrote of
/// a speech model that was not here before. Ollama keeps its own partial
/// layers, and the next pull of the model reuses them.
fn model_cancel(kind: Option<String>, id: Option<String>) -> ExitCode {
    let (kind, entry) = match resolve_entry(kind, id) {
        Ok(resolved) => resolved,
        Err(error) => {
            eprintln!("omaflow: {error}");
            return ExitCode::FAILURE;
        }
    };
    let marker = download_marker(kind, entry);
    let Ok(text) = fs::read_to_string(&marker) else {
        eprintln!("{} is not downloading.", entry.label);
        return ExitCode::FAILURE;
    };
    let mut lines = text.lines();
    let pid = lines.next().and_then(|pid| pid.trim().parse::<i32>().ok());
    let fresh = lines.next() == Some("true");
    if let Some(pid) = pid.filter(|pid| *pid > 1) {
        // SAFETY: signals the download's own process group only.
        unsafe {
            libc::kill(-pid, libc::SIGTERM);
        }
    }
    let _ = fs::remove_file(&marker);
    if fresh {
        catalog::remove_partial_speech(entry.id);
    }
    send_command_quiet(&format!(
        "model-progress:{}",
        serde_json::json!({"id": entry.id, "state": "cancelled", "percent": 0, "message": ""})
    ));
    ExitCode::SUCCESS
}

/// The Restart button for a speech model that stopped: clears a failed
/// state, which would otherwise refuse the start, and starts it again.
fn restart_speech() -> ExitCode {
    let _ = Command::new("systemctl")
        .args(["--user", "reset-failed", "omaflow-asr.service"])
        .bounded_status();
    match Command::new("systemctl")
        .args(["--user", "restart", "omaflow-asr.service"])
        .bounded_status()
    {
        Ok(status) if status.success() => ExitCode::SUCCESS,
        _ => {
            eprintln!(
                "The speech model could not be restarted. See: journalctl --user -u omaflow-asr.service"
            );
            ExitCode::FAILURE
        }
    }
}

/// Forwards download progress to a running daemon so the panel can show it.
/// Downloaders print a new percentage many times a second; the socket sees at
/// most one message per step of the bar.
struct DownloadReporter {
    id: &'static str,
    percent: Option<u8>,
    sent_at: Option<Instant>,
}

impl DownloadReporter {
    fn new(id: &'static str) -> Self {
        Self {
            id,
            percent: None,
            sent_at: None,
        }
    }

    /// A line we cannot read a number out of keeps the last percentage rather
    /// than resetting the bar to zero; zero is what an unparsed download shows.
    fn progress(&mut self, percent: Option<u8>, message: &str) {
        let percent = percent.or(self.percent);
        let stale = self
            .sent_at
            .is_none_or(|sent| sent.elapsed() >= Duration::from_millis(500));
        if percent != self.percent || stale {
            self.percent = percent;
            self.publish("downloading", percent, message);
        }
    }

    fn publish(&mut self, state: &str, percent: Option<u8>, message: &str) {
        self.sent_at = Some(Instant::now());
        send_command_quiet(&format!(
            "model-progress:{}",
            serde_json::json!({
                "id": self.id,
                "state": state,
                "percent": percent.unwrap_or(0),
                "message": message,
            })
        ));
    }
}

fn launch_omaflow() -> ExitCode {
    let started = Command::new("systemctl")
        .args(["--user", "start", "omaflow.service"])
        .status();
    match started {
        Ok(status) if status.success() => {
            match Command::new("omarchy-shell")
                .args(["-q", "entroit.omaflow", "open"])
                .bounded_status()
            {
                Ok(status) if status.success() => ExitCode::SUCCESS,
                _ => {
                    eprintln!(
                        "OmaFlow started, but its window could not open. Turn on the bar widget with: omarchy plugin enable entroit.omaflow right"
                    );
                    ExitCode::FAILURE
                }
            }
        }
        // The window shows this line as it is.
        Ok(_) | Err(_) => {
            eprintln!("OmaFlow could not start. {}", crate::START_FAILED_HELP);
            ExitCode::FAILURE
        }
    }
}

fn quit_omaflow() -> ExitCode {
    unload_cleanup_model();
    let stopped = Command::new("systemctl")
        .args(["--user", "stop", "omaflow.service", "omaflow-asr.service"])
        .status();
    match stopped {
        Ok(status) if status.success() => {
            let _ = fs::remove_file(surface_state_path());
            ExitCode::SUCCESS
        }
        Ok(_) | Err(_) => {
            eprintln!(
                "omaflow: could not stop OmaFlow. See why with: journalctl --user -u omaflow"
            );
            ExitCode::FAILURE
        }
    }
}

fn unload_cleanup_model() {
    if let Ok(config) = Config::load() {
        backend::unload_cleanup(&config);
    }
}

/// Why set_hotkey.py refused config.toml, on one line for a notification:
/// a TOML error comes with a drawing of the line and a caret under it.
fn sync_failure(stdout: &[u8]) -> String {
    let message = serde_json::from_slice::<serde_json::Value>(stdout)
        .ok()
        .and_then(|value| value.get("message")?.as_str().map(str::to_owned))
        .unwrap_or_default();
    message
        .lines()
        .map(str::trim)
        .filter(|line| {
            !line.is_empty()
                && !line.starts_with('|')
                && !line
                    .split_once(" |")
                    .is_some_and(|(number, _)| number.chars().all(|c| c.is_ascii_digit()))
        })
        .collect::<Vec<_>>()
        .join(": ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_config_error_reaches_the_notification_on_one_line() {
        let message = "/home/me/.config/omaflow/config.toml is not valid. Fix it and save the file: TOML parse error at line 3, column 13\n  |\n3 | model = \"bar\n  |             ^\ninvalid basic string, expected `\"`\n";
        let stdout = serde_json::json!({"ok": false, "message": message}).to_string();
        assert_eq!(
            sync_failure(stdout.as_bytes()),
            "/home/me/.config/omaflow/config.toml is not valid. Fix it and save the file: TOML parse error at line 3, column 13: invalid basic string, expected `\"`"
        );
        assert_eq!(
            sync_failure(br#"{"ok": false, "message": "F9 already controls Screenshot. Choose a different key."}"#),
            "F9 already controls Screenshot. Choose a different key."
        );
        assert_eq!(sync_failure(b"not json"), "");
    }

    #[test]
    fn a_ready_cleanup_model_says_whether_cleanup_uses_it() {
        let mut config = Config::default();
        config.cleanup.enabled = false;
        assert_eq!(
            ready_next_step(Kind::Cleanup, Some(&config)),
            "To use it, set Cleanup to Medium in Settings, Basics."
        );
        config.cleanup.enabled = true;
        assert_eq!(
            ready_next_step(Kind::Cleanup, Some(&config)),
            "Cleanup uses it from your next dictation."
        );
    }

    #[test]
    fn a_failed_download_names_the_step_that_helps() {
        assert_eq!(
            download_failed_body(
                "Ollama is not installed, so cleanup models cannot be downloaded."
            ),
            "Ollama is not installed, so cleanup models cannot be downloaded. Settings, Advanced, Cleanup in OmaFlow shows how to install it."
        );
        assert_eq!(
            download_failed_body("The connection dropped."),
            "The connection dropped. To try again, open Settings, Advanced, Models in OmaFlow."
        );
    }
}
