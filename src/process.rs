//! Bounded, cancellable subprocess I/O. Drain pipes while the child runs.
use std::{
    fs,
    io::{self, Read, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Output, Stdio},
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    thread,
    time::{Duration, Instant, SystemTime},
};

pub trait CommandExt {
    fn bounded_output(&mut self) -> io::Result<Output>;
    fn bounded_status(&mut self) -> io::Result<ExitStatus>;
    fn bounded_output_for(&mut self, timeout: Duration) -> io::Result<Output>;
    fn bounded_status_for(&mut self, timeout: Duration) -> io::Result<ExitStatus>;
}

impl CommandExt for Command {
    fn bounded_output(&mut self) -> io::Result<Output> {
        self.bounded_output_for(Duration::from_secs(5))
    }
    fn bounded_output_for(&mut self, timeout: Duration) -> io::Result<Output> {
        let child = self
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        wait(child, &AtomicBool::new(false), timeout).map_err(io::Error::other)
    }
    fn bounded_status(&mut self) -> io::Result<ExitStatus> {
        self.bounded_output().map(|output| output.status)
    }
    fn bounded_status_for(&mut self, timeout: Duration) -> io::Result<ExitStatus> {
        self.bounded_output_for(timeout).map(|output| output.status)
    }
}

/// A bearer token for one curl invocation, handed over in an owner-only config
/// file rather than argv: `/proc/<pid>/cmdline` is readable by every process on
/// the machine, and a self-hosted server's key is a credential like any other.
/// The file lives exactly as long as this value.
pub struct CurlAuth {
    path: Option<PathBuf>,
}

