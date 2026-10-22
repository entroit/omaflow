//! A host-namespace helper authenticates a socket, then transfers that socket.
//! It exits before the sandboxed caller sends credentials or request bodies.
use super::{LocalPolicy, connect_verified};
use crate::process::CommandExt;
use std::{
    ffi::OsString,
    fs,
    io::{self, Read},
    net::{SocketAddr, TcpStream},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::{
            fs::{DirBuilderExt, MetadataExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};

const FAILURE: &str = "Could not authenticate the local model connection outside its sandbox";

fn full_mapping() -> Result<bool, String> {
    let mapping = fs::read_to_string("/proc/self/uid_map").map_err(|_| FAILURE)?;
    Ok(identity_mapping(&mapping))
}

fn identity_mapping(mapping: &str) -> bool {
    let mut next = 0_u64;
    for line in mapping.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 3 {
            return false;
        }
        let (Ok(inside), Ok(outside), Ok(count)) = (
            fields[0].parse::<u64>(),
            fields[1].parse::<u64>(),
            fields[2].parse::<u64>(),
        ) else {
            return false;
        };
        if inside != next || outside != inside || count == 0 {
            return false;
        }
        let Some(end) = next.checked_add(count) else {
            return false;
        };
        next = end;
    }
    next == u64::from(u32::MAX)
}

fn service_invocation() -> bool {
    std::env::var("INVOCATION_ID")
        .is_ok_and(|value| value.len() == 32 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

fn validate_addresses(addresses: &[SocketAddr]) -> Result<(), String> {
    if addresses.is_empty()
        || addresses.len() > 2
        || addresses
            .iter()
            .any(|address| !address.ip().is_loopback() || address.port() == 0)
    {
        return Err("The connection helper accepts only loopback model addresses".into());
    }
    Ok(())
}

fn policy_name(policy: LocalPolicy) -> &'static str {
    match policy {
        LocalPolicy::SameUser => "same-user",
        LocalPolicy::Ollama => "ollama",
        LocalPolicy::ManagedSpeech => "managed-speech",
    }
}

/// Entry point for the transient helper. No HTTP data or credentials enter it.
pub fn connect_helper(socket: &Path, policy: &str, addresses: &[String]) -> Result<(), String> {
    if !full_mapping()? {
        return Err("The connection helper needs the host user namespace".into());
    }
    let policy = match policy {
        "same-user" => LocalPolicy::SameUser,
        "ollama" => LocalPolicy::Ollama,
        "managed-speech" => LocalPolicy::ManagedSpeech,
        _ => return Err("Unknown local model connection policy".into()),
    };
    let addresses = addresses
        .iter()
        .map(|value| value.parse::<SocketAddr>())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| "Invalid loopback model address")?;
    validate_addresses(&addresses)?;
    let peer = crate::ipc::connect(socket).map_err(|_| FAILURE)?;
    same_network_namespace(&peer)?;
    let server = connect_verified(&addresses, policy)?;
    send_descriptor(&peer, &server).map_err(|_| FAILURE.to_string())
}

fn same_network_namespace(peer: &UnixStream) -> Result<(), String> {
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut length = std::mem::size_of_val(&credentials) as libc::socklen_t;
    // SAFETY: both output buffers and the borrowed socket remain live.
    let result = unsafe {
        libc::getsockopt(
            peer.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result != 0 || length as usize != std::mem::size_of_val(&credentials) || credentials.pid <= 0
    {
        return Err(FAILURE.into());
    }
    let own = fs::metadata("/proc/self/ns/net").map_err(|_| FAILURE)?;
    let remote = fs::metadata(format!("/proc/{}/ns/net", credentials.pid)).map_err(|_| FAILURE)?;
    if own.dev() != remote.dev() || own.ino() != remote.ino() {
        return Err("The model connection helper is in another network namespace".into());
    }
    Ok(())
}

struct SocketDirectory(PathBuf);

impl SocketDirectory {
    fn create() -> Result<Self, String> {
        let runtime = crate::private_runtime_dir()?;
        let mut random = [0_u8; 16];
        // SAFETY: getrandom fills only this live fixed-size buffer.
        if unsafe { libc::getrandom(random.as_mut_ptr().cast(), random.len(), 0) }
            != random.len() as isize
        {
            return Err("Could not create a private model connection name".into());
        }
        let name: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let path = runtime.join(format!("omaflow-http-{name}"));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .map_err(|_| FAILURE)?;
        Ok(Self(path))
    }
    fn socket(&self) -> PathBuf {
        self.0.join("socket")
    }
}

impl Drop for SocketDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.socket());
        let _ = fs::remove_dir(&self.0);
    }
}

