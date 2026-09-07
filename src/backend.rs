use crate::cleanup::cleanup;
pub use crate::cleanup::{cleanup_text, evaluate_text};
use crate::process::CommandExt;
use crate::{
    config::{Config, PasteMode, SegmentTier},
    vocabulary,
};
use serde_json::Value;
use std::{
    env, fs,
    io::{ErrorKind, Read, Seek, SeekFrom, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicI32, AtomicU8, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

static DELIVERY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

const METER_BARS: usize = 13;
const METER_SILENCE: &[u8] =
    b"0.000 -96.0 0 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000\n";
const METER_FLOOR_DBFS: f32 = -72.0;

#[derive(Debug)]
pub struct Transcript {
    pub text: String,
    pub raw_text: String,
    pub pasted: bool,
    pub delivery_error: String,
    pub cleanup_warning: String,
}

#[derive(Debug)]
pub enum StopOutcome {
    Transcript(Transcript),
    NoSpeech,
}

pub struct ProcessingSession {
    pub cancel: Arc<AtomicBool>,
    result: mpsc::Receiver<Result<StopOutcome, String>>,
    worker: thread::JoinHandle<()>,
}

impl ProcessingSession {
    pub fn wait(self) -> Result<StopOutcome, String> {
        let result = self
            .result
            .recv()
            .map_err(|_| "dictation worker stopped unexpectedly".to_string())?;
        let _ = self.worker.join();
        result
    }
}

#[derive(Debug, Default)]
enum ClipboardSnapshot {
    #[default]
    Empty,
    Content {
        mime_type: String,
        data: Vec<u8>,
    },
}

impl ClipboardSnapshot {
    fn text_context(&self) -> &str {
        match self {
            Self::Content { mime_type, data } if is_text_mime(mime_type) => {
                std::str::from_utf8(data).unwrap_or("")
            }
            _ => "",
        }
    }
}

pub struct Runtime {
    config: Config,
    meter_gate_db: Arc<AtomicI32>,
    recording: Option<CaptureSession>,
    preview: Option<MeterPreviewSession>,
    /// Last dictation activity, for releasing models after an idle spell.
    last_activity: Instant,
    idle_released: bool,
    /// Earliest moment to try releasing again after a failed attempt.
    release_retry_at: Option<Instant>,
}

/// Idle time after which models leave the GPU when `keep_models_loaded` is off.
const IDLE_RELEASE: Duration = Duration::from_secs(5 * 60);
/// Wait between release attempts when Ollama or systemd did not comply.
const RELEASE_RETRY: Duration = Duration::from_secs(30);

struct AudioMeter {
    file: fs::File,
    gate_db: Arc<AtomicI32>,
    smoothed: f32,
    bars: [f32; METER_BARS],
    display_dbfs: f32,
    voice_hold_frames: u8,
    detected: bool,
    last_published: f32,
    last_published_bars: [f32; METER_BARS],
    last_published_detected: bool,
    last_write: Instant,
}

struct CapturedAudio {
    pcm: Vec<u8>,
    voiced_frames: usize,
    /// Segments transcribed while recording, covering `pcm[..prefix_len]`.
    /// Empty when live transcription was off or any segment failed.
    prefix: Vec<String>,
    prefix_len: usize,
    tail_voiced_frames: usize,
}

const SEGMENT_PAUSE_BYTES: usize = 32_000 * 7 / 10; // 700 ms of 16 kHz S16 mono
const BYTES_PER_SECOND: usize = 32_000;

/// Decides where to cut finished speech during recording. Cuts happen only in
/// the middle of a pause, once the pending audio is long enough, so the ASR
/// never sees a clipped word; continuous speech simply waits for the stop.
/// Tiers let a longer segment accept a shorter pause.
struct Segmenter {
    /// (segment bytes, pause bytes): the base rule first, tiers in rising order.
    rules: Vec<(usize, usize)>,
    total: usize,
    segment_start: usize,
    silence_run: usize,
    voiced_frames: usize,
}

impl Segmenter {
    fn new(min_segment_seconds: u64, tiers: &[SegmentTier]) -> Self {
        let mut rules = Vec::with_capacity(tiers.len() + 1);
        if min_segment_seconds > 0 {
            rules.push((
                (min_segment_seconds as usize).saturating_mul(BYTES_PER_SECOND),
                SEGMENT_PAUSE_BYTES,
            ));
            rules.extend(tiers.iter().map(|tier| {
                (
                    (tier.seconds as usize).saturating_mul(BYTES_PER_SECOND),
                    (tier.pause_ms as usize).saturating_mul(BYTES_PER_SECOND / 1000),
                )
            }));
        }
        Self {
            rules,
            total: 0,
            segment_start: 0,
            silence_run: 0,
            voiced_frames: 0,
        }
    }

    /// The shortest pause that closes the current segment at its present
    /// length, or `None` while it is too short for every rule.
    fn pause_needed(&self) -> Option<usize> {
        let age = self.total - self.segment_start;
        self.rules
            .iter()
            .filter(|(bytes, _)| age >= *bytes)
            .map(|(_, pause)| *pause)
            .min()
    }

    /// Returns the byte range of a finished segment, or `None`. The returned
    /// `voiced` count is the number of voiced frames inside that segment.
    fn observe(&mut self, bytes: usize, voiced: bool) -> Option<(std::ops::Range<usize>, usize)> {
        self.total += bytes;
        if voiced {
            self.silence_run = 0;
            self.voiced_frames += 1;
        } else {
            self.silence_run += bytes;
        }
        if self.silence_run < self.pause_needed()? {
            return None;
        }
        // Cut on a sample boundary in the middle of the pause; the second half
        // of the silence leads the next segment.
        let cut = (self.total - self.silence_run / 2) & !1;
        if cut <= self.segment_start {
            return None;
        }
        let range = self.segment_start..cut;
        self.segment_start = cut;
        self.silence_run = self.total - cut;
        Some((range, std::mem::take(&mut self.voiced_frames)))
    }
}

impl AudioMeter {
    fn open(gate_db: Arc<AtomicI32>) -> Result<Self, String> {
        let path = meter_path();
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        let mut meter = Self {
            file,
            gate_db,
            smoothed: 0.0,
            bars: [0.0; METER_BARS],
            display_dbfs: -96.0,
            voice_hold_frames: 0,
            detected: false,
            last_published: 0.0,
            last_published_bars: [0.0; METER_BARS],
            last_published_detected: false,
            last_write: Instant::now(),
        };
        meter.write(0.0)?;
        Ok(meter)
    }

    fn update(&mut self, pcm: &[u8]) -> bool {
        let (samples, _) = pcm.as_chunks::<2>();
        let count = samples.len();
        if count == 0 {
            return false;
        }
        let sum_squares = samples
            .iter()
            .map(|sample| {
                let value = f32::from(i16::from_le_bytes([sample[0], sample[1]])) / 32768.0;
                value * value
            })
            .sum::<f32>();
        let dbfs = rms_dbfs((sum_squares / count as f32).sqrt());
        let gate_db = self.gate_db.load(Ordering::Relaxed);
        let target = meter_level(dbfs);
        let above_threshold = voice_above_threshold(dbfs, gate_db);
        if above_threshold {
            self.voice_hold_frames = 3;
        } else {
            self.voice_hold_frames = self.voice_hold_frames.saturating_sub(1);
        }
        self.detected = self.voice_hold_frames > 0;

        // The bars are a rolling 416 ms amplitude history, oldest to newest.
        // A frequency spectrum would look lively but would not communicate
        // whether OmaFlow heard the speaker.
        self.bars.rotate_left(1);
        self.bars[METER_BARS - 1] = if target < 0.015 { 0.0 } else { target };

        // A standard meter uses a fast attack and a short, readable release.
        // Absolute dBFS mapping keeps normal speech well below clipping.
        let response = if target > self.smoothed { 0.72 } else { 0.38 };
        self.smoothed += (target - self.smoothed) * response;
        if self.smoothed < 0.015 {
            self.smoothed = 0.0;
        }
        self.display_dbfs = if self.smoothed == 0.0 {
            -96.0
        } else {
            METER_FLOOR_DBFS + self.smoothed * -METER_FLOOR_DBFS
        };

        let bars_changed = self
            .bars
            .iter()
            .zip(self.last_published_bars)
            .any(|(current, previous)| (*current - previous).abs() >= 0.018);
        if self.last_write.elapsed() >= Duration::from_millis(25)
            && ((self.smoothed - self.last_published).abs() >= 0.008
                || bars_changed
                || self.detected != self.last_published_detected
                || self.last_write.elapsed() >= Duration::from_millis(100))
            && let Err(error) = self.write(self.smoothed)
        {
            eprintln!("omaflow: could not update microphone meter: {error}");
        }
        above_threshold
    }

    fn write(&mut self, level: f32) -> Result<(), String> {
        let mut payload = format!(
            "{level:.3} {:.1} {}",
            self.display_dbfs,
            u8::from(self.detected)
        );
        for bar in self.bars {
            payload.push_str(&format!(" {bar:.3}"));
        }
        payload.push('\n');
        self.file
            .seek(SeekFrom::Start(0))
            .and_then(|_| self.file.write_all(payload.as_bytes()))
            .map_err(|error| error.to_string())?;
        self.last_published = level;
        self.last_published_bars = self.bars;
        self.last_published_detected = self.detected;
        self.last_write = Instant::now();
        Ok(())
    }
}

impl Drop for AudioMeter {
    fn drop(&mut self) {
        let _ = self.file.seek(SeekFrom::Start(0));
        let _ = self.file.write_all(METER_SILENCE);
    }
}

fn rms_dbfs(rms: f32) -> f32 {
    if rms <= 0.0 {
        return -96.0;
    }
    (20.0 * rms.log10()).clamp(-96.0, 0.0)
}

fn meter_level(dbfs: f32) -> f32 {
    ((dbfs - METER_FLOOR_DBFS) / -METER_FLOOR_DBFS).clamp(0.0, 1.0)
}

fn voice_above_threshold(dbfs: f32, gate_db: i32) -> bool {
    dbfs > gate_db.clamp(-70, -35) as f32
}

fn meter_path() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            env::temp_dir().join(format!("omaflow-{}", env::var("USER").unwrap_or_default()))
        })
        .join("omaflow-level")
}