impl CurlAuth {
    pub fn new(api_key: &str) -> Result<Self, String> {
        if api_key.is_empty() {
            return Ok(Self { path: None });
        }
        let header = format!("Authorization: Bearer {api_key}");
        let path = crate::runtime_dir().join(format!(
            "omaflow-curl-{}-{}.conf",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        // Never fall back to exposing credentials in process arguments.
        let escaped = header.replace('\\', "\\\\").replace('"', "\\\"");
        write_owner_only(&path, &format!("header = \"{escaped}\"\n"))
            .map_err(|_| "Could not prepare private HTTP credentials".to_string())?;
        Ok(Self { path: Some(path) })
    }

    pub fn apply<'a>(&self, command: &'a mut Command) -> &'a mut Command {
        // Must be curl's first option. Personal curl defaults must not add
        // redirects, retries or destinations to an application-owned request.
        command.arg("--disable");
        if let Some(path) = &self.path {
            command.arg("--config").arg(path);
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
    if let Err(error) = file.write_all(contents.as_bytes()) {
        let _ = fs::remove_file(path);
        return Err(error);
    }
    Ok(())
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

fn drain(pipe: &mut Option<impl Read>, bytes: &mut Vec<u8>) -> io::Result<usize> {
    let Some(pipe) = pipe else { return Ok(0) };
    let mut buffer = [0; 8192];
    let mut read = 0;
    loop {
        match pipe.read(&mut buffer) {
            Ok(0) => return Ok(read),
            Ok(count) => {
                if bytes.len() + count > 4 * 1024 * 1024 {
                    return Err(io::Error::other("subprocess response exceeds 4 MiB"));
                }
                bytes.extend_from_slice(&buffer[..count]);
                read += count;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(read),
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
    if cancel.load(Ordering::Acquire) {
        return Err("dictation cancelled".into());
    }
    let child = command
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    communicate(child, Some(input), cancel, timeout)
}

const CURL_WRITE_OUT: &str =
    "%{stderr}\nomaflow-http-status:%{http_code}\nomaflow-retry-after:%header{retry-after}\n";
const HTTP_ATTEMPTS: usize = 3;

/// Run one HTTP request with a fresh process and response buffer per attempt.
/// Curl's own `--retry-all-errors` cannot safely share our piped stdout: an
/// error response body is left in the pipe and gets concatenated with a later
/// successful JSON response. Keeping the loop here also lets permanent client
/// and authentication errors fail without resending private input.
pub fn run_http(
    mut build: impl FnMut() -> Command,
    input: &[u8],
    cancel: &AtomicBool,
    timeout: Duration,
) -> Result<Output, String> {
    let deadline = Instant::now() + timeout;
    for attempt in 0..HTTP_ATTEMPTS {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("operation timed out".into());
        }
        let mut command = build();
        let (output, http_status, retry_after) =
            run_http_once(&mut command, input, cancel, remaining)?;
        if output.status.success()
            || attempt + 1 == HTTP_ATTEMPTS
            || !retryable_http_failure(output.status.code(), http_status)
        {
            return Ok(output);
        }
        let fallback = [Duration::from_millis(250), Duration::from_millis(750)][attempt];
        wait_for_retry(retry_after.unwrap_or(fallback), cancel, deadline)?;
    }
    unreachable!()
}

/// A single attempt, also used by explicit connection tests to avoid billing
/// multiple inference requests just to check credentials and a model.
pub fn run_http_once(
    command: &mut Command,
    input: &[u8],
    cancel: &AtomicBool,
    timeout: Duration,
) -> Result<(Output, Option<u16>, Option<Duration>), String> {
    command.args(["--write-out", CURL_WRITE_OUT]);
    let mut output = run(command, input, cancel, timeout)?;
    let (status, retry_after) = take_curl_metadata(&mut output.stderr);
    Ok((output, status, retry_after))
}

fn retryable_http_failure(exit_code: Option<i32>, http_status: Option<u16>) -> bool {
    // Permanent HTTP rejections stay permanent even if their error body was
    // interrupted. A successful status does not mean its body arrived intact.
    if let Some(status) = http_status.filter(|status| *status >= 400) {
        return matches!(status, 408 | 429 | 500 | 502 | 503 | 504 | 522 | 524)
            && matches!(exit_code, Some(18 | 22 | 28 | 52 | 55 | 56));
    }
    matches!(exit_code, Some(5 | 6 | 7 | 18 | 28 | 52 | 55 | 56))
}

fn take_curl_metadata(stderr: &mut Vec<u8>) -> (Option<u16>, Option<Duration>) {
    let text = String::from_utf8_lossy(stderr);
    let mut status = None;
    let mut retry_after = None;
    let mut diagnostic = Vec::new();
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("omaflow-http-status:") {
            status = value.trim().parse().ok();
        } else if let Some(value) = line.strip_prefix("omaflow-retry-after:") {
            retry_after = parse_retry_after(value.trim(), SystemTime::now());
        } else if !line.is_empty() {
            diagnostic.push(line);
        }
    }
    *stderr = diagnostic.join("\n").into_bytes();
    (status, retry_after)
}

fn parse_retry_after(value: &str, now: SystemTime) -> Option<Duration> {
    if !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()) {
        // An enormous valid delay means no retry within our bounded deadline.
        return Some(Duration::from_secs(value.parse().unwrap_or(u64::MAX)));
    }
    httpdate::parse_http_date(value)
        .ok()
        .map(|date| date.duration_since(now).unwrap_or_default())
}

fn wait_for_retry(
    duration: Duration,
    cancel: &AtomicBool,
    deadline: Instant,
) -> Result<(), String> {
    let now = Instant::now();
    let until = now + duration.min(deadline.saturating_duration_since(now));
    while Instant::now() < until {
        if cancel.load(Ordering::Acquire) {
            return Err("dictation cancelled".into());
        }
        thread::sleep(
            Duration::from_millis(20).min(until.saturating_duration_since(Instant::now())),
        );
    }
    if Instant::now() >= deadline {
        Err("operation timed out".into())
    } else {
        Ok(())
    }
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
            let mut progressed =
                drain(&mut child.stdout, &mut stdout).map_err(|e| e.to_string())? > 0;
            progressed |= drain(&mut child.stderr, &mut stderr).map_err(|e| e.to_string())? > 0;
            if let Some(input) = input {
                while written < input.len() && child.stdin.is_some() {
                    let pipe = child.stdin.as_mut().expect("stdin checked above");
                    match pipe.write(&input[written..]) {
                        Ok(0) => return Err("subprocess stdin stopped accepting input".into()),
                        Ok(count) => {
                            written += count;
                            progressed = true;
                        }
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                        // Curl can reject a request before consuming stdin.
                        // Still collect its exit status and HTTP diagnostics.
                        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => {
                            child.stdin.take();
                        }
                        Err(error) => return Err(error.to_string()),
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
            if !progressed {
                thread::sleep(Duration::from_millis(2));
            }
        }
    })();
    if result.is_err() {
        let _ = child.kill();
        let deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < deadline {
            match child.try_wait() {
                Ok(Some(_)) | Err(_) => break,
                Ok(None) => thread::sleep(Duration::from_millis(2)),
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
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

    #[test]
    fn http_retry_discards_the_failed_body_and_resends_the_same_input() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/request", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let mut bodies = Vec::new();
            for status in ["503 Service Unavailable", "200 OK"] {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = Vec::new();
                let mut buffer = [0; 4096];
                loop {
                    let count = stream.read(&mut buffer).unwrap();
                    request.extend_from_slice(&buffer[..count]);
                    let Some(headers_end) = request.windows(4).position(|w| w == b"\r\n\r\n")
                    else {
                        continue;
                    };
                    let headers = String::from_utf8_lossy(&request[..headers_end]);
                    let length: usize = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(str::trim)
                                .map(str::to_owned)
                        })
                        .unwrap()
                        .parse()
                        .unwrap();
                    if request.len() >= headers_end + 4 + length {
                        bodies.push(request[headers_end + 4..headers_end + 4 + length].to_vec());
                        break;
                    }
                }
                let body = if status.starts_with("503") {
                    r#"{"error":"busy"}"#
                } else {
                    r#"{"text":"ok"}"#
                };
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
            bodies
        });
        let input = br#"{"private":"same request"}"#;
        let output = run_http(
            || {
                let mut command = Command::new("curl");
                command
                    .args([
                        "--silent",
                        "--show-error",
                        "--fail-with-body",
                        "--data-binary",
                        "@-",
                        &endpoint,
                    ])
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped());
                command
            },
            input,
            &AtomicBool::new(false),
            Duration::from_secs(3),
        )
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, br#"{"text":"ok"}"#);
        assert_eq!(server.join().unwrap(), [input.to_vec(), input.to_vec()]);
    }

    #[test]
    fn http_retry_rejects_permanent_statuses() {
        assert!(!retryable_http_failure(Some(22), Some(400)));
        assert!(!retryable_http_failure(Some(22), Some(401)));
        assert!(retryable_http_failure(Some(22), Some(429)));
        assert!(retryable_http_failure(Some(22), Some(503)));
        assert!(!retryable_http_failure(Some(60), None));
        assert!(retryable_http_failure(Some(7), None));
        assert!(retryable_http_failure(Some(18), Some(200)));
        assert!(retryable_http_failure(Some(56), Some(200)));
        assert!(retryable_http_failure(Some(28), Some(200)));
        assert!(!retryable_http_failure(Some(18), Some(401)));
        assert!(!retryable_http_failure(Some(60), Some(503)));
    }

    #[test]
    fn retry_after_supports_dates_seconds_and_extreme_values() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let date = httpdate::fmt_http_date(now + Duration::from_secs(60));
        assert_eq!(parse_retry_after(&date, now), Some(Duration::from_secs(60)));
        assert_eq!(parse_retry_after("60", now), Some(Duration::from_secs(60)));
        assert_eq!(parse_retry_after("0", now), Some(Duration::ZERO));
        assert_eq!(
            parse_retry_after(&date, now + Duration::from_secs(90)),
            Some(Duration::ZERO)
        );
        assert_eq!(parse_retry_after("-1", now), None);
        assert_eq!(parse_retry_after("garbage", now), None);
        let huge = parse_retry_after("999999999999999999999999999", now).unwrap();
        let deadline = Instant::now() + Duration::from_millis(20);
        assert_eq!(
            wait_for_retry(huge, &AtomicBool::new(false), deadline).unwrap_err(),
            "operation timed out"
        );
    }

