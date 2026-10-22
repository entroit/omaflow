//! Private model requests use the same TCP connection whose owner was checked.
use crate::process::{CommandExt, CurlAuth};
use omaflow_core::config::{model_endpoint, model_host_is_loopback};
use std::{
    fs,
    io::{self, Read, Write},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpStream},
    os::{
        linux::net::SocketAddrExt,
        unix::{
            fs::MetadataExt,
            net::{SocketAddr as UnixAddr, UnixListener, UnixStream},
        },
    },
    process::Command,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

mod helper;
pub use helper::connect_helper;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum LocalPolicy {
    SameUser,
    Ollama,
    ManagedSpeech,
}

pub struct HttpEndpoint {
    url: String,
    auth: CurlAuth,
    relay: Option<Relay>,
}

struct Relay {
    name: String,
    stop: Arc<AtomicBool>,
    failure: Arc<Mutex<Option<String>>>,
    worker: Option<JoinHandle<()>>,
}

static NEXT_RELAY: AtomicU64 = AtomicU64::new(0);

impl HttpEndpoint {
    pub fn prepare(url: &str, policy: LocalPolicy, api_key: &str) -> Result<Self, String> {
        let (host, port, secure) = model_endpoint(url)?;
        let local = model_host_is_loopback(host);
        if policy == LocalPolicy::ManagedSpeech && (secure || !local) {
            return Err("Managed speech needs an authenticated local HTTP connection".into());
        }
        let relay = if local && !secure {
            let addresses = if host == "localhost" {
                vec![
                    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), port),
                    SocketAddr::new(Ipv6Addr::LOCALHOST.into(), port),
                ]
            } else {
                vec![SocketAddr::new(
                    host.parse().map_err(|_| "Invalid loopback address")?,
                    port,
                )]
            };
            Some(Relay::start(addresses, policy)?)
        } else {
            None
        };
        Ok(Self {
            url: url.into(),
            auth: CurlAuth::new(api_key)?,
            relay,
        })
    }

    pub fn command(&self) -> Command {
        let mut command = Command::new("curl");
        self.auth.apply(&mut command);
        if let Some(relay) = &self.relay {
            command.args(["--abstract-unix-socket", &relay.name]);
        }
        command.args(["--url", &self.url]);
        command
    }

    pub fn check(&self) -> Result<(), String> {
        if let Some(relay) = &self.relay
            && let Some(error) = relay.failure.lock().unwrap().as_ref()
        {
            return Err(error.clone());
        }
        Ok(())
    }
}

impl Relay {
    fn start(addresses: Vec<SocketAddr>, policy: LocalPolicy) -> Result<Self, String> {
        let name = format!(
            "omaflow-http-{}-{}",
            std::process::id(),
            NEXT_RELAY.fetch_add(1, Ordering::Relaxed)
        );
        let address = UnixAddr::from_abstract_name(&name).map_err(|error| error.to_string())?;
        let listener = UnixListener::bind_addr(&address)
            .map_err(|error| format!("Could not create private HTTP connection: {error}"))?;
        listener
            .set_nonblocking(true)
            .map_err(|error| error.to_string())?;
        let stop = Arc::new(AtomicBool::new(false));
        let failure = Arc::new(Mutex::new(None));
        let worker_stop = stop.clone();
        let worker_failure = failure.clone();
        let worker = thread::spawn(move || {
            while !worker_stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((client, _)) => {
                        // The bound abstract socket cannot be replaced. Its public
                        // name grants no access to clients from another account.
                        if crate::ipc::verify_peer(&client).is_err() {
                            continue;
                        }
                        *worker_failure.lock().unwrap() = None;
                        match helper::connect(&addresses, policy, &worker_stop) {
                            Ok(server) => {
                                if let Err(error) = forward(client, server, &worker_stop) {
                                    *worker_failure.lock().unwrap() = Some(error.to_string());
                                }
                            }
                            Err(error) => {
                                *worker_failure.lock().unwrap() = Some(error);
                                drop(client);
                            }
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5))
                    }
                    Err(error) => {
                        *worker_failure.lock().unwrap() =
                            Some(format!("Private HTTP connection failed: {error}"));
                        break;
                    }
                }
            }
        });
        Ok(Self {
            name,
            stop,
            failure,
            worker: Some(worker),
        })
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn connect_verified(addresses: &[SocketAddr], policy: LocalPolicy) -> Result<TcpStream, String> {
    let stream = addresses
        .iter()
        .find_map(|address| TcpStream::connect_timeout(address, Duration::from_secs(1)).ok())
        .ok_or("Could not connect to the local model service")?;
    let server = stream.peer_addr().map_err(|error| error.to_string())?;
    let client = stream.local_addr().map_err(|error| error.to_string())?;
    let deadline = Instant::now() + Duration::from_millis(500);
    let owner = loop {
        if let Some(owner) = connection_owner(server, client)?
            && owner.inode != 0
        {
            break owner;
        }
        if Instant::now() >= deadline {
            return Err("Could not verify the local model connection owner".into());
        }
        thread::sleep(Duration::from_millis(5));
    };
    verify_owner(owner, policy)?;
    Ok(stream)
}