pub fn reset_meter() -> Result<(), String> {
    let path = meter_path();
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&path)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    file.write_all(METER_SILENCE)
        .map_err(|error| format!("{}: {error}", path.display()))
}

struct CaptureSession {
    control: Arc<AtomicU8>,
    result: mpsc::Receiver<Result<CapturedAudio, String>>,
    worker: thread::JoinHandle<()>,
}

struct MeterPreviewSession {
    control: Arc<AtomicU8>,
    worker: thread::JoinHandle<()>,
}

impl Runtime {
    pub fn new(config: Config, meter_gate_db: i32) -> Self {
        Self {
            config,
            meter_gate_db: Arc::new(AtomicI32::new(meter_gate_db.clamp(-70, -35))),
            recording: None,
            preview: None,
            last_activity: Instant::now(),
            idle_released: false,
            release_retry_at: None,
        }
    }

    /// Marks dictation activity so the idle release timer starts over.
    pub fn touch(&mut self) {
        self.touch_at(Instant::now());
    }

    fn touch_at(&mut self, now: Instant) {
        self.last_activity = now;
        self.idle_released = false;
        self.release_retry_at = None;
    }

    /// With `keep_models_loaded` off, unloads the cleanup model and stops the
    /// managed speech server once nothing has happened for `IDLE_RELEASE`.
    /// `busy` is true while a stopped recording is still being transcribed.
    /// Both come back on the next dictation through the normal start path.
    /// A refusal is retried after `RELEASE_RETRY` rather than forgotten.
    pub fn release_idle_models(&mut self, busy: bool) {
        self.release_idle_models_at(Instant::now(), busy);
    }

    fn release_idle_models_at(&mut self, now: Instant, busy: bool) {
        if self.config.behavior.keep_models_loaded
            || !self.config.behavior.models_configured
            || self.idle_released
            || busy
            || self.recording.is_some()
            || now.duration_since(self.last_activity) < IDLE_RELEASE
            || self.release_retry_at.is_some_and(|at| now < at)
        {
            return;
        }
        let mut released = true;
        if self.config.cleanup.enabled && !unload_cleanup(&self.config) {
            released = false;
        }
        if self.config.backend.managed() {
            let stopped = Command::new("systemctl")
                .args(["--user", "stop", "omaflow-asr.service"])
                .bounded_status()
                .map(|status| status.success())
                .unwrap_or(false);
            released = released && stopped;
        }
        self.idle_released = released;
        self.release_retry_at = (!released).then(|| now + RELEASE_RETRY);
    }

    pub fn set_meter_gate(&self, gate_db: i32) {
        self.meter_gate_db
            .store(gate_db.clamp(-70, -35), Ordering::Relaxed);
    }

    pub fn set_paste_mode(&mut self, paste_mode: PasteMode) {
        self.config.behavior.paste_mode = paste_mode;
    }

    pub fn reload_config(&mut self, config: Config) -> Result<(), String> {
        if self.config.behavior.models_configured
            && (self.config.cleanup.model != config.cleanup.model
                || self.config.cleanup.endpoint != config.cleanup.endpoint
                || !config.behavior.models_configured)
        {
            let _ = unload_cleanup(&self.config);
        }
        let keep_turned_on =
            config.behavior.keep_models_loaded && !self.config.behavior.keep_models_loaded;
        let changed = self.config.backend != config.backend
            || self.config.behavior.models_configured != config.behavior.models_configured;
        let was_managed = self.config.backend.managed() && self.config.behavior.models_configured;
        let managed = config.backend.managed() && config.behavior.models_configured;
        self.set_meter_gate(config.behavior.meter_gate_db);
        self.config = config;
        if keep_turned_on {
            self.touch();
            let warm_config = self.config.clone();
            thread::spawn(move || {
                if warm_config.backend.managed() {
                    let _ = ensure_speech_server(&warm_config);
                }
                warm_cleanup(&warm_config);
            });
        }
        if changed && (was_managed || managed) {
            let action = if managed { "restart" } else { "stop" };
            let status = Command::new("systemctl")
                .args(["--user", action, "omaflow-asr.service"])
                .bounded_status()
                .map_err(|e| e.to_string())?;
            if !status.success() {
                return Err(
                    "Model settings saved, but the managed speech service could not restart".into(),
                );
            }
        }
        Ok(())
    }

    pub fn set_custom_vocabulary(&mut self, vocabulary: Vec<String>) {
        self.config.cleanup.custom_vocabulary = vocabulary;
    }

    pub fn capture_error(&mut self) -> Option<String> {
        let session = self.recording.as_ref()?;
        match session.result.try_recv() {
            Ok(Err(error)) => {
                let session = self.recording.take().unwrap();
                let _ = session.worker.join();
                Some(error)
            }
            Err(mpsc::TryRecvError::Disconnected) => {
                self.recording = None;
                Some("microphone capture worker stopped".into())
            }
            _ => None,
        }
    }