struct Helper {
    child: Option<Child>,
    unit: String,
}

impl Drop for Helper {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
            let _ = Command::new("/usr/bin/systemctl")
                .args(["--user", "stop", "--no-block", &self.unit])
                .bounded_status_for(Duration::from_millis(500));
        }
    }
}

pub(super) fn connect(
    addresses: &[SocketAddr],
    policy: LocalPolicy,
    stop: &AtomicBool,
) -> Result<TcpStream, String> {
    if policy == LocalPolicy::SameUser || full_mapping()? || !service_invocation() {
        return connect_verified(addresses, policy);
    }
    validate_addresses(addresses)?;
    let directory = SocketDirectory::create()?;
    let listener = UnixListener::bind(directory.socket()).map_err(|_| FAILURE)?;
    listener.set_nonblocking(true).map_err(|_| FAILURE)?;
    let unit = directory
        .0
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    let executable = std::env::current_exe().map_err(|_| FAILURE)?;
    let mut path = OsString::from("--setenv=PATH=");
    path.push(std::env::var_os("PATH").unwrap_or_else(|| OsString::from("/usr/bin")));
    let child = Command::new("/usr/bin/systemd-run")
        .args([
            "--user",
            "--wait",
            "--pipe",
            "--collect",
            "--quiet",
            "--service-type=exec",
            "--expand-environment=no",
        ])
        .arg(format!("--unit={unit}"))
        .arg(path)
        .args([
            "--property=RuntimeMaxSec=5s",
            "--property=TimeoutStopSec=1s",
            "--property=NoNewPrivileges=yes",
            "--property=RestrictNamespaces=yes",
            "--property=RestrictSUIDSGID=yes",
            "--property=LockPersonality=yes",
            "--property=UMask=0077",
        ])
        .arg(executable)
        .arg("http-connect")
        .arg(directory.socket())
        .arg(policy_name(policy))
        .args(addresses.iter().map(ToString::to_string))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| FAILURE)?;
    let mut helper = Helper {
        child: Some(child),
        unit,
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut peer = loop {
        check_wait(stop, deadline)?;
        match listener.accept() {
            Ok((peer, _)) => {
                if crate::ipc::verify_peer(&peer).is_ok() {
                    break peer;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(_) => return Err(FAILURE.into()),
        }
        if helper
            .child
            .as_mut()
            .unwrap()
            .try_wait()
            .map_err(|_| FAILURE)?
            .is_some()
        {
            return Err(FAILURE.into());
        }
        thread::sleep(Duration::from_millis(5));
    };
    peer.set_nonblocking(true).map_err(|_| FAILURE)?;
    let descriptor = loop {
        check_wait(stop, deadline)?;
        match receive_descriptor(&peer) {
            Ok(descriptor) => break descriptor,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5))
            }
            Err(_) => return Err(FAILURE.into()),
        }
    };
    loop {
        check_wait(stop, deadline)?;
        if let Some(status) = helper
            .child
            .as_mut()
            .unwrap()
            .try_wait()
            .map_err(|_| FAILURE)?
        {
            if !status.success() {
                return Err(FAILURE.into());
            }
            helper.child = None;
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }
    let mut trailing = [0_u8; 1];
    if peer.read(&mut trailing).map_err(|_| FAILURE)? != 0 {
        return Err(FAILURE.into());
    }
    verified_tcp(descriptor, addresses)
}

