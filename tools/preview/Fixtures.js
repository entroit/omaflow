.pragma library
// Sample content for previews, taken from the Paper file so the renders can
// be compared with the design one to one.

function peaks(seed, count) {
  var out = []
  var value = seed
  for (var i = 0; i < count; i++) {
    value = (value * 9301 + 49297) % 233280
    out.push(30 + Math.round(60 * value / 233280))
  }
  return out
}

var TODAY = "2026-09-25"
var NOW = new Date(2026, 8, 25, 18, 42, 0).getTime()

var DAY = {
  date: TODAY,
  title: "Friday, 25 September 2026",
  file: "/home/you/Documents/Journal/2026-09-25.md",
  exists: true,
  entries: [
    { id: 1758778920000, time: "07:42", typed: false, audio: true, duration_ms: 48000, peaks: peaks(7, 96),
      text: "Slept badly, but the light in the kitchen this morning was ridiculous. Coffee on the balcony, no phone for twenty minutes. I want to keep doing that.",
      raw_text: "so um slept badly but the light in the kitchen this morning was ridiculous coffee on the balcony no phone for twenty minutes I want to keep doing that" },
    { id: 1758795300000, time: "12:15", typed: false, audio: true, duration_ms: 72000, peaks: peaks(13, 96),
      text: "Lunch with Mira. She's leaving the studio in November and asked if I'd take over the Omarchy workshop. I said yes before I'd thought about it, which is probably the right answer.",
      raw_text: "lunch with Mira uh she's leaving the studio in November and asked if I'd take over the Omarchy workshop I said yes before I'd thought about it which is probably the right answer" },
    { id: 1758817800000, time: "18:30", typed: true, audio: false, duration_ms: 0, peaks: [],
      text: "Ran 5 km along the river. Knee fine.", raw_text: "" }
  ]
}

var MONTH = { month: "2026-09", days: [1, 2, 4, 7, 8, 9, 11, 14, 15, 16, 18, 21, 22, 23, 24, 25].map(function(d) {
  return { date: "2026-09-" + String(d).padStart(2, "0"), entries: 2 }
}) }

// A past day with an entry added to it later, filed by its time.
var PAST_DAY = {
  date: "2026-09-18",
  title: "Friday, 18 September 2026",
  file: "/home/you/Documents/Journal/2026-09-18.md",
  exists: true,
  entries: [
    { id: 1758170520000, time: "08:02", typed: false, audio: true, duration_ms: 31000, peaks: peaks(5, 96), added: "",
      text: "Train was late again. Read on the platform and didn't mind.", raw_text: "train was late again um read on the platform and didn't mind" },
    { id: 1758818520000, time: "18:42", typed: true, audio: false, duration_ms: 0, peaks: [], added: "2026-09-25",
      text: "Forgot to write this down: Jonas called about the flat, and we're going to see it on Sunday.", raw_text: "" }
  ]
}

var YEAR_AGO = { date: "2025-09-25", entry: { id: 1, time: "22:10", text: "First night in the new flat. Everything echoes and I love it." } }

var SEARCH = {
  query: "workshop",
  days: ["2026-09-25", "2026-09-16", "2026-09-09", "2025-11-12"],
  truncated: false,
  hits: [
    { date: "2026-09-25", time: "12:15", id: 1758795300000, snippet: "…asked if I'd take over the Omarchy workshop. I said yes.", matches: [[36, 8]] },
    { date: "2026-09-16", time: "21:04", id: 2, snippet: "Mira's Omarchy workshop tonight. Twelve people, and nobody's laptop caught fire.", matches: [[15, 8]] },
    { date: "2026-09-09", time: "08:10", id: 3, snippet: "Signed up to help at the workshop next week.", matches: [[25, 8]] },
    { date: "2025-11-12", time: "19:40", id: 4, snippet: "First Omarchy workshop. I mostly listened.", matches: [[14, 8]] }
  ]
}