    pub fn start_preview(&mut self) -> Result<(), String> {
        if self.preview.is_some() || self.recording.is_some() {
            return Ok(());
        }
        self.preview = Some(start_meter_preview(Arc::clone(&self.meter_gate_db))?);
        Ok(())
    }

    pub fn stop_preview(&mut self) {
        if let Some(session) = self.preview.take() {
            session.control.store(1, Ordering::Release);
            let _ = session.worker.join();
        }
    }

    pub fn start(&mut self) -> Result<(), String> {
        self.stop_preview();
        if !self.config.behavior.models_configured {
            return Err("Models not configured. Open Settings → Models to finish setup.".into());
        }
        if fake_transcript_override().is_some() {
            return Ok(());
        }
        if !["nemo", "parakeet", "openai", "whisper-cpp"]
            .contains(&self.config.backend.engine.as_str())
        {
            return Err(format!(
                "unsupported ASR engine: {}",
                self.config.backend.engine
            ));
        }
        self.recording = Some(start_recording(
            &self.config,
            Arc::clone(&self.meter_gate_db),
        )?);
        Ok(())
    }

    pub fn stop(&mut self) -> Result<ProcessingSession, String> {
        let fake = fake_transcript_override();
        let recording = if fake.is_some() {
            None
        } else {
            Some(
                self.recording
                    .take()
                    .ok_or_else(|| "microphone recording is not active".to_string())?,
            )
        };
        let config = self.config.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let worker_cancel = Arc::clone(&cancel);
        let (result_tx, result_rx) = mpsc::sync_channel(1);
        let worker = thread::spawn(move || {
            let result = if let Some(text) = fake {
                thread::sleep(Duration::from_millis(120));
                if worker_cancel.load(Ordering::Acquire) {
                    Err("dictation cancelled".into())
                } else {
                    let raw_text = text.to_string_lossy().into_owned();
                    let previous = if config.cleanup.use_clipboard_context {
                        read_clipboard().unwrap_or_default()
                    } else {
                        ClipboardSnapshot::Empty
                    };
                    let window = active_window();
                    finish_transcript(
                        &config,
                        raw_text,
                        previous,
                        window.as_ref(),
                        (Duration::ZERO, Instant::now()),
                        &worker_cancel,
                    )
                }
            } else {
                stop_recording(
                    &config,
                    recording.expect("recording is present without fake input"),
                    &worker_cancel,
                )
            };
            let _ = result_tx.send(result);
        });
        Ok(ProcessingSession {
            cancel,
            result: result_rx,
            worker,
        })
    }

    pub fn cancel(&mut self) {
        if let Some(session) = self.recording.take() {
            session.control.store(2, Ordering::Release);
            let _ = session.result.recv_timeout(Duration::from_millis(750));
            let _ = session.worker.join();
        }
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        self.cancel();
        self.stop_preview();
    }
}

/// Development override: skips microphone capture and transcription and
/// treats the variable's value as the recognized text.
fn fake_transcript_override() -> Option<std::ffi::OsString> {
    std::env::var_os("OMAFLOW_FAKE_TRANSCRIPT")
}

pub fn warm_cleanup(config: &Config) {
    if !config.behavior.models_configured
        || !config.cleanup.enabled
        || !config.behavior.keep_models_loaded
    {
        return;
    }
    // Warm both the weights and GPU shader paths. An empty load request
    // leaves the first real prompt paying graph-compilation latency.
    let cancel = AtomicBool::new(false);
    for _ in 0..12 {
        if cleanup(
            config,
            "This is a short warm-up transcription.",
            "",
            None,
            &cancel,
        )
        .is_ok()
        {
            return;
        }
        thread::sleep(Duration::from_millis(500));
    }
}

fn start_recording(
    config: &Config,
    meter_gate_db: Arc<AtomicI32>,
) -> Result<CaptureSession, String> {
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let (result_tx, result_rx) = mpsc::sync_channel(1);
    let control = Arc::new(AtomicU8::new(0));
    let worker_control = Arc::clone(&control);
    let config = config.clone();

    let worker = thread::spawn(move || {
        let result = capture_audio(&config, &worker_control, &ready_tx, meter_gate_db);
        let _ = result_tx.send(result);
    });

    match ready_rx.recv_timeout(Duration::from_secs(12)) {
        Ok(Ok(())) => Ok(CaptureSession {
            control,
            result: result_rx,
            worker,
        }),
        Ok(Err(error)) => {
            control.store(2, Ordering::Release);
            let _ = worker.join();
            Err(error)
        }
        Err(_) => {
            control.store(2, Ordering::Release);
            let _ = worker.join();
            Err("timed out starting PipeWire microphone capture".into())
        }
    }
}

fn capture_audio(
    config: &Config,
    control: &AtomicU8,
    ready: &mpsc::SyncSender<Result<(), String>>,
    meter_gate_db: Arc<AtomicI32>,
) -> Result<CapturedAudio, String> {
    let mut capture = match start_audio_capture() {
        Ok(capture) => capture,
        Err(error) => {
            let _ = ready.send(Err(error.clone()));
            return Err(error);
        }
    };
    let mut audio = match capture.stdout.take() {
        Some(audio) => audio,
        None => {
            stop_audio_capture(&mut capture);
            let error = "PipeWire recorder did not expose audio".to_string();
            let _ = ready.send(Err(error.clone()));
            return Err(error);
        }
    };
    if let Err(error) = crate::process::nonblocking(&audio) {
        stop_audio_capture(&mut capture);
        let message = format!("could not configure microphone capture: {error}");
        let _ = ready.send(Err(message.clone()));
        return Err(message);
    }
    let mut meter = match AudioMeter::open(meter_gate_db) {
        Ok(meter) => meter,
        Err(error) => {
            stop_audio_capture(&mut capture);
            let error = format!("could not initialize microphone meter: {error}");
            let _ = ready.send(Err(error.clone()));
            return Err(error);
        }
    };
    let _ = ready.send(Ok(()));

    // One minute of mono 16 kHz S16 audio is only 1.92 MB. Keeping PCM in
    // memory avoids filesystem latency and lets curl stream a WAV directly to
    // the already-warm local CUDA server when recording stops.
    let mut pcm = Vec::with_capacity(1_920_000);
    let mut voiced_frames = 0;
    let mut buffer = [0_u8; 1024];
    // Finished segments go to one sequential worker so their order is kept
    // and the speech server sees at most one live request at a time.
    let live = config.behavior.models_configured && config.backend.live_segment_seconds > 0;
    let mut segmenter = Segmenter::new(
        if live {
            config.backend.live_segment_seconds
        } else {
            0
        },
        &config.backend.live_segment_tiers,
    );
    let live_cancel = Arc::new(AtomicBool::new(false));
    let (segment_tx, segment_rx) = mpsc::channel::<Option<Vec<u8>>>();
    let live_worker = live.then(|| {
        let config = config.clone();
        let cancel = Arc::clone(&live_cancel);
        thread::spawn(move || {
            let mut texts = Vec::new();
            for segment in segment_rx {
                let result = match segment {
                    None => Ok(String::new()),
                    Some(pcm) => ensure_speech_server(&config)
                        .and_then(|_| transcribe_pcm(&config, &pcm, &cancel)),
                };
                let failed = result.is_err();
                texts.push(result);
                if failed {
                    break;
                }
            }
            texts
        })
    });
    let mut segment_count = 0_usize;
    while control.load(Ordering::Acquire) == 0 {
        let count = match audio.read(&mut buffer) {
            Ok(0) => {
                stop_audio_capture(&mut capture);
                return Err("PipeWire microphone stream ended".into());
            }
            Ok(count) => count,
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(8));
                continue;
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(error) => {
                stop_audio_capture(&mut capture);
                return Err(format!("could not read microphone audio: {error}"));
            }
        };
        let voiced = meter.update(&buffer[..count]);
        if voiced {
            voiced_frames += 1;
        }
        pcm.extend_from_slice(&buffer[..count]);
        if let Some((range, segment_voiced)) = segmenter.observe(count, voiced) {
            // Silence-only segments never reach the ASR; they cannot hold words.
            let payload = (segment_voiced >= 2).then(|| pcm[range].to_vec());
            if segment_tx.send(payload).is_ok() {
                segment_count += 1;
            }
        }
    }

    stop_audio_capture(&mut capture);
    drop(segment_tx);
    if control.load(Ordering::Acquire) == 2 {
        live_cancel.store(true, Ordering::Release);
        if let Some(worker) = live_worker {
            let _ = worker.join();
        }
        return Err("recording cancelled".into());
    }
    let mut prefix = Vec::new();
    let mut prefix_len = 0;
    if let Some(worker) = live_worker {
        let texts = worker.join().unwrap_or_default();
        if texts.len() == segment_count && texts.iter().all(Result::is_ok) {
            prefix = texts
                .into_iter()
                .map(|text| text.unwrap_or_default())
                .collect();
            prefix_len = segmenter.segment_start;
        } else if let Some(Err(error)) = texts.iter().find(|text| text.is_err()) {
            eprintln!("omaflow: live transcription unavailable, transcribing after stop: {error}");
        }
    }
    Ok(CapturedAudio {
        pcm,
        voiced_frames,
        prefix,
        prefix_len,
        tail_voiced_frames: segmenter.voiced_frames,
    })
}