#[derive(Clone, Copy)]
struct Owner {
    uid: u32,
    inode: u64,
}

fn verify_owner(owner: Owner, policy: LocalPolicy) -> Result<(), String> {
    crate::ipc::verify_uid(owner.uid).map_err(|error| error.to_string())?;
    let uid = unsafe { libc::geteuid() };
    match policy {
        LocalPolicy::SameUser if owner.uid == uid => Ok(()),
        LocalPolicy::Ollama if owner.uid == uid => Ok(()),
        LocalPolicy::Ollama => {
            let pid = service_pid(false, "ollama.service")?;
            let service = fs::metadata(format!("/proc/{pid}"))
                .map_err(|_| "Could not verify the system Ollama service owner")?;
            if owner.uid == service.uid() {
                Ok(())
            } else {
                Err("The local cleanup connection belongs to another user, not the system Ollama service".into())
            }
        }
        LocalPolicy::ManagedSpeech if owner.uid == uid => {
            let pid = service_pid(true, "omaflow-asr.service")?;
            if process_has_socket(pid, owner.inode)? {
                Ok(())
            } else {
                Err("The speech connection does not belong to omaflow-asr.service".into())
            }
        }
        _ => Err("The local model connection belongs to another user".into()),
    }
}

fn service_pid(user: bool, service: &str) -> Result<u32, String> {
    let output = Command::new("systemctl")
        .args([
            if user { "--user" } else { "--system" },
            "show",
            service,
            "--property=MainPID",
            "--value",
        ])
        .bounded_output_for(Duration::from_secs(1))
        .map_err(|_| format!("Could not verify {service}"))?;
    if output.status.success()
        && let Ok(pid @ 1..) = String::from_utf8_lossy(&output.stdout)
            .trim()
            .parse::<u32>()
    {
        return Ok(pid);
    }
    Err(format!("{service} has no running process to authenticate"))
}

fn process_has_socket(pid: u32, inode: u64) -> Result<bool, String> {
    let expected = format!("socket:[{inode}]");
    let descriptors = fs::read_dir(format!("/proc/{pid}/fd"))
        .map_err(|_| "Could not inspect the managed speech service sockets")?;
    Ok(descriptors.filter_map(Result::ok).any(|entry| {
        fs::read_link(entry.path()).is_ok_and(|link| link.as_os_str() == expected.as_str())
    }))
}

fn connection_owner(server: SocketAddr, client: SocketAddr) -> Result<Option<Owner>, String> {
    // Dual-stack listeners record IPv4 peers in tcp6 as mapped addresses.
    for path in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let table = match fs::read_to_string(path) {
            Ok(table) => table,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(_) => return Err("Could not inspect the local model connection".into()),
        };
        for line in table.lines().skip(1) {
            let fields: Vec<_> = line.split_whitespace().collect();
            if fields.len() < 10
                || fields[3] != "01"
                || proc_address(fields[1]) != Some(server)
                || proc_address(fields[2]) != Some(client)
            {
                continue;
            }
            if let (Ok(uid), Ok(inode)) = (fields[7].parse(), fields[9].parse()) {
                return Ok(Some(Owner { uid, inode }));
            }
        }
    }
    Ok(None)
}

