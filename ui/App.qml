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
//   setupCommand()                                     argv that starts the setup detached
Item {
  id: app
  visible: false

  property var host: null
  // A sentence for the window's toast, from an action the window started
  // itself, such as Start or Restart failing.
  signal toast(string message, bool error)

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
  // The day a journal take is for, "YYYY-MM-DD", when it is not today.
  property string takeDate: ""
  property bool todoTake: false
  property int recordingSeconds: 0
  property string transcript: ""
  property string errorText: ""
  property bool pasteSent: false
  property string pasteMode: "auto"
  property var pasteShortcut: ({modifiers: ["ctrl"], key: "V"})
  // The shortcut that pastes into the window the last take was for. With
  // Paste on Auto, a terminal takes Shift+Insert.
  property var pasteKey: ({modifiers: ["ctrl"], key: "V"})
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
  // Dictations that failed and are being transcribed again, by id.
  property var historyTranscribing: []
  property bool canUndoDelete: false
  property int historyLimit: 30

  // -------------------------------------------------------------- feedback
  property string feedback: ""
  property bool feedbackError: false
  // Goes up by one with every message, so the same words twice show twice.
  property int feedbackSerial: 0

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
  // The speech server is set up but stopped or failed, not merely loading.
  property bool asrFailed: false
  // "choose_model" when a take failed because no speech model is ready.
  property string errorAction: ""
  // The default microphone's name, or "" when the daemon cannot tell.
  property string inputDevice: ""
  property int gpuMemoryMib: 0
  property var customVocabulary: []
  property bool trainingLogEnabled: false
  property bool keepModelsLoaded: true
  property bool keepDictationAudio: false
  property int duckAudioPercent: 70
  property int meterGateDb: -60
  // On, the daemon follows the room's noise and places the threshold itself;
  // meterGateDb is then only the manual value kept for when it is off.
  property bool meterGateAuto: true
  // The threshold the meter is using right now, from the level file.
  property int meterGateEffectiveDb: -48
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
  readonly property bool updateFailed: ["rolled-back", "needs-recovery", "interrupted"].indexOf(updateState) >= 0
  // A failed update that left OmaFlow half replaced: the daemon refuses new
  // dictation until Try again puts it right.
  readonly property bool updatePausesDictation: updateState === "needs-recovery"
    || (updateState === "interrupted" && updateTransaction.blocksDictation === true)
  readonly property bool updateActionsAvailable: supportedState && updateAvailable && !updateRunning
    && !updateOffer.externalCheckoutWarning && !updateOffer.error
  readonly property bool updateDeferred: updateAvailable
    && updateDeferral.commit === verifiedUpdate.commit
    && Number(updateDeferral.untilMs || 0) > nowMs
  // Later puts the dot away until tomorrow.
  readonly property bool updateAttention: (updateAvailable && !updateDeferred) || updateRunning || updateFailed
    || Boolean(updateOffer.externalCheckoutWarning)
  // Why the last Update and restart did not start, from the command itself.
  property string updateRequestError: ""

  // ----------------------------------------------------------------- setup
  // Whether the app the OmaFlow folder brought is installed and running, and
  // the setup that puts it right (./install --from-window). The host feeds
  // the facts; `setup` is the one place that turns them into a state.
  // The version in the OmaFlow folder's manifest.json.
  property string pluginVersion: ""
  // The installed release, from its receipt; the running version stands in
  // for a development build, which has none.
  property string installedVersion: ""
  // The status file the setup writes: state, step, message, command, from.
  property var setupStatus: ({})
  // False once the host sees the setup gone while its file still says running.
  property bool setupUnitActive: true
  property int setupMisses: 0
  // The dictation key the setup keeps, as people read it, or "" for none.
  property string existingHotkey: ""
  // When Finish setup was clicked, until the setup's status file answers.
  property double setupRequestedAt: 0
  property string setupStartError: ""
  property bool setupChecking: false
  // { state, update, ... }, where update is { from, to } or null:
  //   ready
  //   needs-setup                   the app is not installed
  //   needs-update                  the folder is newer than the app
  //   running { step }              "app", "services" or "shell"
  //   needs-packages { missing, command }
  //   failed { reason, log }
  readonly property var setup: {
    var status = setupStatus || {}
    var current = installedVersion || runningVersion
    var outdated = binaryFound && (partlyUpdated || pluginVersion !== "" && current !== ""
      && pluginVersion !== current && !updateRunning && !updatePausesDictation)
    var update = outdated ? { from: current, to: pluginVersion || current } : null
    // A setup that started from an installed version is an update, also
    // once it has put the new one in place.
    var ran = setupRequestedAt > 0 || setupStartError ? update
      : status.from ? { from: String(status.from), to: pluginVersion || String(status.from) } : null
    if (setupUnitActive && (setupRequestedAt > 0 || status.state === "running"))
      return { state: "running", update: ran, step: String(status.step || "app") }
    if (setupStartError) return { state: "failed", update: ran, reason: setupStartError, log: "" }
    if (status.state === "running" || status.state === "failed")
      return { state: "failed", update: ran, log: String(status.log || ""),
        reason: status.state === "failed" && status.message ? String(status.message) : "Setup stopped before it finished." }
    if (status.state === "needs-packages" && (!binaryFound || outdated))
      return { state: "needs-packages", update: ran, missing: String(status.missing || ""), command: String(status.command || "") }
    if (!binaryFound) return { state: "needs-setup", update: null }
    if (outdated) return { state: "needs-update", update: update }
    return { state: "ready", update: null }
  }
  readonly property string setupStepText: setup.step === "shell" ? "Restarting the shell…"
    : setup.step === "services" ? "Starting the services…" : "Installing OmaFlow…"
  // Where the setup's banner is: History for a first install, Updates and
  // app for an update, whose History has dictations in it.
  readonly property string setupPage: setup.update ? "settings/updates" : "history"

  // The file the setup writes, read again whenever it changes. A setup this
  // window was waiting for that has ended says how it went; `fresh` is one
  // that ended just before this window started, as the shell restarted.
  function applySetupStatus(raw, fresh) {
    var next
    try { next = JSON.parse(raw || "{}") || {} } catch (error) { next = {} }
    var waiting = setup.state === "running" || fresh === true
    if (setupRequestedAt > 0 && Number(next.updatedAtMs || 0) >= setupRequestedAt - 2000) setupRequestedAt = 0
    replaceIfChanged("setupStatus", next)
    if (!waiting || next.state !== "ok") return
    if (next.message) toast(String(next.message), false)
    // The folder is on the installed release again, so a warning that it
    // changed outside OmaFlow is out of date; checking replaces it.
    if (updateOffer.externalCheckoutWarning) checkForUpdate()
  }
  // The host's answer to whether the setup's unit still runs. Gone twice in
  // a row, so a setup that just wrote its result is not caught between the
  // write and the read.
  function noteSetupUnit(active) {
    setupMisses = active ? 0 : setupMisses + 1
    setupUnitActive = setupMisses < 2
  }
  function finishSetup() {
    if (setup.state === "running" || !host || !host.setupCommand) return
    setupStartError = ""
    setupMisses = 0
    setupUnitActive = true
    setupRequestedAt = clockOverride || Date.now()
    spawn(host.setupCommand(), function(stdout, stderr, code) {
      if (code === 0) return
      setupRequestedAt = 0
      setupStartError = failureText(stderr, "Setup did not start")
    })
  }
  // Check again only looks at the packages; Finish setup then does the rest.
  function checkPackages() {
    if (setupChecking || !pluginDir) return
    setupChecking = true
    spawn([pluginDir + "/install", "--from-window", "--dry-run"], function(stdout, stderr, code) {
      setupChecking = false
      if (code !== 0 && setup.state === "needs-packages")
        toast("Still missing: " + setup.missing + ". Run the command, then check again.", true)
    })
  }

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
  // It is saved in History, so closing the card loses nothing.
  property bool keptInHistory: false
  property double cardClosesAt: 0
  // Where the next to-do goes, "" for the Inbox; during a capture, where it is going.
  property string todoList: ""

  // --------------------------------------------------------------- derived
  readonly property var speechCatalog: Array.isArray(modelCatalog.speech) ? modelCatalog.speech : []
  readonly property var cleanupCatalog: Array.isArray(modelCatalog.cleanup) ? modelCatalog.cleanup : []
  function downloadFor(id) { return modelDownloads[String(id)] || null }
  // The speech model download dictation waits for, or null: any one while
  // no chosen model is ready, otherwise only the chosen one's. Another model
  // downloading beside a ready one does not stop dictation.
  readonly property var speechDownload: {
    for (var i = 0; i < speechCatalog.length; i++) {
      var job = downloadFor(speechCatalog[i].id)
      if (job !== null && job.state === "downloading" && (setupUnfinished || speechCatalog[i].selected === true)) return job
    }
    return null
  }
  readonly property bool speechDownloading: speechDownload !== null
  readonly property bool setupUnfinished: modelSettings.configured === false
  // The speech model you chose, when it is not downloaded yet.
  readonly property var missingSpeechModel: speechCatalog.find(function(entry) {
    return entry.selected === true && entry.installed !== true
  }) || null
  // Your own paste keys, chosen or kept from before: then Basics offers them
  // and Hotkeys shows them.
  readonly property bool customPaste: {
    var shortcut = pasteShortcut || {}
    var label = pasteLabel(shortcut)
    return pasteMode === "custom" || (String(shortcut.key || "").length > 0 && label !== "Ctrl+V" && label !== "Shift+Insert")
  }
  // "Gemma 4 E4B" for "gemma4:e4b"; a model outside the catalog keeps its id.
  function cleanupModelName(id) {
    var entry = cleanupCatalog.find(function(model) { return model.id === id })
    return entry && entry.label ? String(entry.label) : String(id)
  }
  readonly property string hotkeyLabel: hotkeyDisplay.length > 0 ? hotkeyDisplay : "your hotkey"
  // "SUPER + SHIFT + V" as people read it: "Super Shift V". Empty when unset.
  function bindingLabel(binding) { return KeyNames.labels(binding).join("+") }
  // A paste shortcut as the card says it: "Ctrl+V", "Shift+Insert".
  function pasteLabel(shortcut) {
    var names = { ctrl: "Ctrl", shift: "Shift", alt: "Alt", super: "Super" }
    return (shortcut.modifiers || []).map(function(m) { return names[m] || m })
      .concat([KeyNames.label(String(shortcut.key || ""))]).join("+")
  }
  readonly property string journalShortcut: bindingLabel(shortcutSettings.journal)
  readonly property string windowShortcut: bindingLabel(shortcutSettings.window)
  readonly property string openJournalShortcut: bindingLabel(shortcutSettings.open_journal)
  readonly property string todoShortcut: bindingLabel(shortcutSettings.todo)
  readonly property string openTodosShortcut: bindingLabel(shortcutSettings.open_todos)

  // One line for the header: what OmaFlow is doing, and whether that is fine.
  // With Keep models loaded off, an unloaded model is the normal resting
  // state: it loads when you hold the hotkey, so OmaFlow is ready.
  readonly property bool speechLoading: !asrRunning && !asrFailed && keepModelsLoaded
  // The daemon and this window are from different versions, so either may
  // misread the other until the update finishes.
  readonly property bool partlyUpdated: connected && !supportedState
  readonly property string statusTone: setup.state === "running" ? "yellow"
    : !binaryFound || !connected || asrFailed || updatePausesDictation ? "red"
    : phase === "recording" ? "red"
    : setupUnfinished || speechDownloading || speechLoading ? "yellow"
    : partlyUpdated ? "red"
    : "green"
  readonly property string statusText: setup.state === "running" ? setupStepText
    : !binaryFound ? "Not installed yet"
    : !connected ? (pendingAction === "start" ? "Starting OmaFlow" : "OmaFlow stopped")
    : phase === "recording" ? (journalTake ? "Recording journal entry" : todoTake ? "Recording to-dos" : "Recording")
    : phase === "processing" ? (journalTake ? "Writing it down" : todoTake ? "Adding to-dos"
      : cleanupLevel === "medium" ? "Transcribing and cleaning up" : "Transcribing")
    : updatePausesDictation ? "Dictation paused by an update"
    : speechDownloading ? "Downloading the speech model"
    : setupUnfinished ? (missingSpeechModel ? "Download the speech model" : "Choose a speech model")
    : asrFailed ? (pendingAction === "restart" ? "Restarting the speech model" : "Speech model stopped")
    : speechLoading ? "Speech model loading"
    : partlyUpdated ? "Partly updated"
    : "Ready, hold " + hotkeyLabel
  // What the header offers next to that line: "install" (the setup's
  // banner), "models" and "updates" make the line itself a link, "start" and
  // "restart" add a button.
  readonly property string statusAction: setup.state === "running" || !binaryFound ? "install"
    : !connected ? "start"
    : phase === "recording" || phase === "processing" ? ""
    : updatePausesDictation ? "updates"
    : setupUnfinished || speechDownloading ? "models"
    : asrFailed ? "restart"
    : partlyUpdated && !speechLoading ? "updates"
    : ""

  // ------------------------------------------------------------ state file
  function applyState(raw) {
    var next
    try { next = JSON.parse(raw || "{}") } catch (error) { return false }
    phase = String(next.phase || "idle")
    latched = Boolean(next.latched)
    journalTake = Boolean(next.journal_take)
    takeDate = /^\d{4}-\d{2}-\d{2}$/.test(String(next.take_date || "")) ? String(next.take_date) : ""
    todoTake = Boolean(next.todo_take)
    pasteSent = Boolean(next.paste_sent)
    transcript = String(next.text || "")
    errorText = String(next.error || "")
    replaceIfChanged("history", Array.isArray(next.history) ? next.history : [])
    replaceIfChanged("historyTranscribing", Array.isArray(next.history_transcribing) ? next.history_transcribing : [])
    var gate = Number(next.meter_gate_db)
    meterGateDb = isFinite(gate) ? Math.max(-70, Math.min(-35, Math.round(gate))) : -60
    meterGateAuto = next.meter_gate_auto !== false
    pasteMode = ["auto", "ctrl-v", "shift-insert", "clipboard", "custom"].indexOf(next.paste_mode) >= 0
      ? String(next.paste_mode) : "auto"
    if (next.paste_shortcut && Array.isArray(next.paste_shortcut.modifiers)
        && typeof next.paste_shortcut.key === "string")
      replaceIfChanged("pasteShortcut", next.paste_shortcut)
    replaceIfChanged("pasteKey", next.paste_key && Array.isArray(next.paste_key.modifiers)
      && typeof next.paste_key.key === "string" ? next.paste_key : {modifiers: ["ctrl"], key: "V"})
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
    asrFailed = next.asr_failed === true
    errorAction = String(next.error_action || "")
    inputDevice = String(next.input_device || "")
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
    keptInHistory = next.kept_in_history === true
    var timer = next.card_timer || null
    cardTotalMs = timer ? Number(timer.total_ms) : 0
    var closesAt = timer && timer.remaining_ms !== null && timer.remaining_ms !== undefined
      ? lastPublishedAt + Number(timer.remaining_ms) : 0
    // Republished every second; only a real change moves the ring.
    if (Math.abs(closesAt - cardClosesAt) > 80) cardClosesAt = closesAt
    connected = lastPublishedAt > Date.now() - 15000
    // A state file left behind by a daemon that stopped mid-take.
    if (!connected) phase = "idle"
    keepModelsLoaded = next.keep_models_loaded !== false
    keepDictationAudio = next.keep_dictation_audio === true
    historyLimit = Number(next.history_limit || 0)
    var message = String(next.feedback || "")
    var serial = Number(next.feedback_serial)
    var changed = message !== feedback
    feedback = message
    feedbackError = Boolean(next.feedback_error)
    // A daemon without the serial still shows a new message once.
    if (next.feedback_serial !== undefined && isFinite(serial)) feedbackSerial = serial
    else if (changed) feedbackSerial += 1
    recordingSeconds = Math.floor(Number(next.recording_elapsed_ms || 0) / 1000)
    var duck = Number(next.duck_audio_percent)
    duckAudioPercent = isFinite(duck) ? Math.max(0, Math.min(100, Math.round(duck))) : 70
    if (phase !== "recording" && !meterPreview) resetMeter()
    return true
  }

  function replaceIfChanged(name, value) {
    if (JSON.stringify(app[name]) !== JSON.stringify(value)) app[name] = value
  }

  // The level file: "level dbfs detected bar×13 threshold".
  function applyLevel(raw) {
    if (phase !== "recording" && !meterPreview) return
    var values = String(raw || "").trim().split(/\s+/)
    var level = Number(values[0])
    if (!isFinite(level)) return
    micLevel = Math.max(0, Math.min(1, level))
    micDetected = values[2] === "1"
    var gate = Number(values[16])
    if (values.length > 16 && isFinite(gate)) meterGateEffectiveDb = Math.max(-70, Math.min(-35, Math.round(gate)))
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
      else if (code !== 0 && value === null) callback(null, String(stderr || "OmaFlow did not answer. If it is stopped, start it from the top of the window.").trim())
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

  // The last line a command printed on failure, as a sentence:
  // "omaflow: could not start OmaFlow: …" reads "Could not start OmaFlow: ….".
  function failureText(stderr, fallback) {
    var line = String(stderr || "").trim().split("\n").pop().replace(/^omaflow:\s*/, "").trim()
    if (!line) line = fallback
    line = line.charAt(0).toUpperCase() + line.slice(1)
    return /[.!?]$/.test(line) ? line : line + "."
  }
  // Runs a command whose failure the window has to say, since nothing else will.
  function commandOrSay(args, fallback, done) {
    spawn(["omaflow"].concat(args.map(String)), function(stdout, stderr, code) {
      if (done) done()
      if (code !== 0) app.toast(failureText(stderr, fallback), true)
    })
  }
  // "start" or "restart" while that command runs, so the header says so and
  // a second click does not start it twice.
  property string pendingAction: ""
  function runPending(action, args, fallback) {
    if (pendingAction) return
    pendingAction = action
    commandOrSay(args, fallback, function() { app.pendingAction = "" })
  }

  function start() { runPending("start", ["launch"], "OmaFlow did not start. Run omaflow launch in a terminal to see why.") }
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
  // A dictation that failed, transcribed again and kept in History, not pasted.
  function retryHistory(id) { commandOrSay(["history-retry", id], "OmaFlow could not transcribe it again. Run omaflow history-retry " + id + " in a terminal to see why.") }
  function isTranscribing(id) { return historyTranscribing.indexOf(Number(id)) >= 0 }
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
  // Setting a threshold turns the automatic one off, in the daemon too.
  function commitMeterGate(db) {
    meterGateDb = Math.max(-70, Math.min(-35, Math.round(db)))
    meterGateAuto = false
    gateTimer.stop()
    command(["meter-gate", meterGateDb])
  }
  // Switching to manual starts from the threshold in use, so the marker stays
  // where it was instead of jumping to an old value.
  function setMeterGateAuto(on) {
    if (on === meterGateAuto) return
    if (on) { meterGateAuto = true; preference("meter_gate_auto", true) }
    else commitMeterGate(meterGateEffectiveDb)
  }
  function setMeterPreview(on) {
    if (on === meterPreview) return
    meterPreview = on
    resetMeter()
    command([on ? "meter-preview-start" : "meter-preview-stop"])
  }
  function restartSpeech() { runPending("restart", ["restart-speech"], "The speech model did not restart. Run omaflow restart-speech in a terminal to see why.") }
  function selectModel(kind, id) { command(["model-select", kind, id]) }
  function installModel(kind, id) { command(["model-install", kind, id]) }
  function cancelModel(kind, id) { commandOrSay(["model-cancel", kind, id], "The download could not be stopped. Run omaflow model-cancel " + kind + " " + id + " in a terminal to see why.") }
  function checkForUpdate() {
    if (updateChecking) return
    updateChecking = true
    updateRequestError = ""
    spawn(["omaflow", "check-update"], function() { updateChecking = false })
  }
  function requestUpdate() {
    updateRequestError = ""
    spawn([host && host.trustedRunner ? host.trustedRunner : "omaflow", "update", "request"], function(stdout, stderr, code) {
      if (code === 0) return
      // The command says what went wrong and what to do, in a sentence.
      updateRequestError = failureText(stderr, "OmaFlow did not answer. Run omaflow update request in a terminal to see why.")
    })
  }
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
    if (field === "remind_before") { preference("todos_remind_before", value); return }
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