fn start_meter_preview(meter_gate_db: Arc<AtomicI32>) -> Result<MeterPreviewSession, String> {
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let control = Arc::new(AtomicU8::new(0));
    let worker_control = Arc::clone(&control);
    let worker = thread::spawn(move || {
        if let Err(error) = capture_meter_preview(&worker_control, &ready_tx, meter_gate_db) {
            eprintln!("omaflow: microphone preview stopped: {error}");
        }
    });

    match ready_rx.recv_timeout(Duration::from_secs(4)) {
        Ok(Ok(())) => Ok(MeterPreviewSession { control, worker }),
        Ok(Err(error)) => {
            control.store(1, Ordering::Release);
            let _ = worker.join();
            Err(error)
        }
        Err(_) => {
            control.store(1, Ordering::Release);
            let _ = worker.join();
            Err("timed out starting microphone preview".into())
        }
    }
}

fn capture_meter_preview(
    control: &AtomicU8,
    ready: &mpsc::SyncSender<Result<(), String>>,
    meter_gate_db: Arc<AtomicI32>,
) -> Result<(), String> {
    let mut capture = match start_audio_capture() {
        Ok(capture) => capture,
        Err(error) => {
            let _ = ready.send(Err(error.clone()));
            return Err(error);
        }
    };
    let mut audio = match capture.stdout.take() {
        Some(audio) => audio,
        None => {
            stop_audio_capture(&mut capture);
            let error = "PipeWire recorder did not expose preview audio".to_string();
            let _ = ready.send(Err(error.clone()));
            return Err(error);
        }
    };
    if let Err(error) = crate::process::nonblocking(&audio) {
        stop_audio_capture(&mut capture);
        let message = format!("could not configure microphone capture: {error}");
        let _ = ready.send(Err(message.clone()));
        return Err(message);
    }
    let mut meter = match AudioMeter::open(meter_gate_db) {
        Ok(meter) => meter,
        Err(error) => {
            stop_audio_capture(&mut capture);
            let error = format!("could not initialize microphone preview: {error}");
            let _ = ready.send(Err(error.clone()));
            return Err(error);
        }
    };
    let _ = ready.send(Ok(()));

    let mut buffer = [0_u8; 1024];
    while control.load(Ordering::Acquire) == 0 {
        let count = match audio.read(&mut buffer) {
            Ok(0) => {
                stop_audio_capture(&mut capture);
                return Err("PipeWire microphone preview ended".into());
            }
            Ok(count) => count,
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(8));
                continue;
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(error) => {
                stop_audio_capture(&mut capture);
                return Err(format!("could not read microphone preview: {error}"));
            }
        };
        meter.update(&buffer[..count]);
    }

    stop_audio_capture(&mut capture);
    Ok(())
}

pub(crate) fn ensure_speech_server(config: &Config) -> Result<(), String> {
    // External servers own their lifecycle. Send the request directly so its
    // HTTP error is useful, rather than starting an unrelated local service.
    if !config.behavior.models_configured || !config.backend.managed() {
        return Ok(());
    }
    if speech_server_ready(&config.backend) {
        return Ok(());
    }
    installed_speech_model(config.backend.nemo_model())?;

    let started = Command::new("systemctl")
        .args(["--user", "start", "omaflow-asr.service"])
        .bounded_status()
        .map_err(|error| format!("could not start omaflow-asr.service: {error}"))?;
    if !started.success() {
        return Err("omaflow-asr.service did not start".into());
    }

    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if speech_server_ready(&config.backend) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(format!(
        "could not connect to the managed speech server at {}",
        config.backend.endpoint
    ))
}

pub fn speech_server_ready(config: &crate::config::Backend) -> bool {
    let endpoint = if !config.health_endpoint.is_empty() {
        config.health_endpoint.clone()
    } else if config.managed() {
        let Some((base, _)) = config.endpoint.split_once("/v1/") else {
            return false;
        };
        format!("{base}/health")
    } else if config.engine == "whisper-cpp" {
        // whisper-server registers only POST /inference, so probing the
        // transcription endpoint answers 404 forever. It does serve /health.
        let Some(origin) = endpoint_origin(&config.endpoint) else {
            return false;
        };
        format!("{origin}/health")
    } else {
        config.endpoint.clone()
    };
    let auth = crate::process::CurlAuth::new(&config.api_key);
    auth.apply(&mut Command::new("curl"))
        .args([
            "--silent",
            "--max-time",
            "1",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            &endpoint,
        ])
        .bounded_output()
        .ok()
        .is_some_and(|out| {
            let code = String::from_utf8_lossy(&out.stdout);
            out.status.success()
                && (code.starts_with('2') || (config.health_endpoint.is_empty() && code == "405"))
        })
}

/// The scheme and authority of a URL, without its path.
pub(crate) fn endpoint_origin(endpoint: &str) -> Option<String> {
    let (scheme, rest) = endpoint.split_once("://")?;
    let authority = rest
        .split(['/', '?', '#'])
        .next()
        .filter(|a| !a.is_empty())?;
    Some(format!("{scheme}://{authority}"))
}

