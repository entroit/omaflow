//! Bounded, cancellable subprocess I/O. Drain pipes while the child runs.
use std::{
    fs,
    io::{self, Read, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Output, Stdio},
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    thread,
    time::{Duration, Instant},
};

pub trait CommandExt {
    fn bounded_output(&mut self) -> io::Result<Output>;
    fn bounded_status(&mut self) -> io::Result<ExitStatus>;
}

impl CommandExt for Command {
    fn bounded_output(&mut self) -> io::Result<Output> {
        let child = self
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        wait(child, &AtomicBool::new(false), Duration::from_secs(5)).map_err(io::Error::other)
    }
    fn bounded_status(&mut self) -> io::Result<ExitStatus> {
        self.bounded_output().map(|output| output.status)
    }
}

/// A bearer token for one curl invocation, handed over in an owner-only config
/// file rather than argv: `/proc/<pid>/cmdline` is readable by every process on
/// the machine, and a self-hosted server's key is a credential like any other.
/// The file lives exactly as long as this value.
pub struct CurlAuth {
    path: Option<PathBuf>,
    header: Option<String>,
}

impl CurlAuth {
    pub fn new(api_key: &str) -> Self {
        if api_key.is_empty() {
            return Self {
                path: None,
                header: None,
            };
        }
        let header = format!("Authorization: Bearer {api_key}");
        let path = crate::runtime_dir().join(format!(
            "omaflow-curl-{}-{}.conf",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        // A key that cannot be written to disk still has to reach the server,
        // so the argv fallback is deliberate: a working request beats a hidden one.
        match write_owner_only(&path, &format!("header = \"{header}\"\n")) {
            Ok(()) => Self {
                path: Some(path),
                header: None,
            },
            Err(_) => Self {
                path: None,
                header: Some(header),
            },
        }
    }

    pub fn apply<'a>(&self, command: &'a mut Command) -> &'a mut Command {
        if let Some(path) = &self.path {
            command.arg("--config").arg(path);
        } else if let Some(header) = &self.header {
            command.arg("--header").arg(header);
        }
        command
    }
}

impl Drop for CurlAuth {
    fn drop(&mut self) {
        if let Some(path) = &self.path {
            let _ = fs::remove_file(path);
        }
    }
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn write_owner_only(path: &Path, contents: &str) -> io::Result<()> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(contents.as_bytes())
}

pub fn nonblocking(file: &impl AsRawFd) -> io::Result<()> {
    // SAFETY: fcntl borrows a live descriptor and does not take ownership.
    let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn drain(pipe: &mut Option<impl Read>, bytes: &mut Vec<u8>) -> io::Result<()> {
    let Some(pipe) = pipe else { return Ok(()) };
    let mut buffer = [0; 8192];
    loop {
        match pipe.read(&mut buffer) {
            Ok(0) => return Ok(()),
            Ok(count) => {
                if bytes.len() + count > 4 * 1024 * 1024 {
                    return Err(io::Error::other("subprocess response exceeds 4 MiB"));
                }
                bytes.extend_from_slice(&buffer[..count]);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
}

pub fn run(
    command: &mut Command,
    input: &[u8],
    cancel: &AtomicBool,
    timeout: Duration,
) -> Result<Output, String> {
    let child = command
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    communicate(child, Some(input), cancel, timeout)
}

pub fn wait(child: Child, cancel: &AtomicBool, timeout: Duration) -> Result<Output, String> {
    communicate(child, None, cancel, timeout)
}

fn communicate(
    mut child: Child,
    input: Option<&[u8]>,
    cancel: &AtomicBool,
    timeout: Duration,
) -> Result<Output, String> {
    let result = (|| {
        if let Some(pipe) = &child.stdin {
            nonblocking(pipe).map_err(|e| e.to_string())?;
        }
        let mut written = 0;
        if let Some(pipe) = &child.stdout {
            nonblocking(pipe).map_err(|e| e.to_string())?;
        }
        if let Some(pipe) = &child.stderr {
            nonblocking(pipe).map_err(|e| e.to_string())?;
        }
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let started = Instant::now();
        loop {
            if cancel.load(Ordering::Acquire) {
                return Err("dictation cancelled".into());
            }
            if started.elapsed() >= timeout {
                return Err("operation timed out".into());
            }
            drain(&mut child.stdout, &mut stdout).map_err(|e| e.to_string())?;
            drain(&mut child.stderr, &mut stderr).map_err(|e| e.to_string())?;
            if let Some(input) = input {
                if written < input.len()
                    && let Some(pipe) = &mut child.stdin
                {
                    match pipe.write(&input[written..]) {
                        Ok(count) => written += count,
                        Err(e)
                            if matches!(
                                e.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(e) => return Err(e.to_string()),
                    }
                }
                if written == input.len() {
                    child.stdin.take();
                }
            }
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                drain(&mut child.stdout, &mut stdout).map_err(|e| e.to_string())?;
                drain(&mut child.stderr, &mut stderr).map_err(|e| e.to_string())?;
                return Ok(Output {
                    status,
                    stdout,
                    stderr,
                });
            }
            thread::sleep(Duration::from_millis(8));
        }
    })();
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};
    #[test]
    fn drains_more_than_pipe_capacity() {
        let child = Command::new("head")
            .args(["-c", "1048576", "/dev/zero"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let output = wait(child, &AtomicBool::new(false), Duration::from_secs(3)).unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout.len(), 1_048_576);
    }
    #[test]
    fn input_and_output_larger_than_a_pipe_do_not_deadlock() {
        let data = vec![b'x'; 1_048_576];
        let mut command = Command::new("cat");
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
        let output = run(
            &mut command,
            &data,
            &AtomicBool::new(false),
            Duration::from_secs(4),
        )
        .unwrap();
        assert_eq!(output.stdout, data);
    }
    #[test]
    fn blocked_input_obeys_the_deadline() {
        let mut command = Command::new("sleep");
        command.arg("30");
        let started = Instant::now();
        assert!(
            run(
                &mut command,
                &vec![0; 1_048_576],
                &AtomicBool::new(false),
                Duration::from_millis(40)
            )
            .is_err()
        );
        assert!(started.elapsed() < Duration::from_secs(1));
    }
    #[test]
    fn terminates_a_stalled_process() {
        let child = Command::new("sleep").arg("30").spawn().unwrap();
        assert!(
            wait(child, &AtomicBool::new(false), Duration::from_millis(30))
                .unwrap_err()
                .contains("timed out")
        );
    }
}