// A search that finds a note sealed until a later day, and one written
// ahead to a day that has come.
var SEARCH_NOTE = {
  query: "Mira",
  days: ["2026-10-02", "2026-09-18", "2025-09-24"],
  truncated: false,
  hits: [
    { date: "2026-10-02", time: "Note from 2026-09-20, 21:10", id: 1758900000000, snippet: "Remember to ask Mira how the first week without the studio went.", matches: [[16, 4]] },
    { date: "2026-09-18", time: "Note from 2026-09-01, 08:00", id: 1758900000001, snippet: "Did Mira say yes to the workshop?", matches: [[4, 4]] },
    { date: "2025-09-24", time: "21:53", id: 5, snippet: "Mira said yes to the workshop.", matches: [[0, 4]] }
  ]
}

function history(now) {
  var minute = 60000
  return [
    { id: 6, created_at_ms: now - 40 * minute, text: "Can you move the review to Friday at 10 and send the deck to Mira before then?", raw_text: "so um can you move the review to Thursday, no wait, Friday at ten and uh send the deck to Mira before then", cleanup_model: "gemma4:e4b", pasted: true, cleanup_warning: "", audio: true },
    { id: 5, created_at_ms: now - 55 * minute, text: "Refactor the cleanup guard so it aligns words first and only then decides whether to reject the output.", raw_text: "refactor the cleanup guard so it aligns words first and only then decides whether to reject the output", cleanup_model: "gemma4:e4b", pasted: true, cleanup_warning: "" },
    { id: 4, created_at_ms: now - 202 * minute, text: "Thanks, I'll have the numbers to you by Monday.", raw_text: "thanks I'll have the numbers to you by Monday", cleanup_model: "gemma4:e4b", pasted: false, cleanup_warning: "" },
    { id: 3, created_at_ms: now - 1477 * minute, text: "Notes from the Omarchy call, three things we agreed on.", raw_text: "notes from the Omarchy call three things we agreed on", cleanup_model: "", pasted: true, cleanup_warning: "Cleanup did not answer, so this is the raw text. Check Settings, Cleanup." },
    { id: 2, created_at_ms: now - 1571 * minute, text: "Hi Jonas, thanks for the draft. Two small changes before it goes out.", raw_text: "hi Jonas thanks for the draft two small changes before it goes out", cleanup_model: "gemma4:e4b", pasted: true, cleanup_warning: "" }
  ]
}

var CATALOG = {
  speech: [
    { id: "nvidia/parakeet-tdt-0.6b-v3", label: "Parakeet TDT 0.6B v3", detail: "25 European languages, detected automatically. The fastest and most accurate on English.", size_mb: 714, hardware: "Under 1 GB of GPU memory idle, about 1.2 GB while it works", license: "CC-BY-4.0", tier: "recommended", installed: true, selected: true },
    { id: "nvidia/nemotron-3.5-asr-streaming-0.6b", label: "Nemotron 3.5 Streaming 0.6B", detail: "35 languages, including Japanese, Korean, Chinese, Arabic, Hindi and Turkish.", size_mb: 742, hardware: "About 1 GB of GPU memory idle, about 2.2 GB while it works", license: "OpenMDW-1.1", tier: "quality", installed: false, selected: false },
    { id: "nvidia/parakeet-ctc-1.1b", label: "Parakeet CTC 1.1B", detail: "English only, the largest model here.", size_mb: 1178, hardware: "About 1.7 GB of GPU memory", license: "CC-BY-4.0", tier: "quality", installed: false, selected: false },
    { id: "nvidia/nemotron-speech-streaming-en-0.6b", label: "Nemotron Streaming English 0.6B", detail: "English only, built for streaming, and the smallest download here.", size_mb: 700, hardware: "About 1 GB of GPU memory idle, about 2.2 GB while it works", license: "NVIDIA Open Model License", tier: "light", installed: false, selected: false }
  ],
  cleanup: [
    { id: "gemma4:e4b", label: "Gemma 4 E4B", detail: "The recommended multilingual cleanup model.", size_mb: 9163, hardware: "About 10 GB of GPU memory", license: "Gemma Terms of Use", tier: "recommended", installed: true, selected: true },
    { id: "qwen3:4b", label: "Qwen3 4B", detail: "A compact Apache-licensed option.", size_mb: 2382, hardware: "About 5 GB of GPU memory", license: "Apache-2.0", tier: "light", installed: false, selected: false }
  ]
}