fn verified_tcp(descriptor: OwnedFd, addresses: &[SocketAddr]) -> Result<TcpStream, String> {
    let server = TcpStream::from(descriptor);
    if socket_option(&server, libc::SO_TYPE)? != libc::SOCK_STREAM
        || socket_option(&server, libc::SO_PROTOCOL)? != libc::IPPROTO_TCP
    {
        return Err(FAILURE.into());
    }
    let remote = server.peer_addr().map_err(|_| FAILURE)?;
    if !addresses.contains(&remote) || !server.local_addr().map_err(|_| FAILURE)?.ip().is_loopback()
    {
        return Err(FAILURE.into());
    }
    Ok(server)
}

fn socket_option(socket: &TcpStream, option: libc::c_int) -> Result<libc::c_int, String> {
    let mut value = 0;
    let mut length = std::mem::size_of_val(&value) as libc::socklen_t;
    // SAFETY: getsockopt writes into the live integer and its length.
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            option,
            (&mut value as *mut libc::c_int).cast(),
            &mut length,
        )
    };
    if result != 0 || length as usize != std::mem::size_of_val(&value) {
        return Err(FAILURE.into());
    }
    Ok(value)
}

fn check_wait(stop: &AtomicBool, deadline: Instant) -> Result<(), String> {
    if stop.load(Ordering::Acquire) {
        return Err("dictation cancelled".into());
    }
    if Instant::now() >= deadline {
        return Err("The local model connection helper timed out".into());
    }
    Ok(())
}