fn proc_address(value: &str) -> Option<SocketAddr> {
    let (address, port) = value.split_once(':')?;
    let port = u16::from_str_radix(port, 16).ok()?;
    let ip = match address.len() {
        8 => IpAddr::V4(Ipv4Addr::from(
            u32::from_str_radix(address, 16).ok()?.to_ne_bytes(),
        )),
        32 => {
            let mut bytes = [0_u8; 16];
            for (word, output) in address
                .as_bytes()
                .as_chunks::<8>()
                .0
                .iter()
                .zip(bytes.as_chunks_mut::<4>().0.iter_mut())
            {
                output.copy_from_slice(
                    &u32::from_str_radix(std::str::from_utf8(word).ok()?, 16)
                        .ok()?
                        .to_ne_bytes(),
                );
            }
            let ip = Ipv6Addr::from(bytes);
            ip.to_ipv4_mapped()
                .map(IpAddr::V4)
                .unwrap_or(IpAddr::V6(ip))
        }
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

fn forward(mut client: UnixStream, mut server: TcpStream, stop: &AtomicBool) -> io::Result<()> {
    client.set_nonblocking(true)?;
    server.set_nonblocking(true)?;
    let mut upload = Transfer::default();
    let mut download = Transfer::default();
    while !stop.load(Ordering::Acquire) {
        let upload_done = upload.pump(&mut client, &mut server)?;
        let download_done = download.pump(&mut server, &mut client)?;
        if upload_done {
            server.shutdown(Shutdown::Write).ok();
        }
        if download_done {
            client.shutdown(Shutdown::Write).ok();
        }
        if upload_done && download_done {
            break;
        }
        thread::sleep(Duration::from_millis(2));
    }
    Ok(())
}

#[derive(Default)]
struct Transfer {
    bytes: Vec<u8>,
    sent: usize,
    ended: bool,
}

impl Transfer {
    fn pump(&mut self, source: &mut impl Read, target: &mut impl Write) -> io::Result<bool> {
        if self.sent == self.bytes.len() && !self.ended {
            self.bytes.resize(64 * 1024, 0);
            match source.read(&mut self.bytes) {
                Ok(count) => {
                    self.bytes.truncate(count);
                    self.sent = 0;
                    self.ended = count == 0;
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) =>
                {
                    self.bytes.clear();
                    self.sent = 0;
                }
                Err(error) => return Err(error),
            }
        }
        if self.sent < self.bytes.len() {
            match target.write(&self.bytes[self.sent..]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "local HTTP connection closed",
                    ));
                }
                Ok(count) => self.sent += count,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(self.ended && self.sent == self.bytes.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::process::run_http;
    use std::{io::BufRead, net::TcpListener, process::Stdio, sync::mpsc};

    #[test]
    fn relays_private_requests_on_ipv4_ipv6_and_dual_stack_connections() {
        for address in ["127.0.0.1:0", "[::1]:0", "[::]:0"] {
            let listener = TcpListener::bind(address).unwrap();
            let port = listener.local_addr().unwrap().port();
            let host = if address == "[::1]:0" {
                "[::1]"
            } else {
                "127.0.0.1"
            };
            let endpoint = HttpEndpoint::prepare(
                &format!("http://{host}:{port}/private"),
                LocalPolicy::SameUser,
                "synthetic-private-key",
            )
            .unwrap();
            let worker = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut reader = io::BufReader::new(stream.try_clone().unwrap());
                let mut headers = String::new();
                loop {
                    let mut line = String::new();
                    assert_ne!(reader.read_line(&mut line).unwrap(), 0);
                    if line == "\r\n" {
                        break;
                    }
                    headers.push_str(&line);
                }
                assert!(headers.contains("Authorization: Bearer synthetic-private-key\r\n"));
                let length: usize = headers
                    .lines()
                    .find_map(|line| line.strip_prefix("Content-Length: "))
                    .unwrap()
                    .parse()
                    .unwrap();
                let mut body = vec![0; length];
                reader.read_exact(&mut body).unwrap();
                assert_eq!(body, vec![b'X'; 150_000]);
                stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\nprivate response").unwrap();
            });
            let output = run_http(
                || {
                    let mut command = endpoint.command();
                    command
                        .args(["--silent", "--show-error", "--data-binary", "@-"])
                        .env("http_proxy", "http://127.0.0.1:1")
                        .env("NO_PROXY", "")
                        .stdout(Stdio::piped())
                        .stderr(Stdio::piped());
                    command
                },
                &vec![b'X'; 150_000],
                &AtomicBool::new(false),
                Duration::from_secs(3),
            )
            .unwrap();
            endpoint.check().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert_eq!(output.stdout, b"private response");
            worker.join().unwrap();
        }
    }

    #[test]
    fn listener_replacement_does_not_receive_a_verified_connections_body() {
        let script = r#"
import socket, sys
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', 0)); listener.listen()
address = listener.getsockname()
print(address[1], flush=True)
original, _ = listener.accept()
listener.close()
replacement = socket.socket()
replacement.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
replacement.bind(address); replacement.listen(); replacement.settimeout(.1)
print('replaced', flush=True)
assert original.recv(64) == b'private recording'
try:
    replacement.accept()
except TimeoutError:
    print('original received the recording; replacement received nothing', flush=True)
else:
    raise AssertionError('the replacement received a connection')
"#;
        let mut child = Command::new("python3")
            .args(["-c", script])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut output = io::BufReader::new(child.stdout.take().unwrap());
        let mut port = String::new();
        output.read_line(&mut port).unwrap();
        let address = format!("127.0.0.1:{}", port.trim()).parse().unwrap();
        let mut stream = connect_verified(&[address], LocalPolicy::SameUser).unwrap();
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        assert_eq!(line.trim(), "replaced");
        stream.write_all(b"private recording").unwrap();
        line.clear();
        output.read_line(&mut line).unwrap();
        assert_eq!(
            line.trim(),
            "original received the recording; replacement received nothing"
        );
        assert!(child.wait().unwrap().success());
    }

    #[test]
    fn verified_owner_is_the_accepted_socket_and_managed_process() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        let owner = connection_owner(server.local_addr().unwrap(), client.local_addr().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(owner.uid, unsafe { libc::geteuid() });
        assert_ne!(owner.inode, 0);
        assert!(process_has_socket(std::process::id(), owner.inode).unwrap());
        assert!(!process_has_socket(std::process::id(), u64::MAX).unwrap());
        verify_owner(owner, LocalPolicy::SameUser).unwrap();
        assert!(
            verify_owner(
                Owner {
                    uid: owner.uid + 1,
                    ..owner
                },
                LocalPolicy::SameUser
            )
            .is_err()
        );
    }

    #[test]
    fn dropping_a_stalled_relay_cancels_its_connections() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = HttpEndpoint::prepare(
            &format!("http://{}/private", listener.local_addr().unwrap()),
            LocalPolicy::SameUser,
            "",
        )
        .unwrap();
        let (accepted, ready) = mpsc::channel();
        let worker = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            accepted.send(()).unwrap();
            let mut bytes = Vec::new();
            stream.read_to_end(&mut bytes).unwrap();
        });
        let mut command = endpoint.command();
        command
            .arg("--silent")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = command.spawn().unwrap();
        ready.recv_timeout(Duration::from_secs(2)).unwrap();
        let start = Instant::now();
        drop(endpoint);
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(!child.wait().unwrap().success());
        worker.join().unwrap();
    }

    #[test]
    fn managed_policy_never_accepts_a_direct_external_connection() {
        for url in [
            "https://models.example/v1/audio/transcriptions",
            "https://127.0.0.1/v1/audio/transcriptions",
            "http://models.example/v1/audio/transcriptions",
        ] {
            assert!(HttpEndpoint::prepare(url, LocalPolicy::ManagedSpeech, "").is_err());
        }
    }
}
