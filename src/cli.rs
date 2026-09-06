//! Command-line entry points. Interactive requests use the daemon IPC channel.
use crate::process::CommandExt;
use crate::surface_state_path;
use crate::{
    backend, config::Config, history_command, meter_gate_command, paste_mode_command, run_daemon,
    send_command, update, vocabulary_command,
};
use std::{
    env, fs,
    io::Read,
    process::{Command, ExitCode},
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
        "press" => send_command("press"),
        "release" => send_command("release"),
        "stop" | "toggle" => send_command("stop"),
        "cancel" => send_command("cancel"),
        "close" => send_command("close"),
        "copy" => send_command("copy"),
        "paste-last" => send_command("paste-last"),
        "history-paste" => history_command("history-paste", args.next()),
        "history-copy" => history_command("history-copy", args.next()),
        "history-delete" => history_command("history-delete", args.next()),
        "history-undo" => send_command("history-undo"),
        "history-clear" => send_command("history-clear"),
        "erase-data" => send_command("erase-data"),
        "reload-config" => {
            let result = update::repo_root()
                .ok_or("Cannot locate the OmaFlow checkout".to_string())
                .and_then(|root| {
                    Command::new("python3")
                        .arg(root.join("tools/set_hotkey.py"))
                        .arg("--sync")
                        .bounded_status()
                        .map_err(|e| e.to_string())
                });
            match result {
                Ok(status) if status.success() => send_command("reload-config"),
                Ok(_) => ExitCode::FAILURE,
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
            match (
                args.next(),
                args.next()
                    .and_then(|value| serde_json::from_str::<serde_json::Value>(&value).ok()),
            ) {
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
        "version" => {
            println!("{}", update::RUNNING_VERSION);
            ExitCode::SUCCESS
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
        "apply-update" | "rebuild" => {
            let pull = command == "apply-update";
            match update::run_installer(pull) {
                Ok(()) => ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("omaflow: {error}");
                    ExitCode::FAILURE
                }
            }
        }
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
        "segment-file" => {
            let result = args
                .next()
                .ok_or_else(|| "usage: omaflow segment-file FILE.wav".to_string())
                .and_then(|path| {
                    Config::load().and_then(|config| {
                        backend::segment_file(&config, std::path::Path::new(&path))
                    })
                });
            match result {
                Ok(report) => {
                    println!("{report}");
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
        "OmaFlow local dictation

Usage: omaflow COMMAND

Recording: press, release, stop, cancel, close
Delivery: copy, paste-last, paste-mode auto|ctrl-v|shift-insert|clipboard
History: history-copy ID, history-raw ID, history-paste ID, history-edit ID TEXT,
         history-delete ID, history-undo, history-clear, erase-data
Settings: vocabulary-add TERM, vocabulary-remove TERM, configure KEY JSON
Models: configure models JSON
Microphone: meter-gate DB, meter-preview-start, meter-preview-stop
Evaluation: cleanup < text, evaluate < JSON, segment-file FILE.wav
Maintenance: daemon, launch, quit, reload-config, effective-config,
             version, check-update, apply-update, rebuild"
    );
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
                        "OmaFlow started, but its panel could not open. Check that the bar widget is enabled."
                    );
                    ExitCode::FAILURE
                }
            }
        }
        Ok(status) => {
            eprintln!("omaflow: could not start OmaFlow: systemctl exited with {status}");
            ExitCode::FAILURE
        }
        Err(error) => {
            eprintln!("omaflow: could not start OmaFlow: {error}");
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
        Ok(status) => {
            eprintln!("omaflow: could not stop OmaFlow: systemctl exited with {status}");
            ExitCode::FAILURE
        }
        Err(error) => {
            eprintln!("omaflow: could not stop OmaFlow: {error}");
            ExitCode::FAILURE
        }
    }
}

fn unload_cleanup_model() {
    if let Ok(config) = Config::load() {
        backend::unload_cleanup(&config);
    }
}
