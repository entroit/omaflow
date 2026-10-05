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

var YEAR_AGO = { date: "2025-09-25", entry: { id: 1, time: "22:10", text: "First night in the new flat. Everything echoes and I love it." } }

var SEARCH = {
  query: "workshop",
  days: ["2026-09-25", "2026-09-16", "2026-09-09"],
  truncated: false,
  hits: [
    { date: "2026-09-25", time: "12:15", id: 1758795300000, snippet: "…asked if I'd take over the Omarchy workshop. I said yes.", matches: [[36, 8]] },
    { date: "2026-09-16", time: "21:04", id: 2, snippet: "Mira's Omarchy workshop tonight. Twelve people, and nobody's laptop caught fire.", matches: [[15, 8]] },
    { date: "2026-09-09", time: "08:10", id: 3, snippet: "Signed up to help at the workshop next week.", matches: [[25, 8]] }
  ]
}

function history(now) {
  var minute = 60000
  return [
    { id: 6, created_at_ms: now - 40 * minute, text: "Can you move the review to Friday at 10 and send the deck to Mira before then?", raw_text: "so um can you move the review to Thursday, no wait, Friday at ten and uh send the deck to Mira before then", cleanup_model: "gemma4:e4b", pasted: true, cleanup_warning: "", audio: true },
    { id: 5, created_at_ms: now - 55 * minute, text: "Refactor the cleanup guard so it aligns words first and only then decides whether to reject the output.", raw_text: "refactor the cleanup guard so it aligns words first and only then decides whether to reject the output", cleanup_model: "gemma4:e4b", pasted: true, cleanup_warning: "" },
    { id: 4, created_at_ms: now - 202 * minute, text: "Thanks, I'll have the numbers to you by Monday.", raw_text: "thanks I'll have the numbers to you by Monday", cleanup_model: "gemma4:e4b", pasted: false, cleanup_warning: "" },
    { id: 3, created_at_ms: now - 1477 * minute, text: "Notes from the Omarchy call, three things we agreed on.", raw_text: "notes from the Omarchy call three things we agreed on", cleanup_model: "", pasted: true, cleanup_warning: "The cleanup model was unavailable, so the raw transcription was used." },
    { id: 2, created_at_ms: now - 1571 * minute, text: "Hi Jonas, thanks for the draft. Two small changes before it goes out.", raw_text: "hi Jonas thanks for the draft two small changes before it goes out", cleanup_model: "gemma4:e4b", pasted: true, cleanup_warning: "" }
  ]
}

