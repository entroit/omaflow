//! Plays a journal recording back through PipeWire. Recordings are the 16 kHz
//! mono WAV files OmaFlow writes itself, so the samples go straight to
//! `pw-cat` without a decoder.
use std::{
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

const HEADER_BYTES: u64 = 44;
const BYTES_PER_MS: u64 = 32;

/// Length of a recording in milliseconds, from its size on disk.
pub fn wav_duration_ms(path: &Path) -> Result<u64, String> {
    let bytes = fs::metadata(path)
        .map_err(|error| format!("{}: {error}", path.display()))?
        .len();
    Ok(bytes.saturating_sub(HEADER_BYTES) / BYTES_PER_MS)
}

/// Blocks until the recording has played from `offset_ms`, or until `stop`
/// is set. Setting `stop` silences the output within one buffer.
pub fn play_wav(path: &Path, offset_ms: u64, stop: Arc<AtomicBool>) -> Result<(), String> {
    let mut file = fs::File::open(path).map_err(|error| format!("{}: {error}", path.display()))?;
    let mut header = [0; HEADER_BYTES as usize];
    file.read_exact(&mut header)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    if &header[0..4] != b"RIFF" || &header[36..40] != b"data" {
        return Err(format!("{} is not an OmaFlow recording", path.display()));
    }
    file.seek(SeekFrom::Start(HEADER_BYTES + offset_ms * BYTES_PER_MS))
        .map_err(|error| error.to_string())?;
    let mut child = Command::new("pw-cat")
        .args([
            "--playback",
            "--raw",
            "--format",
            "s16",
            "--rate",
            "16000",
            "--channels",
            "1",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("could not start pw-cat: {error}"))?;
    let mut input = child.stdin.take().ok_or("pw-cat has no input")?;
    // 125 ms per write keeps a stop request close to instant.
    let mut buffer = [0; 4_000];
    let result = loop {
        if stop.load(Ordering::Acquire) {
            let _ = child.kill();
            break Ok(());
        }
        match file.read(&mut buffer) {
            Ok(0) => break Ok(()),
            Ok(read) => {
                if input.write_all(&buffer[..read]).is_err() {
                    break Ok(());
                }
            }
            Err(error) => break Err(error.to_string()),
        }
    };
    drop(input);
    let _ = child.wait();
    result
}