    fn busy_response() -> Command {
        let mut command = Command::new("sh");
        command
            .args([
                "-c",
                "printf 'omaflow-http-status:503\\nomaflow-retry-after:60\\n' >&2; exit 22",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }

    #[test]
    fn cancellation_interrupts_http_backoff_without_another_attempt() {
        let cancel = AtomicBool::new(false);
        let mut attempts = 0;
        let start = Instant::now();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(100));
                cancel.store(true, Ordering::Release);
            });
            let error = run_http(
                || {
                    attempts += 1;
                    busy_response()
                },
                b"",
                &cancel,
                Duration::from_secs(30),
            )
            .unwrap_err();
            assert_eq!(error, "dictation cancelled");
        });
        assert_eq!(attempts, 1);
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn http_deadline_includes_backoff() {
        let mut attempts = 0;
        let start = Instant::now();
        let error = run_http(
            || {
                attempts += 1;
                busy_response()
            },
            b"",
            &AtomicBool::new(false),
            Duration::from_millis(100),
        )
        .unwrap_err();
        assert_eq!(error, "operation timed out");
        assert_eq!(attempts, 1);
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn cancellation_interrupts_http_in_flight_and_prevents_spawn() {
        let cancel = AtomicBool::new(false);
        let start = Instant::now();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(100));
                cancel.store(true, Ordering::Release);
            });
            let error = run_http(
                || {
                    let mut command = Command::new("sh");
                    command.args(["-c", "exec sleep 30"]);
                    command
                },
                b"",
                &cancel,
                Duration::from_secs(30),
            )
            .unwrap_err();
            assert_eq!(error, "dictation cancelled");
        });
        assert!(start.elapsed() < Duration::from_secs(1));
        let error = run_http(
            || Command::new("/nonexistent-do-not-spawn"),
            b"",
            &cancel,
            Duration::from_secs(1),
        )
        .unwrap_err();
        assert_eq!(error, "dictation cancelled");
    }
}