fn start_audio_capture() -> Result<Child, String> {
    Command::new("pw-cat")
        .args([
            "--record",
            "--raw",
            "--format",
            "s16",
            "--rate",
            "16000",
            "--channels",
            "1",
            "--latency",
            "32ms",
            "--media-category",
            "Capture",
            "--media-role",
            "Communication",
            "-",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("could not start PipeWire microphone capture: {error}"))
}

fn stop_audio_capture(capture: &mut Child) {
    let _ = capture.kill();
    let _ = capture.wait();
}

fn stop_recording(
    config: &Config,
    session: CaptureSession,
    cancel: &AtomicBool,
) -> Result<StopOutcome, String> {
    let total_started = Instant::now();
    session.control.store(1, Ordering::Release);
    let window = active_window();
    let backend_started = Instant::now();
    let previous = if config.cleanup.use_clipboard_context {
        read_clipboard().unwrap_or_default()
    } else {
        ClipboardSnapshot::Empty
    };

    let captured = session
        .result
        .recv_timeout(Duration::from_millis(config.backend.status_timeout_ms))
        .map_err(|_| "timed out finalizing microphone capture".to_string())??;
    let _ = session.worker.join();
    // Two 32 ms frames are enough for short words such as "yes", while taps,
    // room noise and key clicks never reach the ASR or cleanup model.
    if captured.voiced_frames < 2 {
        return Ok(StopOutcome::NoSpeech);
    }
    if cancel.load(Ordering::Acquire) {
        return Err("dictation cancelled".into());
    }
    ensure_speech_server(config)?;
    let raw_text = if captured.prefix_len > 0 && captured.prefix_len <= captured.pcm.len() {
        let tail = &captured.pcm[captured.prefix_len..];
        let mut parts: Vec<String> = captured
            .prefix
            .iter()
            .map(|text| text.trim().to_string())
            .filter(|text| !text.is_empty())
            .collect();
        if !tail.is_empty() && captured.tail_voiced_frames >= 2 {
            let text = transcribe_pcm(config, tail, cancel)?;
            if !text.trim().is_empty() {
                parts.push(text.trim().to_string());
            }
        }
        eprintln!(
            "omaflow: live segments={} tail={}ms",
            captured.prefix.len(),
            tail.len() / (BYTES_PER_SECOND / 1000)
        );
        if parts.is_empty() {
            return Err("speech server returned an empty transcript".into());
        }
        parts.join(" ")
    } else {
        transcribe_speech(config, &captured.pcm, cancel)?
    };
    let backend_elapsed = backend_started.elapsed();

    finish_transcript(
        config,
        raw_text,
        previous,
        window.as_ref(),
        (backend_elapsed, total_started),
        cancel,
    )
}

/// Runs a WAV file through the live segmenter exactly as the microphone path
/// would, transcribes the whole file and every segment, and returns both so a
/// segmentation rule can be judged against a checked transcript.
pub(crate) fn segment_file(config: &Config, path: &Path) -> Result<Value, String> {
    let bytes = fs::read(path).map_err(|error| format!("{}: {error}", path.display()))?;
    if bytes.len() < 44 || &bytes[..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("expected a RIFF WAVE file".into());
    }
    let channels = u16::from_le_bytes([bytes[22], bytes[23]]);
    let rate = u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]);
    let bits = u16::from_le_bytes([bytes[34], bytes[35]]);
    if channels != 1 || rate != 16_000 || bits != 16 {
        return Err(format!(
            "expected 16 kHz mono 16-bit PCM, got {rate} Hz, {channels} channel(s), {bits} bit"
        ));
    }
    let data_at = bytes
        .windows(4)
        .position(|window| window == b"data")
        .ok_or("WAV has no data chunk")?
        + 8;
    let pcm = &bytes[data_at..];
    let mut meter = AudioMeter::open(Arc::new(AtomicI32::new(config.behavior.meter_gate_db)))?;
    let mut segmenter = Segmenter::new(
        config.backend.live_segment_seconds,
        &config.backend.live_segment_tiers,
    );
    let cancel = AtomicBool::new(false);
    ensure_speech_server(config)?;
    let seconds = |bytes: usize| bytes as f64 / BYTES_PER_SECOND as f64;
    let mut segments = Vec::new();
    for chunk in pcm.chunks(1024) {
        let voiced = meter.update(chunk);
        if let Some((range, voiced_frames)) = segmenter.observe(chunk.len(), voiced) {
            let text = if voiced_frames >= 2 {
                transcribe_pcm(config, &pcm[range.clone()], &cancel)?
            } else {
                String::new()
            };
            segments.push(serde_json::json!({
                "start": seconds(range.start),
                "end": seconds(range.end),
                "text": text,
            }));
        }
    }
    let tail_start = segmenter.segment_start;
    let tail = if tail_start < pcm.len() {
        transcribe_pcm(config, &pcm[tail_start..], &cancel)?
    } else {
        String::new()
    };
    segments.push(serde_json::json!({
        "start": seconds(tail_start),
        "end": seconds(pcm.len()),
        "text": tail,
    }));
    let whole = transcribe_pcm(config, pcm, &cancel)?;
    Ok(serde_json::json!({
        "seconds": seconds(pcm.len()),
        "live_segment_seconds": config.backend.live_segment_seconds,
        "live_segment_tiers": config.backend.live_segment_tiers,
        "whole": whole,
        "segments": segments,
    }))
}

pub(crate) fn transcribe_speech(
    config: &Config,
    pcm: &[u8],
    cancel: &AtomicBool,
) -> Result<String, String> {
    let text = transcribe_pcm(config, pcm, cancel)?;
    if text.trim().is_empty() {
        return Err("speech server returned an empty transcript".into());
    }
    Ok(text)
}

