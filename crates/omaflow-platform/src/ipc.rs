//! Unix peer checks and unambiguous local user identities.
use std::{fs, io, os::fd::AsRawFd, os::unix::net::UnixStream, path::Path};

pub fn connect(path: &Path) -> io::Result<UnixStream> {
    let stream = UnixStream::connect(path)?;
    verify_peer(&stream)?;
    Ok(stream)
}

pub fn verify_peer(stream: &UnixStream) -> io::Result<()> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of_val(&credentials) as libc::socklen_t;
    // The live stream owns the fd; both output buffers stay valid for the call.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    verify_uid(credentials.uid)?;
    if length as usize != std::mem::size_of_val(&credentials)
        || credentials.uid != unsafe { libc::geteuid() }
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "the local service belongs to another user",
        ));
    }
    Ok(())
}

pub(crate) fn verify_uid(uid: u32) -> io::Result<()> {
    let overflow = fs::read_to_string("/proc/sys/kernel/overflowuid")?
        .trim()
        .parse::<u32>()
        .map_err(|_| io::Error::other("could not read the kernel overflow UID"))?;
    // Unmapped accounts collapse to this UID. Even an explicit mapping of that
    // number is ambiguous unless the namespace maps every usable kernel UID.
    if uid == u32::MAX
        || (uid == overflow && !full_uid_map(&fs::read_to_string("/proc/self/uid_map")?))
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "the local service UID is ambiguous in this user namespace",
        ));
    }
    Ok(())
}

fn full_uid_map(mapping: &str) -> bool {
    // The kernel guarantees nonoverlapping ranges and reserves UID -1.
    mapping.lines().try_fold(0_u64, |total, line| {
        total.checked_add(line.split_whitespace().nth(2)?.parse::<u64>().ok()?)
    }) == Some(u64::from(u32::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mapped_overflow_uid_does_not_remove_unmapped_uid_ambiguity() {
        assert!(!full_uid_map("0 1000 1\n65534 1001 1\n"));
        assert!(!full_uid_map("0 1000 1\n"));
        assert!(!full_uid_map(""));
        assert!(full_uid_map("0 0 4294967295\n"));
        assert!(full_uid_map("0 0 65534\n65534 65534 4294901761\n"));
    }
}