var CATALOG = {
  speech: [
    { id: "nvidia/parakeet-tdt-0.6b-v3", label: "Parakeet TDT 0.6B v3", detail: "25 European languages, detected automatically. The fastest and most accurate on English.", size_mb: 714, hardware: "Under 1 GB of GPU memory idle", license: "CC-BY-4.0", tier: "recommended", installed: true, selected: true },
    { id: "nvidia/nemotron-3.5-asr-streaming-0.6b", label: "Nemotron 3.5 Streaming 0.6B", detail: "35 languages, including Japanese, Korean, Chinese, Arabic, Hindi and Turkish.", size_mb: 742, hardware: "About the same as Parakeet", license: "OpenMDW-1.1", tier: "quality", installed: false, selected: false },
    { id: "nvidia/parakeet-ctc-1.1b", label: "Parakeet CTC 1.1B", detail: "English only, the largest model here.", size_mb: 1178, hardware: "Roughly twice Parakeet TDT", license: "CC-BY-4.0", tier: "quality", installed: false, selected: false },
    { id: "nvidia/nemotron-speech-streaming-en-0.6b", label: "Nemotron Streaming English 0.6B", detail: "English only, the smallest download. Try it on a machine without a usable GPU.", size_mb: 700, hardware: "The lightest of these", license: "NVIDIA Open Model License", tier: "light", installed: false, selected: false }
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
  { index: 2, text: "Renew the TLS certs on the staging box", done: false, list: "Infra", due: "2026-09-24" },
  { index: 3, text: "Move the backups to the new bucket, and check that the old ones restore before deleting them", done: false, list: "Infra", due: "2026-09-28" },
  { index: 4, text: "Rotate the deploy key", done: true, list: "Infra", due: null },
  { index: 5, text: "Fix the AltGr binding when Super is held first", done: false, list: "Dev", due: "2026-09-25" },
  { index: 6, text: "Write tests for the to-do split", done: false, list: "Dev", due: null },
  { index: 7, text: "Send Jonas the invoice for September", done: true, list: "Dev", due: null },
  { index: 8, text: "Lists for the to-do page", done: false, list: "Feature", due: "2026-10-09" },
  { index: 9, text: "Notes to your future self", done: true, list: "Feature", due: null }
]
// The same file before any list was made.
var FLAT = TODOS.map(function(t) { return { index: t.index, text: t.text, done: t.done, list: "", due: t.due, time: t.time } })

// Previews of the page before the first list.
var FLAT_MODES = ["todos", "todos-empty", "todos-editing", "todos-settling", "todos-undo"]

function state(mode, now) {
  var s = {
    phase: "idle", latched: false, journal_take: false, text: "", error: "",
    history: history(now), meter_gate_db: -48, duck_audio_percent: 70, paste_mode: "auto",
    paste_shortcut: { modifiers: ["ctrl"], key: "V" }, error_visible_ms: 5000, notice_visible_ms: 5000,
    training_log_enabled: false, hotkey_display: "F9", custom_vocabulary: ["Omarchy", "Claude Code", "Hyprland", "user_id"],
    can_undo_delete: false, asr_running: true, cleanup_loaded: true, cleanup_available: true, cleanup_runtime: "ready",
    gpu_memory_mib: 6300, state_version: 4, running_version: "0.19.0",
    model_settings: { configured: true, speech_engine: "nemo", speech_model: "nvidia/parakeet-tdt-0.6b-v3", speech_endpoint: "http://127.0.0.1:18103/v1/audio/transcriptions", speech_device: "cuda", speech_language: "auto", cleanup_engine: "ollama", cleanup_model: "gemma4:e4b", cleanup_endpoint: "http://127.0.0.1:11434/api/chat" },
    model_catalog: CATALOG, model_downloads: {}, config_path: "/home/you/.config/omaflow/config.toml",
    shortcut_settings: { keys: ["F9"], consumed: [], window: "SUPER + SHIFT + V", journal: "" }, cleanup_enabled: true, cleanup_level: "medium",
    history_limit: 30, feedback: "", feedback_error: false, keep_models_loaded: true,
    paste_sent: false, recording_elapsed_ms: 0, keep_dictation_audio: true,
    journal_settings: { folder: "~/Documents/Journal", folder_path: "/home/you/Documents/Journal", cleanup: "light", keep_recordings: true, empty_day_question: false },
    journal_revision: 1, journal_saved: null, journal_playback: null, published_at_ms: Date.now(),
    todo_take: false, todos_saved: null, todos_revision: 1,
    todo_settings: { folder: "~/Documents/To-dos", folder_path: "/home/you/Documents/To-dos", file_path: "/home/you/Documents/To-dos/To-dos.md" }
  }
  if (mode === "todos-talking") { s.phase = "recording"; s.latched = true; s.todo_take = true; s.recording_elapsed_ms = 9000 }
  if (mode.indexOf("todos") === 0) s.shortcut_settings.todo = "MOD5 + T"
  if (mode.indexOf("todos-") === 0 && FLAT_MODES.indexOf(mode) < 0) s.todo_list = "Infra"
  if (mode.indexOf("journal-playing") === 0)
    s.journal_playback = { date: TODAY, id: 1758795300000, offset_ms: 29000, started_at_ms: now, duration_ms: 72000 }
  if (mode === "journal-talking") { s.phase = "recording"; s.latched = true; s.journal_take = true; s.recording_elapsed_ms = 37000 }
  if (mode === "history-setup") s.model_settings.configured = false
  if (mode === "history-empty") s.history = []
  if (mode === "history-undo") { s.can_undo_delete = true; s.feedback = "Dictation deleted. Undo is available." }
  if (mode.indexOf("overlay-") === 0) {
    var phase = mode.slice(8)
    s.phase = phase
    if (phase === "locked") { s.phase = "recording"; s.latched = true; s.recording_elapsed_ms = 42000 }
    if (phase === "holding") { s.phase = "recording"; s.recording_elapsed_ms = 3000 }
    if (phase === "journal") { s.phase = "recording"; s.latched = true; s.journal_take = true; s.recording_elapsed_ms = 37000 }
    if (phase.indexOf("todo-") === 0 || phase === "todo") { s.phase = "recording"; s.latched = true; s.todo_take = true; s.recording_elapsed_ms = 9000 }
    if (phase.indexOf("todos-saved") === 0) s.phase = "todos-saved"
    if (phase.indexOf("todos-saved") === 0) s.todos_saved = { items: [TODOS[2], TODOS[3], TODOS[4]], moved: false }
    // A card closing by itself, a third of the way through its time.
    if (["success", "notice", "journal-saved", "error"].indexOf(s.phase) >= 0 || phase.indexOf("todos-saved") === 0)
      s.card_timer = { total_ms: 7000, remaining_ms: 4700 }
    if (phase.indexOf("todo") === 0) s.todo_list = "Infra"
    if (phase === "journal-saved") s.journal_saved = { date: TODAY, id: 1, words: 146, duration_ms: 72000 }
    if (phase === "result") { s.text = "Thanks, I'll have the numbers to you by Monday."; s.paste_sent = false }
    if (phase === "error") s.error = "Transcription stalled and was stopped. Try again."
    if (phase === "error-kept") { s.phase = "error"; s.can_retry = true; s.error = "Transcription stalled and was stopped. Your recording is kept." }
  }
  return s
}