fn send_descriptor(peer: &UnixStream, descriptor: &impl AsRawFd) -> io::Result<()> {
    let mut byte = b'F';
    let mut vector = libc::iovec {
        iov_base: (&mut byte as *mut u8).cast(),
        iov_len: 1,
    };
    let mut control = [0_usize; 4];
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen =
        unsafe { libc::CMSG_SPACE(std::mem::size_of::<libc::c_int>() as u32) } as usize;
    // SAFETY: aligned control storage fits one header and one descriptor.
    unsafe {
        let header = libc::CMSG_FIRSTHDR(&message);
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<libc::c_int>() as u32) as usize;
        libc::CMSG_DATA(header)
            .cast::<libc::c_int>()
            .write(descriptor.as_raw_fd());
        if libc::sendmsg(peer.as_raw_fd(), &message, libc::MSG_NOSIGNAL) != 1 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn receive_descriptor(peer: &UnixStream) -> io::Result<OwnedFd> {
    let mut bytes = [0_u8; 2];
    let mut vector = libc::iovec {
        iov_base: bytes.as_mut_ptr().cast(),
        iov_len: bytes.len(),
    };
    let mut control = [0_usize; 16];
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = std::mem::size_of_val(&control);
    // SAFETY: recvmsg writes only within the live payload and aligned control buffers.
    let count = unsafe {
        libc::recvmsg(
            peer.as_raw_fd(),
            &mut message,
            libc::MSG_CMSG_CLOEXEC | libc::MSG_DONTWAIT,
        )
    };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut descriptors = Vec::new();
    let mut valid = count == 1
        && bytes[0] == b'F'
        && message.msg_flags & (libc::MSG_TRUNC | libc::MSG_CTRUNC) == 0;
    // The kernel validates ancillary headers. Own every received fd, including
    // those in a rejected message, so malformed or excessive rights cannot leak.
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(&message);
        while !header.is_null() {
            let size = (*header)
                .cmsg_len
                .saturating_sub(libc::CMSG_LEN(0) as usize);
            if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
                for index in 0..size / std::mem::size_of::<libc::c_int>() {
                    let descriptor = libc::CMSG_DATA(header)
                        .cast::<libc::c_int>()
                        .add(index)
                        .read();
                    descriptors.push(OwnedFd::from_raw_fd(descriptor));
                }
            } else {
                valid = false;
            }
            header = libc::CMSG_NXTHDR(&message, header);
        }
    }
    if !valid || descriptors.len() != 1 {
        return Err(io::Error::other("Invalid model connection descriptor"));
    }
    Ok(descriptors.pop().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::Write,
        net::{TcpListener, UdpSocket},
    };

    #[test]
    fn transferred_descriptor_is_the_same_connection_and_is_close_on_exec() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let original = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (mut accepted, _) = listener.accept().unwrap();
        let expected_local = original.local_addr().unwrap();
        let expected_remote = original.peer_addr().unwrap();
        let (sender, receiver) = UnixStream::pair().unwrap();
        send_descriptor(&sender, &original).unwrap();
        drop(original);
        let descriptor = receive_descriptor(&receiver).unwrap();
        // SAFETY: fcntl only inspects the live received descriptor's flags.
        assert_ne!(
            unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
        let mut transferred = verified_tcp(descriptor, &[expected_remote]).unwrap();
        assert_eq!(transferred.local_addr().unwrap(), expected_local);
        transferred.write_all(b"private recording").unwrap();
        let mut body = [0_u8; 17];
        accepted.read_exact(&mut body).unwrap();
        assert_eq!(&body, b"private recording");
    }

    fn rights(peer: &UnixStream, byte: u8, descriptors: &[libc::c_int]) {
        let mut payload = byte;
        let mut vector = libc::iovec {
            iov_base: (&mut payload as *mut u8).cast(),
            iov_len: 1,
        };
        let mut control = [0_usize; 64];
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = &mut vector;
        message.msg_iovlen = 1;
        message.msg_control = control.as_mut_ptr().cast();
        // SAFETY: the fixed aligned buffer holds all descriptors in these fixtures.
        unsafe {
            let bytes = std::mem::size_of_val(descriptors) as u32;
            message.msg_controllen = libc::CMSG_SPACE(bytes) as usize;
            assert!(message.msg_controllen <= std::mem::size_of_val(&control));
            let header = libc::CMSG_FIRSTHDR(&message);
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(bytes) as usize;
            std::ptr::copy_nonoverlapping(
                descriptors.as_ptr(),
                libc::CMSG_DATA(header).cast(),
                descriptors.len(),
            );
            assert_eq!(
                libc::sendmsg(peer.as_raw_fd(), &message, libc::MSG_NOSIGNAL),
                1
            );
        }
    }

    #[test]
    fn malformed_and_truncated_transfers_close_every_received_descriptor() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let original = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (_accepted, _) = listener.accept().unwrap();
        let inode = fs::read_link(format!("/proc/self/fd/{}", original.as_raw_fd())).unwrap();
        let copies = || {
            fs::read_dir("/proc/self/fd")
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| fs::read_link(entry.path()).is_ok_and(|value| value == inode))
                .count()
        };
        for (payload, count) in [(b'X', 1), (b'F', 2), (b'F', 40)] {
            let (sender, receiver) = UnixStream::pair().unwrap();
            rights(&sender, payload, &vec![original.as_raw_fd(); count]);
            assert!(receive_descriptor(&receiver).is_err());
            assert_eq!(copies(), 1, "a rejected rights message leaked a descriptor");
        }
        let (mut sender, receiver) = UnixStream::pair().unwrap();
        sender.write_all(b"F").unwrap();
        assert!(receive_descriptor(&receiver).is_err());
    }

    #[test]
    fn connected_udp_and_an_unrequested_tcp_destination_are_rejected() {
        let listener = UdpSocket::bind("127.0.0.1:0").unwrap();
        let client = UdpSocket::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        client.connect(address).unwrap();
        assert!(verified_tcp(client.into(), &[address]).is_err());
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        assert!(verified_tcp(client.into(), &["127.0.0.1:1".parse().unwrap()]).is_err());
    }

    #[test]
    fn helper_requires_an_identity_map_and_loopback_destinations() {
        assert!(identity_mapping("0 0 4294967295\n"));
        assert!(identity_mapping("0 0 65534\n65534 65534 4294901761\n"));
        for mapping in [
            "",
            "0 1000 1\n",
            "1000 1000 1\n",
            "0 1 4294967295\n",
            "0 0 1\n2 2 4294967294\n",
        ] {
            assert!(!identity_mapping(mapping));
        }
        assert!(
            validate_addresses(&[
                "127.0.0.1:18103".parse().unwrap(),
                "[::1]:18103".parse().unwrap()
            ])
            .is_ok()
        );
        assert!(validate_addresses(&["192.0.2.1:18103".parse().unwrap()]).is_err());
        assert!(validate_addresses(&["127.0.0.1:0".parse().unwrap()]).is_err());
        assert!(validate_addresses(&[]).is_err());
    }
}