// A to-do file after a few days of use, on Friday 25 September: the Inbox
// and three lists, with something late, something due today, and dates ahead.
var LISTS = ["Infra", "Dev", "Feature"]
var TODOS = [
  { index: 0, text: "Call Mira about the lease", done: false, list: "", due: "2026-09-25", time: "15:00" },
  { index: 1, text: "Buy oat milk", done: false, list: "", due: null },
  { index: 2, text: "Renew the TLS certs on the staging box", done: false, list: "Infra", due: "2026-09-24", time: "09:30", reminder: "off" },
  { index: 3, text: "Move the backups to the new bucket, and check that the old ones restore before deleting them", done: false, list: "Infra", due: "2026-09-28" },
  { index: 4, text: "Rotate the deploy key", done: true, list: "Infra", due: null },
  { index: 5, text: "Fix the AltGr binding when Super is held first", done: false, list: "Dev", due: "2026-09-25", time: "17:00", reminder: "2026-09-25 16:30" },
  { index: 6, text: "Write tests for the to-do split", done: false, list: "Dev", due: null },
  { index: 7, text: "Send Jonas the invoice for September", done: true, list: "Dev", due: null },
  { index: 8, text: "Lists for the to-do page", done: false, list: "Feature", due: "2026-10-09" },
  { index: 9, text: "Notes to your future self", done: true, list: "Feature", due: null }
]
// The same file before any list was made.
var FLAT = TODOS.map(function(t) { return { index: t.index, text: t.text, done: t.done, list: "", due: t.due, time: t.time, reminder: t.reminder } })

// Previews of the page before the first list.
var FLAT_MODES = ["todos", "todos-empty", "todos-editing", "todos-settling", "todos-undo"]

// What one spoken capture just added to Infra: new to-dos at the end of the
// file, nothing done yet and nothing already late.
var SAVED = [
  { index: 10, text: "Renew the TLS certs on the staging box", done: false, list: "Infra", due: "2026-09-28", time: "09:30", reminder: "off" },
  { index: 11, text: "Move the backups to the new bucket, and check that the old ones restore before deleting them", done: false, list: "Infra", due: "2026-09-30" },
  { index: 12, text: "Rotate the deploy key", done: false, list: "Infra", due: null }
]