/// One transcription request; an empty transcript is a valid answer here.
fn transcribe_pcm(config: &Config, pcm: &[u8], cancel: &AtomicBool) -> Result<String, String> {
    if pcm.is_empty() {
        return Err("recording contained no microphone audio".into());
    }
    let header = wav_header(pcm.len())?;
    let timeout_seconds = config.backend.status_timeout_ms.div_ceil(1_000).max(1);
    let timeout = timeout_seconds.to_string();
    let model = format!("model={}", config.backend.model);
    let language = format!("language={}", config.backend.language);
    let auth = crate::process::CurlAuth::new(&config.backend.api_key);
    let mut command = Command::new("curl");
    auth.apply(&mut command)
        .args([
            "--silent",
            "--show-error",
            "--fail-with-body",
            "--max-time",
            &timeout,
            "--form",
            "file=@-;filename=dictation.wav;type=audio/wav",
            "--form-string",
            "response_format=json",
            &config.backend.endpoint,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if config.backend.engine == "openai" {
        command.args(["--form-string", &model]);
    }
    if config.backend.language != "auto" || config.backend.engine != "openai" {
        command.args(["--form-string", &language]);
    }
    let mut wav = Vec::with_capacity(header.len() + pcm.len());
    wav.extend_from_slice(&header);
    wav.extend_from_slice(pcm);
    let output = crate::process::run(
        &mut command,
        &wav,
        cancel,
        Duration::from_secs(timeout_seconds),
    )
    .map_err(|error| format!("local transcription: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "speech server request failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let body: Value = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("invalid speech server response: {error}"))?;
    body.get("text")
        .and_then(Value::as_str)
        .map(str::trim)
        .map(ToOwned::to_owned)
        .ok_or_else(|| "invalid speech server response: missing text".into())
}

fn wav_header(pcm_bytes: usize) -> Result<[u8; 44], String> {
    let data_size = u32::try_from(pcm_bytes)
        .map_err(|_| "recording is too large for a standard WAV file".to_string())?;
    let riff_size = data_size
        .checked_add(36)
        .ok_or_else(|| "recording is too large for a standard WAV file".to_string())?;
    let mut header = [0_u8; 44];
    header[0..4].copy_from_slice(b"RIFF");
    header[4..8].copy_from_slice(&riff_size.to_le_bytes());
    header[8..12].copy_from_slice(b"WAVE");
    header[12..16].copy_from_slice(b"fmt ");
    header[16..20].copy_from_slice(&16_u32.to_le_bytes());
    header[20..22].copy_from_slice(&1_u16.to_le_bytes());
    header[22..24].copy_from_slice(&1_u16.to_le_bytes());
    header[24..28].copy_from_slice(&16_000_u32.to_le_bytes());
    header[28..32].copy_from_slice(&32_000_u32.to_le_bytes());
    header[32..34].copy_from_slice(&2_u16.to_le_bytes());
    header[34..36].copy_from_slice(&16_u16.to_le_bytes());
    header[36..40].copy_from_slice(b"data");
    header[40..44].copy_from_slice(&data_size.to_le_bytes());
    Ok(header)
}

fn finish_transcript(
    config: &Config,
    raw_text: String,
    previous: ClipboardSnapshot,
    window: Option<&Value>,
    timing: (Duration, Instant),
    cancel: &AtomicBool,
) -> Result<StopOutcome, String> {
    let (backend_elapsed, total_started) = timing;
    if cancel.load(Ordering::Acquire) {
        return Err("dictation cancelled".into());
    }
    let prepare_started = Instant::now();
    let mut text = vocabulary::apply(&raw_text, &config.cleanup.custom_vocabulary);
    let prepare_elapsed = prepare_started.elapsed();
    if text.trim().is_empty() {
        return Err("transcription contained no text".into());
    }
    let cleanup_started = Instant::now();
    let mut cleanup_warning = String::new();
    if config.cleanup.enabled {
        match cleanup(config, &text, previous.text_context(), window, cancel) {
            Ok(cleaned) => text = cleaned,
            Err(error) => {
                eprintln!("omaflow: cleanup unavailable, using raw transcript: {error}");
                cleanup_warning = crate::cleanup::cleanup_warning_text(&error);
            }
        }
    }
    let cleanup_elapsed = cleanup_started.elapsed();
    if text.trim().is_empty() {
        return Ok(StopOutcome::NoSpeech);
    }
    if cancel.load(Ordering::Acquire) {
        return Err("dictation cancelled".into());
    }
    let output_started = Instant::now();
    let delivery_guard = DELIVERY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if cancel.load(Ordering::Acquire) {
        return Err("dictation cancelled".into());
    }
    let delivery_error = set_clipboard(text.as_bytes(), None)
        .err()
        .unwrap_or_default();

    // Wayland cannot universally confirm that an application accepted pasted
    // text. Send the shortcut to the active surface and keep this transcript
    // on the clipboard in case the app ignores it or no editor has focus.
    let pasted = !cancel.load(Ordering::Acquire)
        && delivery_error.is_empty()
        && config.behavior.paste_mode != PasteMode::Clipboard
        && active_window_matches(window)
        && paste(config.behavior.paste_mode, window).is_ok();
    drop(delivery_guard);
    let output_elapsed = output_started.elapsed();
    eprintln!(
        "omaflow: timing words={} backend={}ms prepare={}ms cleanup={}ms output={}ms total={}ms",
        raw_text.split_whitespace().count(),
        backend_elapsed.as_millis(),
        prepare_elapsed.as_millis(),
        cleanup_elapsed.as_millis(),
        output_elapsed.as_millis(),
        total_started.elapsed().as_millis(),
    );
    Ok(StopOutcome::Transcript(Transcript {
        text,
        raw_text,
        pasted,
        delivery_error,
        cleanup_warning,
    }))
}

pub fn copy_text(text: &str) -> Result<(), String> {
    let _guard = DELIVERY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    set_clipboard(text.as_bytes(), None)
}

pub fn paste_text_now(text: &str, mode: PasteMode) -> Result<(), String> {
    let _guard = DELIVERY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    set_clipboard(text.as_bytes(), None)?;
    if mode == PasteMode::Clipboard {
        return Ok(());
    }
    // The panel defers this command until its fade has released keyboard
    // focus. Keep one final compositor frame between clipboard ownership and
    // the synthetic paste shortcut.
    thread::sleep(Duration::from_millis(80));
    let window = active_window();
    let window = window.ok_or_else(|| "no focused window".to_string())?;
    focus_window(&window)?;
    // Layer-shell focus changes are asynchronous. Wait for Hyprland to
    // deliver the focus commit before injecting the paste chord.
    thread::sleep(Duration::from_millis(200));
    if !active_window_matches(Some(&window)) {
        return Err("Focus changed; text remains on the clipboard".into());
    }
    paste(mode, Some(&window))
}

fn focus_window(window: &Value) -> Result<(), String> {
    let address = window
        .get("address")
        .and_then(Value::as_str)
        .filter(|address| !address.is_empty())
        .ok_or_else(|| "focused window has no address".to_string())?;
    let dispatcher = format!(r#"hl.dsp.focus({{ window = "address:{address}" }})"#);
    let output = Command::new("hyprctl")
        .args(["dispatch", &dispatcher])
        .bounded_output()
        .map_err(|error| format!("could not restore focused window: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err("Hyprland could not restore the focused window".into())
    }
}

fn set_clipboard(data: &[u8], mime_type: Option<&str>) -> Result<(), String> {
    let mut command = Command::new("wl-copy");
    if let Some(mime_type) = mime_type {
        command.args(["--type", mime_type]);
    }
    command.stdout(Stdio::null()).stderr(Stdio::null());
    let status = crate::process::run(
        &mut command,
        data,
        &AtomicBool::new(false),
        Duration::from_secs(3),
    )?
    .status;
    if status.success() {
        Ok(())
    } else {
        Err("wl-copy failed".into())
    }
}

fn read_clipboard() -> Result<ClipboardSnapshot, String> {
    let types_output = Command::new("wl-paste")
        .arg("--list-types")
        .bounded_output()
        .map_err(|error| format!("could not inspect clipboard: {error}"))?;
    if !types_output.status.success() {
        return Ok(ClipboardSnapshot::Empty);
    }
    let types_text = String::from_utf8_lossy(&types_output.stdout);
    let types: Vec<&str> = types_text
        .lines()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .collect();
    let Some(mime_type) = preferred_clipboard_type(&types) else {
        return Ok(ClipboardSnapshot::Empty);
    };
    if !is_text_mime(mime_type) {
        return Ok(ClipboardSnapshot::Empty);
    }
    let output = Command::new("wl-paste")
        .args(["--type", mime_type])
        .bounded_output()
        .map_err(|error| format!("could not read clipboard as {mime_type}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "could not read clipboard as {mime_type}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(ClipboardSnapshot::Content {
        mime_type: mime_type.to_string(),
        data: output.stdout,
    })
}

fn preferred_clipboard_type<'a>(types: &'a [&'a str]) -> Option<&'a str> {
    [
        "text/plain;charset=utf-8",
        "text/plain",
        "UTF8_STRING",
        "STRING",
        "TEXT",
        "text/uri-list",
    ]
    .into_iter()
    .find_map(|preferred| {
        types
            .iter()
            .copied()
            .find(|mime_type| mime_type.eq_ignore_ascii_case(preferred))
    })
}

fn is_text_mime(mime_type: &str) -> bool {
    mime_type.starts_with("text/")
        || ["UTF8_STRING", "STRING", "TEXT"]
            .iter()
            .any(|text_type| mime_type.eq_ignore_ascii_case(text_type))
}

fn paste(mode: PasteMode, window: Option<&Value>) -> Result<(), String> {
    let (modifier, key) = paste_shortcut(mode, window);
    send_hyprland_shortcut(modifier, key)
}

fn send_hyprland_shortcut(modifier: &str, key: &str) -> Result<(), String> {
    // Keep down and delayed up in one Hyprland Lua evaluation. Separate
    // `hyprctl` calls lose the synthetic key between Lua contexts, which can
    // leave the shortcut pressed or make the release fail.
    let dispatcher = format!(
        "function() \
         hl.dispatch(hl.dsp.send_key_state({{ mods = \"{modifier}\", key = \"{key}\", state = \"down\" }})); \
         hl.timer(function() \
           hl.dispatch(hl.dsp.send_key_state({{ mods = \"{modifier}\", key = \"{key}\", state = \"up\" }})) \
         end, {{ timeout = 50, type = \"oneshot\" }}) \
         end"
    );
    let output = Command::new("hyprctl")
        .args(["dispatch", &dispatcher])
        .bounded_output()
        .map_err(|error| format!("could not ask Hyprland to paste: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err("Hyprland could not send the paste shortcut".into())
    }
}

fn paste_shortcut(mode: PasteMode, window: Option<&Value>) -> (&'static str, &'static str) {
    match mode {
        PasteMode::Clipboard | PasteMode::CtrlV => ("CTRL", "V"),
        PasteMode::ShiftInsert => ("SHIFT", "Insert"),
        PasteMode::Auto if window_has_tag(window, "terminal") => ("SHIFT", "Insert"),
        PasteMode::Auto => ("CTRL", "V"),
    }
}

fn window_has_tag(window: Option<&Value>, expected: &str) -> bool {
    window
        .and_then(|window| window.get("tags"))
        .and_then(Value::as_array)
        .is_some_and(|tags| {
            tags.iter()
                .filter_map(Value::as_str)
                .any(|tag| tag.trim_end_matches('*').eq_ignore_ascii_case(expected))
        })
}

fn active_window() -> Option<Value> {
    Command::new("hyprctl")
        .args(["activewindow", "-j"])
        .bounded_output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| serde_json::from_slice(&output.stdout).ok())
}

fn active_window_matches(expected: Option<&Value>) -> bool {
    let expected = expected
        .and_then(|window| window.get("address"))
        .and_then(Value::as_str)
        .filter(|address| !address.is_empty());
    let current = active_window();
    let current = current
        .as_ref()
        .and_then(|window| window.get("address"))
        .and_then(Value::as_str)
        .filter(|address| !address.is_empty());
    expected.is_some() && expected == current
}

// Resolve only files already on disk. Passing a repository name to NeMo can
// trigger an implicit download, even though OmaFlow has no download controls.
fn installed_speech_model(model: &str) -> Result<PathBuf, String> {
    let supplied = PathBuf::from(model);
    if supplied.is_file() {
        return supplied.canonicalize().map_err(|e| e.to_string());
    }
    let cache = env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".cache"));
    let directory = cache.join("nemo-speech/models").join(model);
    let mut candidates = Vec::new();
    if let Ok(revisions) = fs::read_dir(directory) {
        for revision in revisions.flatten() {
            if let Ok(files) = fs::read_dir(revision.path()) {
                for file in files.flatten() {
                    let path = file.path();
                    if path.is_file() && path.extension().is_some_and(|ext| ext == "gguf") {
                        candidates.push(path);
                    }
                }
            }
        }
    }
    if candidates.len() == 1 {
        return candidates
            .remove(0)
            .canonicalize()
            .map_err(|e| e.to_string());
    }
    Err("Speech model is not configured as a unique installed file. Install it separately and enter its absolute GGUF path in Settings → Models.".into())
}

/// Foreground entry point for omaflow-asr.service: resolves the configured
/// model and replaces this process with the NeMo-Speech server.
pub fn serve_speech() -> Result<(), String> {
    use std::os::unix::process::CommandExt as _;
    let config = Config::load()?;
    if !config.behavior.models_configured || !config.backend.managed() {
        return Ok(());
    }
    let (host, port) = config.backend.listen_address()?;
    let model_path = installed_speech_model(config.backend.nemo_model())?;
    let model = model_path
        .to_str()
        .ok_or("Speech model path must be valid UTF-8")?;
    let binary = PathBuf::from(env::var_os("HOME").ok_or("HOME is not set")?)
        .join(".local/lib/nemo-speech/bin/nemo-speech");
    let error = Command::new(binary)
        .args([
            "--quiet",
            "serve",
            "--asr-model",
            model,
            "--backend",
            &config.backend.device,
            "--host",
            host,
            "--port",
            &port.to_string(),
            "--threads",
            "2",
            "--no-ui",
        ])
        .exec();
    Err(format!("Could not start configured NeMo model: {error}"))
}

/// Asks Ollama to drop the cleanup model now. True when the server agreed.
pub fn unload_cleanup(config: &Config) -> bool {
    let payload =
        serde_json::json!({"model":config.cleanup.model,"messages":[],"keep_alive":0}).to_string();
    let auth = crate::process::CurlAuth::new(&config.cleanup.api_key);
    auth.apply(&mut Command::new("curl"))
        .args([
            "-fsS",
            "--max-time",
            "3",
            "-o",
            "/dev/null",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            &payload,
            &config.cleanup.endpoint,
        ])
        .bounded_status()
        .map(|status| status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use crate::config::PasteMode;
    use serde_json::json;

    use super::{
        ClipboardSnapshot, meter_level, paste_shortcut, preferred_clipboard_type, rms_dbfs,
        voice_above_threshold, wav_header,
    };

    fn rms_at(dbfs: f32) -> f32 {
        10.0_f32.powf(dbfs / 20.0)
    }

    #[test]
    fn segmenter_cuts_only_in_a_pause_after_enough_audio() {
        use super::{BYTES_PER_SECOND, Segmenter};
        let mut segmenter = Segmenter::new(5, &[]);
        let frame = 1024;
        // Ten seconds of continuous speech never cuts.
        for _ in 0..(10 * BYTES_PER_SECOND / frame) {
            assert!(segmenter.observe(frame, true).is_none());
        }
        // A 600 ms pause is too short; at 700 ms the segment closes mid-pause.
        let mut cut = None;
        for _ in 0..40 {
            cut = segmenter.observe(frame, false);
            if cut.is_some() {
                break;
            }
        }
        let (range, voiced) = cut.expect("cut after a pause");
        assert_eq!(range.start, 0);
        assert!(range.end % 2 == 0);
        assert!(range.end > 10 * BYTES_PER_SECOND);
        assert!(range.end < segmenter.total);
        assert!(voiced > 300);
        // The next segment starts at the cut and needs its own five seconds.
        assert_eq!(segmenter.segment_start, range.end);
        for _ in 0..40 {
            assert!(segmenter.observe(frame, false).is_none());
        }
        assert!(Segmenter::new(0, &[]).observe(frame, false).is_none());
    }

    #[test]
    fn segmenter_tiers_accept_shorter_pauses_as_a_segment_grows() {
        use super::{BYTES_PER_SECOND, Segmenter};
        use crate::config::SegmentTier;
        let tiers = [
            SegmentTier {
                seconds: 8,
                pause_ms: 400,
            },
            SegmentTier {
                seconds: 12,
                pause_ms: 250,
            },
        ];
        let frame = 1024;
        let speak = |segmenter: &mut Segmenter, seconds: usize| {
            for _ in 0..(seconds * BYTES_PER_SECOND / frame) {
                assert!(segmenter.observe(frame, true).is_none());
            }
        };
        let pause = |segmenter: &mut Segmenter, ms: usize| {
            let mut cut = None;
            for _ in 0..(ms * BYTES_PER_SECOND / 1000 / frame) {
                cut = segmenter.observe(frame, false);
                if cut.is_some() {
                    break;
                }
            }
            cut
        };
        let mut segmenter = Segmenter::new(5, &tiers);
        // Six seconds in, a 450 ms pause is short of the 700 ms base rule.
        speak(&mut segmenter, 6);
        assert!(pause(&mut segmenter, 450).is_none());
        // Past the 8 s tier the same pause closes the segment.
        speak(&mut segmenter, 3);
        assert!(pause(&mut segmenter, 450).is_some());
        // A fresh segment past 12 s needs only 250 ms: 200 ms leaves it open,
        // another 100 ms closes it.
        speak(&mut segmenter, 13);
        assert!(pause(&mut segmenter, 200).is_none());
        assert!(pause(&mut segmenter, 100).is_some());
    }

    /// A one-shot HTTP server answering `status` to the first request, so the
    /// idle release can be driven without Ollama. Returns the endpoint.
    fn one_shot_http(status: &'static str) -> String {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!(
            "http://127.0.0.1:{}/api/chat",
            listener.local_addr().unwrap().port()
        );
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0; 4096];
            let _ = stream.read(&mut buffer);
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"
            );
        });
        endpoint
    }

    #[test]
    fn idle_release_waits_skips_busy_and_retries_a_refusal() {
        use super::{IDLE_RELEASE, RELEASE_RETRY, Runtime};
        use std::time::{Duration, Instant};
        let mut config = crate::config::Config::default();
        config.behavior.models_configured = true;
        config.behavior.keep_models_loaded = false;
        config.cleanup.enabled = true;
        // An external speech server is never stopped, so only Ollama matters.
        config.backend.engine = "openai".into();
        let start = Instant::now();

        // Ollama refuses: not released, and no second attempt before the backoff.
        config.cleanup.endpoint = one_shot_http("500 Internal Server Error");
        let mut runtime = Runtime::new(config.clone(), -60);
        runtime.touch_at(start);
        runtime.release_idle_models_at(start + IDLE_RELEASE - Duration::from_secs(1), false);
        assert!(!runtime.idle_released);
        assert!(
            runtime.release_retry_at.is_none(),
            "too early to have tried"
        );
        runtime.release_idle_models_at(start + IDLE_RELEASE, true);
        assert!(runtime.release_retry_at.is_none(), "busy must not try");
        runtime.release_idle_models_at(start + IDLE_RELEASE, false);
        assert!(!runtime.idle_released);
        let retry_at = runtime.release_retry_at.expect("refusal schedules a retry");
        assert_eq!(retry_at, start + IDLE_RELEASE + RELEASE_RETRY);

        // The retry succeeds once Ollama agrees, and activity resets everything.
        runtime.config.cleanup.endpoint = one_shot_http("200 OK");
        runtime.release_idle_models_at(retry_at - Duration::from_secs(1), false);
        assert!(!runtime.idle_released, "before the backoff nothing is sent");
        runtime.release_idle_models_at(retry_at, false);
        assert!(runtime.idle_released);
        runtime.touch_at(retry_at + Duration::from_secs(1));
        assert!(!runtime.idle_released);
        assert!(runtime.release_retry_at.is_none());

        // Keeping models loaded never releases, however idle.
        runtime.config.behavior.keep_models_loaded = true;
        runtime.release_idle_models_at(retry_at + IDLE_RELEASE * 10, false);
        assert!(!runtime.idle_released);
    }

    #[test]
    fn speech_adapters_send_expected_multipart_fields() {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::atomic::AtomicBool;
        use std::time::Duration;
        for engine in ["nemo", "openai", "whisper-cpp"] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let server = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0; 4096];
                loop {
                    let count = stream.read(&mut buffer).unwrap();
                    assert!(count > 0);
                    bytes.extend_from_slice(&buffer[..count]);
                    if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&bytes[..end]).to_lowercase();
                        let length: usize = headers
                            .lines()
                            .find_map(|l| l.strip_prefix("content-length:"))
                            .unwrap()
                            .trim()
                            .parse()
                            .unwrap();
                        if bytes.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                let body = r#"{"text":"A recorded sentence."}"#;
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                )
                .unwrap();
                bytes
            });
            let mut config = crate::config::Config::default();
            config.backend.engine = engine.into();
            config.backend.endpoint = format!("http://127.0.0.1:{port}/transcribe");
            config.backend.model = "@literal-model-name".into();
            let text =
                super::transcribe_speech(&config, &[0; 3200], &AtomicBool::new(false)).unwrap();
            assert_eq!(text, "A recorded sentence.");
            let bytes = server.join().unwrap();
            let request = String::from_utf8_lossy(&bytes);
            assert!(request.contains("RIFF"));
            assert!(request.contains("name=\"response_format\"\r\n\r\njson"));
            assert_eq!(request.contains("name=\"model\""), engine == "openai");
            assert_eq!(request.contains("name=\"language\""), engine != "openai");
            if engine == "openai" {
                assert!(request.contains("@literal-model-name"));
            }
        }
    }

    #[test]
    fn microphone_meter_is_absolute_dbfs_not_adaptive_peak_normalized() {
        assert_eq!(meter_level(rms_dbfs(0.0)), 0.0);
        assert_eq!(meter_level(-72.0), 0.0);
        assert!((0.57..0.59).contains(&meter_level(-30.0)));
        assert!((0.73..0.75).contains(&meter_level(-19.0)));
        assert_eq!(meter_level(0.0), 1.0);
    }

    #[test]
    fn quick_normal_speech_does_not_fill_the_meter() {
        let normal_speech = meter_level(rms_dbfs(rms_at(-30.0)));
        assert!(normal_speech < 0.6);
    }

    #[test]
    fn quiet_input_remains_visible_for_threshold_calibration() {
        assert!((0.29..0.32).contains(&meter_level(-50.0)));
    }

    #[test]
    fn sensitivity_threshold_is_separate_from_meter_level() {
        let quiet = -62.0;
        let level = meter_level(quiet);
        assert!(!voice_above_threshold(quiet, -60));
        assert!(voice_above_threshold(quiet, -65));
        assert_eq!(meter_level(quiet), level);
    }

    #[test]
    fn automatic_paste_matches_omarchy_terminal_behavior() {
        let terminal = json!({"tags": ["default-opacity*", "terminal*"]});
        let graphical = json!({"tags": ["browser*"]});
        assert_eq!(
            paste_shortcut(PasteMode::Auto, Some(&terminal)),
            ("SHIFT", "Insert")
        );
        assert_eq!(
            paste_shortcut(PasteMode::Auto, Some(&graphical)),
            ("CTRL", "V")
        );
        assert_eq!(
            paste_shortcut(PasteMode::CtrlV, Some(&terminal)),
            ("CTRL", "V")
        );
    }

    #[test]
    fn clipboard_context_reads_text_and_ignores_binary() {
        let types = ["text/plain", "image/jpeg", "image/png"];
        assert_eq!(preferred_clipboard_type(&types), Some("text/plain"));
        assert_eq!(preferred_clipboard_type(&["image/png"]), None);
        let snapshot = ClipboardSnapshot::Content {
            mime_type: "image/png".into(),
            data: vec![0, 159, 146, 150],
        };
        assert_eq!(snapshot.text_context(), "");
    }

    #[test]
    fn wav_header_describes_mono_16khz_s16_pcm() {
        let header = wav_header(32_000).unwrap();
        assert_eq!(&header[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(header[4..8].try_into().unwrap()), 32_036);
        assert_eq!(&header[8..12], b"WAVE");
        assert_eq!(u16::from_le_bytes(header[22..24].try_into().unwrap()), 1);
        assert_eq!(
            u32::from_le_bytes(header[24..28].try_into().unwrap()),
            16_000
        );
        assert_eq!(u16::from_le_bytes(header[34..36].try_into().unwrap()), 16);
        assert_eq!(
            u32::from_le_bytes(header[40..44].try_into().unwrap()),
            32_000
        );
    }
}
