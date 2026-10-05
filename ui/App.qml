import QtQuick
import "Keys.js" as KeyNames

// Everything the screens know about OmaFlow, and everything they can ask it
// to do. It holds no platform code: a host (the Omarchy shell plugin today, a
// standalone Qt app later) feeds it the daemon's state and lends it a few
// hooks, and every screen talks to this object only.
//
// Host hooks, set on `host`:
//   spawn(argv, callback(stdout, stderr, exitCode))   run a process
//   copy(text)                                         put text on the clipboard
//   openInEditor(path)                                 open a text file
//   openExternally(pathOrUrl)                          folder, web page
//   showWindow(page), hideWindow()                     open or close the main window
Item {
  id: app
  visible: false

  property var host: null

  // ------------------------------------------------------------ connection
  property bool connected: false
  property bool binaryFound: true
  property int stateVersion: 1
  property double lastPublishedAt: 0
  readonly property bool supportedState: stateVersion === 4

  // ------------------------------------------------------------- dictation
  property string phase: "idle"
  property bool latched: false
  property bool journalTake: false
  property bool todoTake: false
  property int recordingSeconds: 0
  property string transcript: ""
  property string errorText: ""
  property bool pasteSent: false
  property string pasteMode: "auto"
  property var pasteShortcut: ({modifiers: ["ctrl"], key: "V"})
  property int noticeVisibleMs: 5000
  property int errorVisibleMs: 5000

  // Microphone meter, fed by the host from the daemon's level file.
  property real micLevel: 0
  property bool micDetected: false
  // About ten seconds of levels: enough to fill the journal's recording card.
  readonly property int waveSamples: 120
  property var waveHistory: []
  property bool meterPreview: false

  // --------------------------------------------------------------- history
  property var history: []
  property bool canUndoDelete: false
  property int historyLimit: 30

  // -------------------------------------------------------------- feedback
  property string feedback: ""
  property bool feedbackError: false

  // -------------------------------------------------------------- settings
  property string hotkeyDisplay: ""
  property var shortcutSettings: ({})
  property var modelSettings: ({})
  property var modelCatalog: ({})
  property var modelDownloads: ({})
  property string cleanupLevel: "off"
  property bool cleanupEnabled: false
  property string cleanupRuntime: "ready"
  property bool asrRunning: false
  property int gpuMemoryMib: 0
  property var customVocabulary: []
  property bool trainingLogEnabled: false
  property bool keepModelsLoaded: true
  property bool keepDictationAudio: false
  property int duckAudioPercent: 70
  property int meterGateDb: -60
  property string personalConfigPath: ""
  property string pluginDir: ""

  // --------------------------------------------------------------- updates
  property string runningVersion: ""
  property var updateOffer: ({})
  property var updateTransaction: ({})
  property var updateDeferral: ({})
  property bool updateChecking: false
  property double nowMs: Date.now()
  // Set by previews and tests to pin "today"; 0 follows the real clock.
  property double clockOverride: 0
  readonly property var verifiedUpdate: updateOffer.target
    && !(updateTransaction.state === "succeeded"
      && updateTransaction.targetCommit === updateOffer.target.commit)
    ? updateOffer.target : null
  readonly property bool updateAvailable: verifiedUpdate !== null
  readonly property string updateState: String(updateTransaction.state || "")
  readonly property bool updateRunning: ["queued", "preparing", "waiting-for-idle", "activating", "verifying"].indexOf(updateState) >= 0
  readonly property bool updateFailed: ["rolled-back", "needs-recovery"].indexOf(updateState) >= 0
  readonly property bool updateActionsAvailable: supportedState && updateAvailable && !updateRunning
    && !updateOffer.externalCheckoutWarning && !updateOffer.error
  readonly property bool updateDeferred: updateAvailable
    && updateDeferral.commit === verifiedUpdate.commit
    && Number(updateDeferral.untilMs || 0) > nowMs
  readonly property bool updateAttention: updateAvailable || updateRunning || updateFailed
    || Boolean(updateOffer.externalCheckoutWarning)

  // --------------------------------------------------------------- journal
  property var journalSettings: ({folder: "~/Documents/Journal", cleanup: "light", keep_recordings: true, empty_day_question: false})
  property int journalRevision: 0
  property var journalSaved: null
  property var journalPlayback: null

  // ---------------------------------------------------------------- to-dos
  property var todoSettings: ({folder: "~/Documents/To-dos", file_path: ""})
  property int todosRevision: 0
  property var todosSaved: null
  // A card that closes by itself: how long it is shown for, and the moment
  // it closes on this clock, or 0 while it waits for you.
  property double cardTotalMs: 0
  // A failed take's recording is kept, so Try again can use it.
  property bool canRetry: false
  property double cardClosesAt: 0
  // Where the next to-do goes, "" for the Inbox; during a capture, where it is going.
  property string todoList: ""

  // --------------------------------------------------------------- derived
  readonly property var speechCatalog: Array.isArray(modelCatalog.speech) ? modelCatalog.speech : []
  readonly property var cleanupCatalog: Array.isArray(modelCatalog.cleanup) ? modelCatalog.cleanup : []
  function downloadFor(id) { return modelDownloads[String(id)] || null }
  readonly property bool speechDownloading: speechCatalog.some(function(entry) {
    var job = downloadFor(entry.id)
    return job !== null && job.state === "downloading"
  })
  readonly property bool setupUnfinished: modelSettings.configured === false
  readonly property string hotkeyLabel: hotkeyDisplay.length > 0 ? hotkeyDisplay : "your hotkey"
  // "SUPER + SHIFT + V" as people read it: "Super Shift V". Empty when unset.
  function bindingLabel(binding) { return KeyNames.labels(binding).join(" ") }
  readonly property string journalShortcut: bindingLabel(shortcutSettings.journal)
  readonly property string windowShortcut: bindingLabel(shortcutSettings.window)
  readonly property string openJournalShortcut: bindingLabel(shortcutSettings.open_journal)
  readonly property string todoShortcut: bindingLabel(shortcutSettings.todo)
  readonly property string openTodosShortcut: bindingLabel(shortcutSettings.open_todos)

  // One line for the header: what OmaFlow is doing, and whether that is fine.
  readonly property string statusTone: !binaryFound || !connected ? "red"
    : phase === "recording" ? "red"
    : setupUnfinished || (!asrRunning && !speechDownloading) || speechDownloading ? "yellow"
    : "green"
  readonly property string statusText: !binaryFound ? "Daemon not built"
    : !connected ? "Stopped"
    : phase === "recording" ? (journalTake ? "Recording journal entry" : todoTake ? "Listening for to-dos" : "Recording")
    : phase === "processing" ? (journalTake ? "Writing it down" : todoTake ? "Adding to-dos" : "Transcribing")
    : setupUnfinished ? "Setup not finished"
    : speechDownloading ? "Downloading the speech model"
    : !asrRunning ? "Speech model loading"
    : "Ready, hold " + hotkeyLabel

  // ------------------------------------------------------------ state file
  function applyState(raw) {
    var next
    try { next = JSON.parse(raw || "{}") } catch (error) { return false }
    phase = String(next.phase || "idle")
    latched = Boolean(next.latched)
    journalTake = Boolean(next.journal_take)
    todoTake = Boolean(next.todo_take)
    pasteSent = Boolean(next.paste_sent)
    transcript = String(next.text || "")
    errorText = String(next.error || "")
    replaceIfChanged("history", Array.isArray(next.history) ? next.history : [])
    var gate = Number(next.meter_gate_db)
    meterGateDb = isFinite(gate) ? Math.max(-70, Math.min(-35, Math.round(gate))) : -60
    pasteMode = ["auto", "ctrl-v", "shift-insert", "clipboard", "custom"].indexOf(next.paste_mode) >= 0
      ? String(next.paste_mode) : "auto"
    if (next.paste_shortcut && Array.isArray(next.paste_shortcut.modifiers)
        && typeof next.paste_shortcut.key === "string")
      replaceIfChanged("pasteShortcut", next.paste_shortcut)
    var errorTimeout = Number(next.error_visible_ms)
    errorVisibleMs = isFinite(errorTimeout) ? Math.max(1000, Math.min(60000, errorTimeout)) : 5000
    var noticeTimeout = Number(next.notice_visible_ms)
    noticeVisibleMs = isFinite(noticeTimeout) ? Math.max(500, Math.min(60000, noticeTimeout)) : 5000
    replaceIfChanged("modelSettings", next.model_settings || ({}))
    replaceIfChanged("shortcutSettings", next.shortcut_settings || ({}))
    replaceIfChanged("modelCatalog", next.model_catalog || ({}))
    replaceIfChanged("modelDownloads", next.model_downloads || ({}))
    replaceIfChanged("journalSettings", next.journal_settings || journalSettings)
    replaceIfChanged("journalSaved", next.journal_saved || null)
    replaceIfChanged("journalPlayback", next.journal_playback || null)
    journalRevision = Number(next.journal_revision || 0)
    replaceIfChanged("todoSettings", next.todo_settings || todoSettings)
    replaceIfChanged("todosSaved", next.todos_saved || null)
    todosRevision = Number(next.todos_revision || 0)
    todoList = String(next.todo_list || "")
    personalConfigPath = String(next.config_path || personalConfigPath)
    trainingLogEnabled = Boolean(next.training_log_enabled)
    hotkeyDisplay = String(next.hotkey_display || "")
    customVocabulary = Array.isArray(next.custom_vocabulary) ? next.custom_vocabulary : []
    canUndoDelete = Boolean(next.can_undo_delete)
    asrRunning = Boolean(next.asr_running)
    cleanupEnabled = Boolean(next.cleanup_enabled)
    cleanupLevel = ["off", "light", "medium"].indexOf(next.cleanup_level) >= 0
      ? String(next.cleanup_level) : (cleanupEnabled ? "medium" : "off")
    cleanupRuntime = ["ready", "stopped", "missing"].indexOf(next.cleanup_runtime) >= 0
      ? String(next.cleanup_runtime) : "stopped"
    gpuMemoryMib = Math.max(0, Number(next.gpu_memory_mib) || 0)
    var version = Number(next.state_version)
    stateVersion = isFinite(version) ? Math.round(version) : 1
    runningVersion = String(next.running_version || "")
    lastPublishedAt = Number(next.published_at_ms || 0)
    canRetry = next.can_retry === true
    var timer = next.card_timer || null
    cardTotalMs = timer ? Number(timer.total_ms) : 0
    var closesAt = timer && timer.remaining_ms !== null && timer.remaining_ms !== undefined
      ? lastPublishedAt + Number(timer.remaining_ms) : 0
    // Republished every second; only a real change moves the ring.
    if (Math.abs(closesAt - cardClosesAt) > 80) cardClosesAt = closesAt
    connected = lastPublishedAt > Date.now() - 15000
    keepModelsLoaded = next.keep_models_loaded !== false
    keepDictationAudio = next.keep_dictation_audio === true
    historyLimit = Number(next.history_limit || 0)
    feedback = String(next.feedback || "")
    feedbackError = Boolean(next.feedback_error)
    recordingSeconds = Math.floor(Number(next.recording_elapsed_ms || 0) / 1000)
    var duck = Number(next.duck_audio_percent)
    duckAudioPercent = isFinite(duck) ? Math.max(0, Math.min(100, Math.round(duck))) : 70
    if (phase !== "recording" && !meterPreview) resetMeter()
    return true
  }

  function replaceIfChanged(name, value) {
    if (JSON.stringify(app[name]) !== JSON.stringify(value)) app[name] = value
  }

  // The level file: "level dbfs detected bar×13".
  function applyLevel(raw) {
    if (phase !== "recording" && !meterPreview) return
    var values = String(raw || "").trim().split(/\s+/)
    var level = Number(values[0])
    if (!isFinite(level)) return
    micLevel = Math.max(0, Math.min(1, level))
    micDetected = values[2] === "1"
    var next = waveHistory.slice(-(waveSamples - 1))
    next.push(micLevel)
    waveHistory = next
  }

  function resetMeter() {
    micLevel = 0
    micDetected = false
    if (waveHistory.length > 0) waveHistory = []
  }

  // The daemon rewrites its state at least once a second; silence for longer
  // than that means it stopped.
  function checkConnection() {
    nowMs = clockOverride || Date.now()
    if (lastPublishedAt < nowMs - 15000) {
      connected = false
      phase = "idle"
    }
  }

  // --------------------------------------------------------------- actions
  // `input` goes to the command's stdin: secrets never go in its arguments,
  // which every local user can read in /proc.
  function spawn(argv, callback, input) {
    if (host && host.spawn) host.spawn(argv, callback || function() {}, input || "")
  }
  function command(args) { spawn(["omaflow"].concat(args.map(String))) }
  // Runs an `omaflow` query and hands back its JSON, or an error sentence.
  function query(args, callback) {
    spawn(["omaflow"].concat(args.map(String)), function(stdout, stderr, code) {
      var value = null
      try { value = JSON.parse(stdout || "null") } catch (error) { value = null }
      if (value && value.error) callback(null, String(value.error))
      else if (code !== 0 && value === null) callback(null, String(stderr || "OmaFlow did not answer").trim())
      else callback(value, "")
    })
  }
  function preference(key, value) {
    var secret = value && typeof value === "object"
      && Object.keys(value).some(function(name) { return /api_key$/.test(name) })
    if (secret) spawn(["omaflow", "configure", key, "-"], null, JSON.stringify(value) + "\n")
    else command(["configure", key, JSON.stringify(value)])
  }
  function copy(text) { if (host && host.copy) host.copy(String(text)) }
  function openInEditor(path) { if (host && host.openInEditor) host.openInEditor(String(path)) }
  function openExternally(target) { if (host && host.openExternally) host.openExternally(String(target)) }
  function hideWindow() { if (host && host.hideWindow) host.hideWindow() }
  function showWindow(page) { if (host && host.showWindow) host.showWindow(page || "history") }

  function start() { command(["launch"]) }
  function quit() { hideWindow(); command(["quit"]) }
  function stopRecording() { command(["stop"]) }
  function cancel() { command(["cancel"]) }
  function dismiss() { command(["dismiss"]) }
  function retry() { command(["retry"]) }
  function copyAgain() { command(["copy"]) }

  // History
  function pasteHistory(id) {
    // The window has to let go of keyboard focus before a paste shortcut can
    // reach the app underneath.
    hideWindow()
    pasteTimer.pending = String(id)
    pasteTimer.restart()
  }
  function copyHistory(id) { command(["history-copy", id]) }
  function copyRawHistory(id) { command(["history-raw", id]) }
  function deleteHistory(id) { command(["history-delete", id]) }
  function editHistory(id, text) { command(["history-edit", id, text]) }
  function undoDelete() { command(["history-undo"]) }
  function clearHistory() { command(["history-clear"]) }
  function eraseData() { command(["erase-data"]) }

  // Settings
  function setCleanupLevel(level) { preference("cleanup_level", level) }
  function setPasteMode(mode) { pasteMode = mode; command(["paste-mode", mode]) }
  function savePasteShortcut(modifiers, key) {
    preference("paste_delivery", {mode: "custom", shortcut: {modifiers: modifiers, key: String(key).trim()}})
  }
  function addVocabulary(value) {
    var term = String(value || "").trim().replace(/\s+/g, " ")
    if (term.length > 0) command(["vocabulary-add", term])
  }
  function removeVocabulary(value) { command(["vocabulary-remove", value]) }
  function previewMeterGate(db) {
    var next = Math.max(-70, Math.min(-35, Math.round(db)))
    if (next === meterGateDb) return
    meterGateDb = next
    gateTimer.restart()
  }
  function commitMeterGate(db) {
    meterGateDb = Math.max(-70, Math.min(-35, Math.round(db)))
    gateTimer.stop()
    command(["meter-gate", meterGateDb])
  }
  function setMeterPreview(on) {
    if (on === meterPreview) return
    meterPreview = on
    resetMeter()
    command([on ? "meter-preview-start" : "meter-preview-stop"])
  }
  function selectModel(kind, id) { command(["model-select", kind, id]) }
  function installModel(kind, id) { command(["model-install", kind, id]) }
  function reloadConfig() { command(["reload-config"]) }
  function checkForUpdate() {
    if (updateChecking) return
    updateChecking = true
    spawn(["omaflow", "check-update"], function() { updateChecking = false })
  }
  function requestUpdate() { spawn([host && host.trustedRunner ? host.trustedRunner : "omaflow", "update", "request"]) }
  function deferUpdate() { spawn([host && host.trustedRunner ? host.trustedRunner : "omaflow", "update", "later"]) }
  readonly property string guideBaseUrl: "https://github.com/entroit/omaflow/blob/main/docs/"
  function openGuide(page) { openExternally(guideBaseUrl + page) }

  // Journal
  // With a later day, the entry is a note to yourself for that day.
  function journalToggle(laterDay) { command(laterDay ? ["journal-toggle", laterDay] : ["journal-toggle"]) }
  function journalDiscard() { command(["journal-discard"]) }
  function journalPlay(date, id, offsetMs) { command(["journal-play", date, id, Math.max(0, Math.round(offsetMs || 0))]) }
  function journalStopPlayback() { command(["journal-stop-playback"]) }
  // Kept dictation audio uses the same player; its playback has an empty date.
  function historyPlay(id, offsetMs) { command(["history-play", id, Math.max(0, Math.round(offsetMs || 0))]) }
  function journalSetting(field, value) {
    if (field !== "folder") { preference("journal_" + field, value); return }
    // The daemon is sandboxed and can only write folders opened to it, so a
    // new journal folder is created and opened once the setting is saved.
    spawn(["omaflow", "configure", "journal_folder", JSON.stringify(value)], function() { openJournalFolder() })
  }
  function openJournalFolder() {
    if (pluginDir) spawn(["python3", pluginDir + "/tools/journal_folder.py"])
  }

  // To-dos
  // With a target, { list, due }: where the To-dos tab's Talk button sends it.
  function todoToggle(target) { command(target ? ["todo-toggle", JSON.stringify(target)] : ["todo-toggle"]) }
  function todoSetList(list) { command(["todo-list", list || ""]) }
  function todoMoveCapture(list) { command(["todo-move", list || ""]) }
  // "hover", "edit" or "" to let the card close again.
  function cardHold(kind) { command([kind === "edit" ? "card-edit" : kind === "hover" ? "card-hold" : "card-resume"]) }
  function todoCardEdit(todo, text) { command(["todo-card-edit", todo.index, todo.text, text]) }
  function todoCardRemove(todo) { command(["todo-card-remove", todo.index, todo.text]) }
  function todoDiscard() { command(["todo-discard"]) }
  // Takes the last capture's to-dos back out of the list.
  function todoUndo() { command(["todo-undo"]) }
  function todoSetting(field, value) {
    if (field !== "folder") return
    // Like the journal's, the folder is opened to the sandboxed daemon once saved.
    spawn(["omaflow", "configure", "todos_folder", JSON.stringify(value)], function() { openJournalFolder() })
  }

  // ------------------------------------------------------------ formatting
  function clock(seconds) {
    seconds = Math.max(0, Math.floor(seconds))
    return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
  }
  function isoDate(date) {
    return date.getFullYear() + "-" + String(date.getMonth() + 1).padStart(2, "0")
      + "-" + String(date.getDate()).padStart(2, "0")
  }
  function parseDate(iso) {
    var parts = String(iso).split("-")
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  }
  function todayIso() { return isoDate(new Date(nowMs)) }

  Timer {
    id: pasteTimer
    property string pending: ""
    interval: 250
    onTriggered: app.command(["history-paste", pending])
  }
  Timer {
    id: gateTimer
    interval: 70
    onTriggered: app.command(["meter-gate-preview", app.meterGateDb])
  }
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: app.checkConnection()
  }
  // Playback progress is drawn from the clock, so it ticks while playing.
  Timer {
    interval: 100
    running: app.journalPlayback !== null
    repeat: true
    onTriggered: app.nowMs = app.clockOverride || Date.now()
  }
}
