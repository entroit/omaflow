//! Plays a journal recording back through PipeWire. Recordings are the 16 kHz
//! mono WAV files OmaFlow writes itself, so the samples go straight to
//! `pw-cat` without a decoder.
use crate::process;
use std::{
    fs,
    io::{self, Read, Seek, SeekFrom, Write},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

const HEADER_BYTES: u64 = 44;
const BYTES_PER_MS: u64 = 32;
// The maximum configured recording duration is one hour.
const MAX_RECORDING_BYTES: u64 = HEADER_BYTES + 3_600_000 * BYTES_PER_MS;

/// Length of a recording from the same open file that playback will consume.
pub fn recording_duration_ms(file: &fs::File) -> Result<u64, String> {
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file() || metadata.len() > MAX_RECORDING_BYTES {
        return Err("The recording must be a regular file no longer than one hour".into());
    }
    Ok(metadata.len().saturating_sub(HEADER_BYTES) / BYTES_PER_MS)
}

/// Blocks until playback finishes or `stop` is set, including when PipeWire stalls.
pub fn play_wav_file(file: fs::File, offset_ms: u64, stop: Arc<AtomicBool>) -> Result<(), String> {
    recording_duration_ms(&file)?;
    let mut command = Command::new("pw-cat");
    command.args([
        "--playback",
        "--raw",
        "--format",
        "s16",
        "--rate",
        "16000",
        "--channels",
        "1",
        "-",
    ]);
    play(file, offset_ms, &stop, &mut command)
}

fn play(
    mut file: fs::File,
    offset_ms: u64,
    stop: &AtomicBool,
    command: &mut Command,
) -> Result<(), String> {
    let mut header = [0; HEADER_BYTES as usize];
    file.read_exact(&mut header)
        .map_err(|error| error.to_string())?;
    if &header[0..4] != b"RIFF" || &header[36..40] != b"data" {
        return Err("The file is not an OmaFlow recording".into());
    }
    let offset = offset_ms
        .checked_mul(BYTES_PER_MS)
        .and_then(|bytes| bytes.checked_add(HEADER_BYTES))
        .ok_or("The playback position exceeds the recording")?;
    let remaining = file
        .metadata()
        .map_err(|error| error.to_string())?
        .len()
        .saturating_sub(offset);
    file.seek(SeekFrom::Start(offset))
        .map_err(|error| error.to_string())?;
    if stop.load(Ordering::Acquire) {
        return Ok(());
    }
    let deadline = Instant::now() + Duration::from_millis(remaining / BYTES_PER_MS + 10_000);
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("could not start pw-cat: {error}"))?;
    let result = (|| {
        let mut input = child.stdin.take().ok_or("pw-cat has no input")?;
        process::nonblocking(&input).map_err(|error| error.to_string())?;
        let mut buffer = [0; 4_000];
        let mut bytes_left = remaining;
        while bytes_left > 0 {
            let count = file
                .read(&mut buffer[..bytes_left.min(4_000) as usize])
                .map_err(|error| error.to_string())?;
            if count == 0 {
                break;
            }
            bytes_left -= count as u64;
            let mut sent = 0;
            while sent < count {
                if stop.load(Ordering::Acquire) {
                    return Ok(());
                }
                if Instant::now() >= deadline {
                    return Err("Playback timed out".into());
                }
                match input.write(&buffer[sent..count]) {
                    Ok(0) => return Err("The audio player stopped accepting samples".into()),
                    Ok(written) => sent += written,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2))
                    }
                    Err(error) => return Err(format!("The audio player stopped: {error}")),
                }
            }
        }
        Ok(())
    })();
    if result.is_err() || stop.load(Ordering::Acquire) {
        let _ = child.kill();
    }
    let waited = process::wait(
        child,
        stop,
        deadline.saturating_duration_since(Instant::now()),
    );
    if stop.load(Ordering::Acquire) {
        return Ok(());
    }
    result?;
    let output = waited?;
    if output.status.success() {
        Ok(())
    } else {
        Err("The audio player stopped before playback finished".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stop_interrupts_both_a_blocked_pipe_and_a_stalled_player_at_eof() {
        for samples in [64, 1_000_000] {
            let mut file = tempfile::tempfile().unwrap();
            let mut wav = vec![0; HEADER_BYTES as usize + samples];
            wav[..4].copy_from_slice(b"RIFF");
            wav[36..40].copy_from_slice(b"data");
            file.write_all(&wav).unwrap();
            file.rewind().unwrap();
            let stop = Arc::new(AtomicBool::new(false));
            let signal = stop.clone();
            let thread = thread::spawn(move || {
                let mut command = Command::new("sh");
                command.args(["-c", "exec sleep 30"]);
                play(file, 0, &signal, &mut command)
            });
            thread::sleep(Duration::from_millis(100));
            let at = Instant::now();
            stop.store(true, Ordering::Release);
            thread.join().unwrap().unwrap();
            assert!(at.elapsed() < Duration::from_secs(1));
        }
    }
}