function state(mode, now) {
  var s = {
    phase: "idle", latched: false, journal_take: false, text: "", error: "",
    history: history(now), meter_gate_db: -48, meter_gate_auto: true, duck_audio_percent: 70, paste_mode: "auto",
    paste_shortcut: { modifiers: ["ctrl"], key: "V" }, error_visible_ms: 5000, notice_visible_ms: 5000,
    training_log_enabled: false, hotkey_display: "F9", custom_vocabulary: ["Omarchy", "Claude Code", "Hyprland", "user_id"],
    can_undo_delete: false, asr_running: true, cleanup_loaded: true, cleanup_available: true, cleanup_runtime: "ready",
    gpu_memory_mib: 6300, state_version: 4, running_version: "0.19.0",
    model_settings: { configured: true, speech_engine: "nemo", speech_model: "nvidia/parakeet-tdt-0.6b-v3", speech_endpoint: "http://127.0.0.1:18103/v1/audio/transcriptions", speech_device: "cuda", speech_language: "auto", cleanup_engine: "ollama", cleanup_model: "gemma4:e4b", cleanup_endpoint: "http://127.0.0.1:11434/api/chat" },
    model_catalog: CATALOG, model_downloads: {}, config_path: "/home/you/.config/omaflow/config.toml",
    shortcut_settings: { keys: ["F9"], consumed: [], window: "SUPER + SHIFT + V", journal: "" }, cleanup_enabled: true, cleanup_level: "medium",
    history_limit: 30, feedback: "", feedback_error: false, feedback_serial: 0, keep_models_loaded: true,
    asr_failed: false, error_action: "", input_device: "", take_date: "", kept_in_history: false, history_transcribing: [],
    paste_sent: false, recording_elapsed_ms: 0, keep_dictation_audio: true,
    journal_settings: { folder: "~/Documents/Journal", folder_path: "/home/you/Documents/Journal", cleanup: "light", keep_recordings: true, empty_day_question: false },
    journal_revision: 1, journal_saved: null, journal_playback: null, published_at_ms: Date.now(),
    todo_take: false, todos_saved: null, todos_revision: 1,
    todo_settings: { folder: "~/Documents/To-dos", folder_path: "/home/you/Documents/To-dos", file_path: "/home/you/Documents/To-dos/To-dos.md", remind_before: 15 }
  }
  if (mode === "todos-talking") { s.phase = "recording"; s.latched = true; s.todo_take = true; s.recording_elapsed_ms = 9000 }
  if (mode.indexOf("todos") === 0) s.shortcut_settings.todo = "MOD5 + T"
  if (mode.indexOf("todos-") === 0 && FLAT_MODES.indexOf(mode) < 0) s.todo_list = "Infra"
  if (mode.indexOf("journal-playing") === 0)
    s.journal_playback = { date: TODAY, id: 1758795300000, offset_ms: 29000, started_at_ms: now, duration_ms: 72000 }
  if (mode === "journal-talking") { s.phase = "recording"; s.latched = true; s.journal_take = true; s.recording_elapsed_ms = 37000 }
  if (mode === "journal-writing") { s.phase = "processing"; s.journal_take = true }
  if (mode === "history-setup") s.model_settings.configured = false
  if (mode === "history-empty") s.history = []
  if (mode === "history-undo") { s.can_undo_delete = true; s.feedback = "Dictation deleted"; s.feedback_serial = 1 }
  if (mode === "history-off") { s.history = []; s.history_limit = 0 }
  if (mode === "history-toast-error") { s.feedback_error = true; s.feedback_serial = 1
    s.feedback = "OmaFlow could not save the history file: the disk is full. Free some space, then save your changes again." }
  if (mode === "history-unloaded") { s.keep_models_loaded = false; s.asr_running = false }
  if (mode === "history-stopped" || mode === "history-stopped-narrow" || mode === "history-restarting") { s.asr_running = false; s.asr_failed = true }
  // A dictation fixed by hand after cleanup.
  if (mode === "history-edited") { s.history[0].text = "Can you move the review to Friday at 11 and send the deck to Mira on Thursday?"; s.history[0].edited = true }
  // Settings: a fresh install whose chosen model is not here yet, a custom
  // paste chord, Light cleanup with nothing in History, a known microphone.
  if (mode === "settings-models-missing") {
    s.model_settings.configured = false; s.asr_running = false; s.gpu_memory_mib = 0
    s.model_catalog = { speech: CATALOG.speech.map(function(e) { return Object.assign({}, e, { installed: false }) }), cleanup: CATALOG.cleanup }
  }
  if (mode === "settings-basics-custom") { s.paste_mode = "custom"; s.paste_shortcut = { modifiers: ["ctrl", "shift"], key: "V" }; s.input_device = "Blue Yeti Stereo Microphone" }
  if (mode === "settings-audio-manual") s.meter_gate_auto = false
  if (mode === "settings-basics-light") { s.cleanup_level = "light"; s.history = []; s.history_limit = 0 }
  // The window is newer than the daemon still running.
  if (mode === "history-partly" || mode === "settings-updates-partly") s.state_version = 3
  // Keep the raw text, saved over a cleaned dictation.
  if (mode === "history-kept") { s.history[0].text = s.history[0].raw_text; s.history[0].edited = true }
  // A dictation the speech model failed, saved with its recording; being
  // transcribed again; or with its recording deleted by Privacy.
  if (mode.indexOf("history-failed") === 0) s.history.unshift({ id: 7, created_at_ms: now - 2 * 60000, text: "", raw_text: "",
    cleanup_model: "", pasted: false, cleanup_warning: "", audio: mode !== "history-failed-gone",
    status: { state: "not_transcribed", reason: "Transcription stalled and was stopped." } })
  if (mode === "history-failed-transcribing") s.history_transcribing = [7]
  // A dictation too long for the window; cleanup off, the default, with
  // and without a word from Words; the first speech model downloading;
  // OmaFlow stopped before anything was dictated; Paste set to Clipboard only.
  if (mode === "history-long") { var said = []; for (var w = 0; w < 700; w++) said.push(["so", "the", "review", "moves", "to", "Friday", "and", "Mira", "gets", "the", "deck"][w % 11])
    s.history[0].text = said.join(" ") + "."; s.history[0].raw_text = s.history[0].text + " um" }
  if (mode === "history-cleanupoff" || mode === "history-vocab") { s.cleanup_enabled = false; s.cleanup_level = "off"
    s.history.forEach(function(e) { e.raw_text = e.text; e.cleanup_model = ""; e.cleanup_warning = "" }) }
  if (mode === "history-vocab") s.history[0].raw_text = "Can you move the review to Friday at 10 and send the deck to mira before then?"
  if (mode === "history-firstdownload") { s.model_settings.configured = false
    s.model_catalog = { speech: CATALOG.speech.map(function(e) { return Object.assign({}, e, { installed: false }) }), cleanup: CATALOG.cleanup }
    s.model_downloads = { "nvidia/parakeet-tdt-0.6b-v3": { state: "downloading", percent: 62, message: "443 MB of 714 MB" } } }
  if (mode === "history-stoppedempty") { s.history = []; s.published_at_ms = Date.now() - 60000 }
  if (mode === "settings-basics-stopped") s.published_at_ms = Date.now() - 60000
  if (mode === "history-clipboard") s.paste_mode = "clipboard"
  // A computer without an NVIDIA GPU: the CPU build, and CPU times in the rows.
  if (mode === "settings-models-cpu") {
    var cpuTimes = ["About 2 seconds per 30 seconds of speech, and 1 GB of memory", "About 5 seconds per 30 seconds of speech, and 2 GB of memory",
      "About 3.5 seconds per 30 seconds of speech, and 1.4 GB of memory", "About 2.5 seconds per 30 seconds of speech, and 2 GB of memory"]
    s.gpu_memory_mib = 0
    s.model_catalog = { speech: CATALOG.speech.map(function(e, i) { return Object.assign({}, e, { hardware: cpuTimes[i] }) }),
      cleanup: CATALOG.cleanup, speech_runtime: "cpu", nvidia_gpu: false }
  }
  if (mode === "settings-models-downloading")
    s.model_downloads = { "nvidia/parakeet-ctc-1.1b": { state: "downloading", percent: 62, message: "730 MB of 1.2 GB" } }
  if (mode === "settings-cleanup-light") s.cleanup_level = "light"
  // Medium with Ollama missing, a server of your own that stopped answering,
  // history off, and a speech model file of your own.
  if (mode === "settings-basics-cleanmissing" || mode === "settings-cleanup-cleanmissing") s.cleanup_runtime = "missing"
  if (mode === "settings-cleanup-serverdown") {
    s.cleanup_runtime = "stopped"
    Object.assign(s.model_settings, { cleanup_engine: "openai", cleanup_model: "qwen3-8b", cleanup_endpoint: "https://llm.example.com/v1/chat/completions" })
  }
  if (mode === "settings-privacy-nohist") { s.history = []; s.history_limit = 0 }
  if (mode === "settings-models-own") {
    s.model_settings.speech_model = "/home/you/models/my-asr-q8_0.gguf"
    s.model_catalog = { speech: CATALOG.speech.map(function(e) { return Object.assign({}, e, { selected: false }) }), cleanup: CATALOG.cleanup }
  }
  if (mode.indexOf("overlay-") === 0) {
    var phase = mode.slice(8)
    s.phase = phase
    if (phase === "locked") { s.phase = "recording"; s.latched = true; s.recording_elapsed_ms = 42000 }
    if (phase === "holding") { s.phase = "recording"; s.recording_elapsed_ms = 3000 }
    // A spoken note for a later day.
    if (phase === "journal-note") s.phase = "journal-saved"
    if (phase === "journal") { s.phase = "recording"; s.latched = true; s.journal_take = true; s.recording_elapsed_ms = 37000 }
    if (phase.indexOf("todo-") === 0 || phase === "todo") { s.phase = "recording"; s.latched = true; s.todo_take = true; s.recording_elapsed_ms = 9000 }
    if (phase.indexOf("todos-saved") === 0) s.phase = "todos-saved"
    if (phase.indexOf("todos-saved") === 0) s.todos_saved = { items: SAVED, moved: false }
    if (phase === "copy-failed") { s.phase = "result"; s.text = "Thanks, I'll have the numbers to you by Monday."; s.error = "Your words are safe in History. The clipboard did not take them." }
    if (phase === "clipboard") { s.phase = "result"; s.text = "Thanks, I'll have the numbers to you by Monday."; s.paste_mode = "clipboard" }
    if (phase === "warning") { s.phase = "result"; s.text = "Notes from the Omarchy call."; s.paste_sent = true; s.feedback = "Cleanup did not answer, so this is the raw text. Check Settings, Cleanup."; s.feedback_error = true }
    if (phase === "processing-journal") { s.phase = "processing"; s.journal_take = true }
    if (phase === "processing-todos") { s.phase = "processing"; s.todo_take = true }
    if (phase === "error-model") { s.phase = "error"; s.error_action = "choose_model"; s.error = "Nothing was recorded. Parakeet TDT 0.6B v3 (714 MB) is the usual choice." }
    // A take that has heard nothing for four seconds.
    if (phase === "nomic") { s.phase = "recording"; s.latched = true; s.recording_elapsed_ms = 4000 }
    // A card closing by itself, a third of the way through its time.
    if (["success", "notice", "journal-saved", "error"].indexOf(s.phase) >= 0 || phase.indexOf("todos-saved") === 0
      || phase.indexOf("notice-") === 0 || s.phase === "result" && !s.error)
      s.card_timer = { total_ms: 7000, remaining_ms: 4700 }
    if (phase.indexOf("todo") === 0) s.todo_list = "Infra"
    if (phase === "journal-saved") s.journal_saved = { date: TODAY, id: 1, words: 146, duration_ms: 72000 }
    if (phase === "journal-note") s.journal_saved = { date: "2026-10-02", id: 1, words: 23, duration_ms: 9000 }
    if (phase === "result") { s.text = "Thanks, I'll have the numbers to you by Monday."; s.paste_sent = false }
    if (phase === "error") s.error = "Transcription stalled and was stopped. Hold AltGr+Menu and say it again."
    if (phase === "error-kept") { s.phase = "error"; s.can_retry = true; s.error = "Transcription stalled and was stopped. Your recording is kept until you start another." }
    if (phase === "error-saved") { s.phase = "error"; s.can_retry = true; s.kept_in_history = true; s.error = "Transcription stalled and was stopped. Your recording is saved in History." }
    // A journal take for a later day, a note, and one for a past day.
    if (phase.indexOf("journal-for-") === 0) { s.phase = "recording"; s.latched = true; s.journal_take = true; s.recording_elapsed_ms = 9000
      s.take_date = phase === "journal-for-later" ? "2026-10-02" : "2026-09-18" }
    if (phase === "error-downloading") { s.phase = "error"; s.error_action = "downloading"; s.error = "Hold AltGr+Menu again when Parakeet TDT 0.6B v3 finishes."
      s.model_downloads = { "nvidia/parakeet-tdt-0.6b-v3": { state: "downloading", percent: 62, message: "443 MB of 714 MB" } } }
    if (phase === "journal-warning") { s.phase = "journal-saved"; s.journal_saved = { date: TODAY, id: 1, words: 146, duration_ms: 72000 }
      s.feedback = "Cleanup did not answer, so this was saved lightly tidied. Check Settings, Cleanup."; s.feedback_error = true }
    if (phase === "notice-update") { s.phase = "notice"; s.feedback = "OmaFlow is finishing an update. Try again in a minute." }
    if (phase === "notice-update-failed") { s.phase = "notice"; s.feedback = "An update did not finish, so dictation is paused. Open OmaFlow and choose Put back 0.19.0 in Settings, Advanced, Updates and app." }
    // To-dos moved to another list from the card.
    if (phase === "todos-saved-moved") s.todos_saved = { items: SAVED.map(function(item) { return Object.assign({}, item, { list: "Dev" }) }), moved: true }
    // A notice too long for one capsule, naming a settings page.
    if (phase === "notice-long") { s.phase = "notice"; s.feedback = "OmaFlow could not read where the last update stopped, so dictation is paused. Open OmaFlow and choose Check now in Settings, Advanced, Updates and app." }
    // A to-do fixed or taken out on the card since.
    if (phase === "todos-saved-changed") s.todos_saved = { items: SAVED.slice(0, 2), moved: false, changed: true }
    if (phase === "todos-saved-warning") { s.feedback = "Cleanup was unavailable, so these were split by sentence. Check them above."; s.feedback_error = true }
    // The clipboard did not take the words, and History is off.
    if (phase === "copy-failed-nohistory") { s.phase = "result"; s.history_limit = 0; s.text = "Thanks, I'll have the numbers to you by Monday."
      s.error = "The clipboard did not take them, and History is off, so this card is their only copy. Use Copy again." }
    // The model finished downloading while the card kept the recording.
    if (phase === "error-ready") { s.phase = "error"; s.error_action = "ready"; s.can_retry = true
      s.error = "Choose Try again to transcribe it with Parakeet TDT 0.6B v3. Your recording is kept until you start another." }
    if (phase === "error-mic") { s.phase = "error"; s.card_timer = { total_ms: 7000, remaining_ms: 4700 }
      s.error = "OmaFlow could not reach the microphone. Check the microphone in Settings, Audio." }
    // A finished entry or capture whose folder could not be written.
    if (phase === "error-journal-save") { s.phase = "error"; s.journal_take = true
      s.error = "The entry is on your clipboard. OmaFlow cannot write to ~/Documents/Journal. Check the folder in Journal settings." }
    if (phase === "error-todos-save") { s.phase = "error"; s.todo_take = true
      s.error = "The to-dos are on your clipboard. OmaFlow cannot write to ~/Documents/To-dos. Check the folder in To-dos, Reminders and folder." }
    // A journal shortcut pressed mid-dictation, and Discard asking on a long take.
    if (phase === "locked-busy" || phase === "locked-asking") { s.phase = "recording"; s.latched = true; s.recording_elapsed_ms = 252000 }
    if (phase === "locked-busy") s.feedback = "Finish the recording first, then start the journal entry."
  }
  return s
}
