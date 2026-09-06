import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "entroit.omaflow"
  ipcTarget: "entroit.omaflow"

  property bool editShortcut: false
  property bool editModels: false
  property var modelSettings: ({})
  property var shortcutSettings: ({})
  property string personalConfigPath: configHome + "/omaflow/config.toml"
  property bool reducedMotion: false
  property bool keepModelsLoaded: true
  property string phase: "idle"
  property bool pasteSent: false
  property bool latched: false
  property string transcript: ""
  property string errorText: ""
  property var history: []
  property bool connected: false
  // False once the probe proves `omaflow` is not on PATH: the checkout was
  // cloned by `omarchy plugin add`, which copies files but never builds.
  property bool binaryFound: true
  readonly property string pluginDir: configHome + "/omarchy/plugins/entroit.omaflow"
  property string idlePage: "history"
  property real micLevel: 0
  property bool micDetected: false
  property var micBars: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  // Last ~0.4 s of meter ticks, newest last. The overlay scrolls this so a
  // flat stretch shows a dropped microphone before the hotkey is released.
  readonly property int waveSamples: 12
  property var waveHistory: []
  property int meterGateDb: -60
  property string pasteMode: "auto"
  property int errorVisibleMs: 5000
  property int noticeVisibleMs: 5000
  property bool trainingLogEnabled: false
  property string hotkeyDisplay: "Custom binding"
  property var customVocabulary: []
  property bool canUndoDelete: false
  property bool asrRunning: false
  property bool cleanupAvailable: false
  property bool cleanupLoaded: false
  property int gpuMemoryMib: 0
  property bool cursorActive: false
  property int selectedHistoryIndex: 0
  property double currentTimeMs: Date.now()
  property int stateVersion: 1
  property string runningVersion: ""
  property string checkoutVersion: ""
  property bool needsRebuild: false
  property int updateBehind: 0
  property string updateRemoteVersion: ""
  property double updateCheckedAtMs: 0
  property string updateError: ""
  property string historyQuery: ""
  property string selectedEntryId: ""
  property string feedback: ""
  property bool feedbackError: false
  property double lastPublishedAt: 0
  property int recordingSeconds: 0
  property bool cleanupEnabled: true
  property string writingStyle: "natural"
  property int historyLimit: 30
  property bool eraseConfirm: false
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config"
  readonly property var selectedEntry: root.history.find(function(e) { return String(e.id) === root.selectedEntryId }) || null
  function preference(key, value) { Quickshell.execDetached(["omaflow", "configure", key, JSON.stringify(value)]) }


  // The panel is loaded from the checkout while the daemon is a compiled
  // binary, so a git pull without a rebuild leaves the two out of step. The
  // daemon reports both versions and the contract version of this JSON.
  readonly property bool supportedState: root.stateVersion === 2
  readonly property bool updateAvailable: root.updateBehind > 0
  readonly property bool updateAttention: root.needsRebuild
    || root.updateAvailable || (root.connected && !root.supportedState)

  readonly property bool meterPreviewActive: phase === "idle"
    && opened && idlePage === "settings"
  readonly property bool voiceDetected: micDetected
    && (phase === "recording" || meterPreviewActive)
  readonly property bool silent: !voiceDetected
  readonly property int overlayWidth: phase === "recording"
    ? Style.space(latched ? 360 : 400)
    : phase === "processing" || phase === "success" || phase === "notice"
      ? Style.space(350)
      : Style.space(520)
  readonly property int overlayHeight: phase === "recording"
    ? Style.space(80)
    : phase === "processing" || phase === "success" || phase === "notice"
      ? Style.space(64)
      : phase === "result"
        ? Style.space(290)
        : phase === "error"
          ? Style.space(180)
          : Style.space(470)

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  function applyState(raw) {
    try {
      var next = JSON.parse(raw || "{}")
      var previousPhase = root.phase
      root.phase = String(next.phase || "idle")
      root.latched = Boolean(next.latched)
      root.pasteSent = Boolean(next.paste_sent)
      root.transcript = String(next.text || "")
      root.errorText = String(next.error || "")
      root.history = Array.isArray(next.history) ? next.history : []
      var nextGate = Number(next.meter_gate_db)
      root.meterGateDb = isFinite(nextGate)
        ? Math.max(-70, Math.min(-35, Math.round(nextGate))) : -60
      root.pasteMode = ["auto", "ctrl-v", "shift-insert", "clipboard"].indexOf(next.paste_mode) >= 0
        ? String(next.paste_mode) : "auto"
      var nextErrorTimeout = Number(next.error_visible_ms)
      root.errorVisibleMs = isFinite(nextErrorTimeout)
        ? Math.max(1000, Math.min(60000, Math.round(nextErrorTimeout))) : 5000
      var nextNoticeTimeout = Number(next.notice_visible_ms)
      root.noticeVisibleMs = isFinite(nextNoticeTimeout)
        ? Math.max(500, Math.min(60000, Math.round(nextNoticeTimeout))) : 5000
      if (JSON.stringify(root.modelSettings) !== JSON.stringify(next.model_settings || {})) root.modelSettings = next.model_settings || ({})
      if (JSON.stringify(root.shortcutSettings) !== JSON.stringify(next.shortcut_settings || {})) root.shortcutSettings = next.shortcut_settings || ({})
      root.personalConfigPath = String(next.config_path || root.configHome + "/omaflow/config.toml")
      root.trainingLogEnabled = Boolean(next.training_log_enabled)
      root.hotkeyDisplay = String(next.hotkey_display || "Custom binding")
      root.customVocabulary = Array.isArray(next.custom_vocabulary)
        ? next.custom_vocabulary : []
      root.canUndoDelete = Boolean(next.can_undo_delete)
      root.asrRunning = Boolean(next.asr_running)
      root.cleanupLoaded = Boolean(next.cleanup_loaded)
      root.cleanupAvailable = Boolean(next.cleanup_available)
      root.gpuMemoryMib = Math.max(0, Number(next.gpu_memory_mib) || 0)
      root.selectedHistoryIndex = Math.max(0,
        Math.min(root.selectedHistoryIndex, root.history.length - 1))
      var nextStateVersion = Number(next.state_version)
      root.stateVersion = isFinite(nextStateVersion) ? Math.round(nextStateVersion) : 1
      root.runningVersion = String(next.running_version || "")
      root.checkoutVersion = String(next.checkout_version || "")
      root.needsRebuild = Boolean(next.needs_rebuild)
      var nextBehind = Number(next.update_behind)
      root.updateBehind = isFinite(nextBehind) ? Math.max(0, Math.round(nextBehind)) : 0
      root.updateRemoteVersion = String(next.update_remote_version || "")
      var nextChecked = Number(next.update_checked_at_ms)
      root.updateCheckedAtMs = isFinite(nextChecked) ? nextChecked : 0
      root.updateError = String(next.update_error || "")
      root.lastPublishedAt = Number(next.published_at_ms || 0)
      root.connected = root.lastPublishedAt > Date.now() - 15000
      root.cleanupEnabled = Boolean(next.cleanup_enabled)
      root.writingStyle = String(next.style || "natural")
      root.reducedMotion = Boolean(next.reduced_motion)
      root.keepModelsLoaded = next.keep_models_loaded !== false
      root.historyLimit = Number(next.history_limit || 0)
      root.feedback = String(next.feedback || "")
      root.feedbackError = Boolean(next.feedback_error)
      root.recordingSeconds = Math.floor(Number(next.recording_elapsed_ms || 0) / 1000)

      if (root.phase !== "recording" && !root.meterPreviewActive) root.resetMeter()

      if (root.phase !== "idle" && (previousPhase === "idle" || root.opened))
        root.controller.hide()
    } catch (error) {
      reloadTimer.restart()
    }
  }

  function openHistory() {
    root.idlePage = "history"
    root.cursorActive = false
    root.controller.show()
    stateFile.reload()
  }

  function togglePanel() {
    if (!root.connected) {
      root.startOmaFlow()
      return
    }
    if (root.phase === "recording" && root.latched) {
      Quickshell.execDetached(["omaflow", "stop"])
      return
    }
    if (["result","success","error","notice"].indexOf(root.phase) >= 0) {
      root.dismissResult()
      panelReopenTimer.restart()
      return
    }
    if (root.phase !== "idle") return
    if (root.opened) root.controller.hide()
    else root.openHistory()
  }

  function dismissResult() {
    Quickshell.execDetached(["omaflow", "close"])
    root.controller.hide()
  }

  function formatHistoryTime(value) {
    var milliseconds = Number(value)
    if (!isFinite(milliseconds) || milliseconds <= 0) return "Earlier"
    var date = new Date(milliseconds)
    var age = Math.max(0, root.currentTimeMs - milliseconds)
    if (age < 60000) return "Just now"
    if (age < 3600000) return Math.floor(age / 60000) + " min ago"
    var now = new Date(root.currentTimeMs)
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    var entryDay = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
    if (entryDay === today) return Math.floor(age / 3600000) + " h ago"
    if (entryDay === today - 86400000)
      return "Yesterday " + Qt.formatDateTime(date, "HH:mm")
    if (age < 604800000) return Qt.formatDateTime(date, "ddd HH:mm")
    return Qt.formatDateTime(date, "dd MMM yyyy HH:mm")
  }

  property string pendingPasteId: ""
  function pasteHistory(id) { root.pendingPasteId = String(id); root.controller.hide(); historyPasteTimer.restart() }
  Timer { id:historyPasteTimer; interval:250; onTriggered:Quickshell.execDetached(["omaflow","history-paste",root.pendingPasteId]) }

  function copyHistory(id) {
    var value = String(id)
    Quickshell.execDetached(["omaflow", "history-copy", value])
  }

  function deleteHistory(id) {
    Quickshell.execDetached(["omaflow", "history-delete", String(id)])
  }

  function undoDelete() {
    Quickshell.execDetached(["omaflow", "history-undo"])
  }

  function clearHistory() {
    Quickshell.execDetached(["omaflow", "history-clear"])
  }

  function addVocabulary(value) {
    var term = String(value || "").trim().replace(/\s+/g, " ")
    if (term.length === 0) return
    Quickshell.execDetached(["omaflow", "vocabulary-add", term])
  }

  function removeVocabulary(value) {
    Quickshell.execDetached(["omaflow", "vocabulary-remove", String(value)])
  }

  function movePanelCursor(dx, dy) {
    if (dx !== 0) {
      root.idlePage = dx < 0 ? "history" : "settings"
      root.cursorActive = true
      return
    }
    root.cursorActive = true
    if (idlePageLoader.item && idlePageLoader.item.moveCursor)
      idlePageLoader.item.moveCursor(dy)
  }

  function activatePanelCursor() {
    root.cursorActive = true
    if (idlePageLoader.item && idlePageLoader.item.activateCursor)
      idlePageLoader.item.activateCursor()
  }

  function editHotkey() { root.editShortcut = !root.editShortcut }

  function openEditor(path) {
    root.controller.hide()
    Quickshell.execDetached(["omarchy-launch-editor", path])
  }

  function checkForUpdate() { if (!checkUpdateProcess.running) checkUpdateProcess.running = true }
  Process {
    id:checkUpdateProcess
    command:["omaflow","check-update"]
    onExited: stateFile.reload()
  }

  function applyUpdate() {
    root.controller.hide()
    Quickshell.execDetached(["omaflow", "apply-update"])
  }

  function finishUpdate() {
    root.controller.hide()
    Quickshell.execDetached(["omaflow", "rebuild"])
  }

  function quitOmaFlow() {
    root.controller.hide()
    Quickshell.execDetached(["omaflow", "quit"])
  }

  function startOmaFlow() {
    Quickshell.execDetached(["omaflow", "launch"])
  }

  function previewMeterGate(db) {
    var next = Math.max(-70, Math.min(-35, Math.round(db)))
    if (next === root.meterGateDb) return
    root.meterGateDb = next
    meterGateTimer.restart()
  }

  function commitMeterGate(db) {
    var next = Math.max(-70, Math.min(-35, Math.round(db)))
    root.meterGateDb = next
    meterGateTimer.stop()
    Quickshell.execDetached(["omaflow", "meter-gate", String(next)])
  }

  function setPasteMode(mode) {
    if (mode === root.pasteMode) return
    root.pasteMode = mode
    Quickshell.execDetached(["omaflow", "paste-mode", mode])
  }

  function resetMeter() {
    root.micLevel = 0
    root.micDetected = false
    root.micBars = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    root.waveHistory = []
  }

  Process {
    id: binaryProbe
    command: ["sh", "-c", "command -v omaflow"]
    running: true
    onExited: function(code) { root.binaryFound = code === 0 }
  }

  // Everything here is about the visit, not the data: a search you typed and
  // the row you were on. Reopening the panel should show your history, not the
  // tail of the last visit.
  onOpenedChanged: {
    if (root.opened) { binaryProbe.running = true; return }
    root.historyQuery = ""
    root.cursorActive = false
    root.selectedHistoryIndex = 0
    root.selectedEntryId = ""
  }

  onMeterPreviewActiveChanged: {
    root.resetMeter()
    Quickshell.execDetached(["omaflow", meterPreviewActive
      ? "meter-preview-start" : "meter-preview-stop"])
  }

  Component.onDestruction: Quickshell.execDetached(["omaflow", "meter-preview-stop"])

  FileView {
    id: stateFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omaflow-state.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: root.connected = false
    onFileChanged: reload()
  }

  FileView {
    id: levelFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omaflow-level"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var values = text().trim().split(/\s+/)
      var nextLevel = Number(values[0])
      if (isFinite(nextLevel) && (root.phase === "recording" || root.meterPreviewActive)) {
        root.micLevel = Math.max(0, Math.min(1, nextLevel))
        root.micDetected = values[2] === "1"
        var nextBars = []
        for (var index = 0; index < 13; index++) {
          var nextBar = Number(values[index + 3])
          nextBars.push(isFinite(nextBar)
            ? Math.max(0, Math.min(1, nextBar)) : root.micLevel)
        }
        root.micBars = nextBars
        var history = root.waveHistory.slice(-(root.waveSamples - 1))
        history.push(root.micLevel)
        root.waveHistory = history
      }
    }
    onFileChanged: reload()
  }

  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      if (root.lastPublishedAt < Date.now() - 15000) {
        root.connected = false
        root.phase = "idle"
      }
      stateFile.reload()
    }
  }

  Timer {
    id: reloadTimer
    interval: 12
    onTriggered: stateFile.reload()
  }

  Timer { id: panelReopenTimer; interval:100; onTriggered:root.openHistory() }

  Timer {
    id: meterGateTimer
    interval: 70
    onTriggered: Quickshell.execDetached([
      "omaflow", "meter-gate-preview", String(root.meterGateDb)
    ])
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.currentTimeMs = Date.now()
  }

  Component {
    id: pillBarsIcon

    Item {
      readonly property color iconColor: root.phase === "recording"
        || root.phase === "error"
        ? Color.urgent
        : root.phase === "processing" ? Color.accent : barButton.foreground

      Repeater {
        model: [
          { "x": 1, "y": 6, "width": 2.5, "height": 4 },
          { "x": 4.75, "y": 3, "width": 2.5, "height": 10 },
          { "x": 8.5, "y": 1, "width": 2.5, "height": 14 },
          { "x": 12.25, "y": 5, "width": 2.5, "height": 6 }
        ]

        Rectangle {
          required property var modelData
          x: parent.width * modelData.x / 16
          y: parent.height * modelData.y / 16
          width: parent.width * modelData.width / 16
          height: parent.height * modelData.height / 16
          radius: width / 2
          color: parent.iconColor
        }
      }

      // A quiet dot is the only ambient signal that a release exists; the
      // update check never notifies, so nothing else says so.
      Rectangle {
        visible: root.updateAttention && root.phase === "idle"
        width: parent.width * 0.3
        height: width
        radius: width / 2
        x: parent.width - width
        y: 0
        color: Color.accent
      }
    }
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: ""
    iconComponent: pillBarsIcon
    foreground: root.bar ? root.bar.foreground : Color.foreground
    active: root.phase === "recording" || root.phase === "error"
    activeColor: Color.urgent
    slotSize: Style.bar.statusSlot
    tooltipText: root.phase === "recording"
      ? (root.latched ? "OmaFlow is recording — press the hotkey again or click to stop"
        : "OmaFlow is recording — release the hotkey to finish")
      : root.phase === "processing"
        ? "OmaFlow is transcribing and formatting"
        : root.connected
          ? "OmaFlow — transcript history and settings"
          : "OmaFlow is stopped — click to start"
    onPressed: root.togglePanel()

  }

  KeyboardPanel {
    id: panel
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened && root.phase === "idle"
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(Style.space(610), Style.space(700))

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      FocusReveal { scope:keyCatcher }
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.selectedEntryId) root.selectedEntryId = ""
          else root.controller.hide()
          event.accepted = true
        } else if (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)) {
          if (idlePageLoader.item) idlePageLoader.item.focusSearch()
          event.accepted = true
        } else if (keyCatcher.activeFocus && root.idlePage === "history" && !root.selectedEntryId) {
          if (event.key === Qt.Key_Down || event.text === "j") { root.movePanelCursor(0, 1); event.accepted = true }
          else if (event.key === Qt.Key_Up || event.text === "k") { root.movePanelCursor(0, -1); event.accepted = true }
          else if (event.key === Qt.Key_Return) { root.activatePanelCursor(); event.accepted = true }
          else if (event.text === "/") { idlePageLoader.item.focusSearch(); event.accepted = true }
        }
      }

      Loader {
        id: idlePageLoader
        anchors.fill: parent
        sourceComponent: idleView
      }
    }
  }

  PanelWindow {
    id: recordingOverlay
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    visible: root.connected && root.supportedState && root.phase !== "idle"
      && (!Hyprland.focusedMonitor || !screen || screen.name === Hyprland.focusedMonitor.name)
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omaflow"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region { item: recordingCard }

    BorderSurface {
      id: recordingCard
      // The recording row is sized by its content so nothing is clipped;
      // the other cards wrap text and keep their fixed widths.
      width: Math.min(root.phase === "recording" && cardContent.item
        ? cardContent.item.implicitWidth + Style.space(24) : root.overlayWidth,
        parent.width - Style.space(24))
      height: Math.min(root.overlayHeight, parent.height - Style.space(90))
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(67)
      color: Util.alpha(Color.popups.background, 0.98)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border,
                                     Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      clip: true

      Behavior on width { NumberAnimation { duration: root.reducedMotion ? 0 : 120; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: root.reducedMotion ? 0 : 120; easing.type: Easing.OutCubic } }

      Loader {
        id: cardContent
        anchors.fill: parent
        anchors.margins: Style.space(12)
        sourceComponent: root.phase === "recording" ? recordingView
          : root.phase === "processing" ? processingView
          : root.phase === "success" ? successView
          : root.phase === "notice" ? noticeView
          : root.phase === "result" ? resultView
          : errorView
      }
    }
  }

  component Waveform: Item {
    implicitHeight: Style.space(40)
    implicitWidth: Style.space(root.waveSamples * 7 - 3)
    clip: true

    Row {
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      spacing: Style.space(3)

      Repeater {
        model: root.waveSamples

        Rectangle {
          required property int index
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(4)
          // Bars older than the history are drawn as rest so the row is full
          // from the first tick and grows in from the right.
          readonly property int historyIndex: index - (root.waveSamples - root.waveHistory.length)
          readonly property real level: historyIndex >= 0 ? Number(root.waveHistory[historyIndex]) : 0
          height: Style.space(4) + Style.space(36) * level
          radius: width / 2
          color: Color.accent
          opacity: root.silent && index === root.waveSamples - 1 ? 0.38
            : 0.45 + 0.55 * Math.min(1, level + 0.25)

          Behavior on height {
            NumberAnimation { duration: root.reducedMotion ? 0 : 40; easing.type: Easing.OutQuad }
          }
        }
      }
    }
  }

  Component {
    id: recordingView

    RowLayout {
      spacing: Style.space(12)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          // The waveform already shows when speech is picked up. Swapping this
          // label on every pause makes the card flicker while dictating, so
          // the heading stays steady and only reports the recording mode.
          text: "Listening"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          // Locked mode has a Stop button; a hint would only repeat it.
          visible: !root.latched
          textFormat: Text.PlainText
          text: "Release the hotkey to finish"
          color: Util.alpha(Color.popups.text, 0.58)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        // Locked recording: the lock says so, Stop says how to end it.
        visible: root.latched
        textFormat: Text.PlainText
        text: "󰌾"
        color: Util.alpha(Color.popups.text, 0.58)
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
      }

      Text {
        textFormat: Text.PlainText
        text: Math.floor(root.recordingSeconds / 60) + ":" + String(root.recordingSeconds % 60).padStart(2, "0")
        color: Util.alpha(Color.popups.text, 0.58)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.features: { "tnum": 1 }
      }

      Waveform { Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }

      ActionButton {
        visible: root.latched
        text: "Stop"
        foreground: Color.popups.text
        background: Util.alpha(Color.urgent, 0.18)
        bordered: true
        onClicked: Quickshell.execDetached(["omaflow", "stop"])
      }
    }
  }

  Component {
    id: processingView

    RowLayout {
      spacing: Style.space(12)

      Text {
        textFormat: Text.PlainText
        text: "󰔟"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
        RotationAnimation on rotation {
          from: 0
          to: 360
          duration: 800
          loops: Animation.Infinite
          running: root.phase === "processing" && !root.reducedMotion
        }
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: "Transcribing and formatting…"
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      ActionButton {
        text: "Cancel"
        foreground: Color.popups.text
        onClicked: Quickshell.execDetached(["omaflow", "cancel"])
      }
    }
  }

  Component {
    id: successView

    RowLayout {
      spacing: Style.space(12)

      Text {
        textFormat: Text.PlainText
        text: "✓"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: "Copied and pasted"
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

    }
  }

  Component {
    id: noticeView

    RowLayout {
      spacing: Style.space(12)

      Text {
        textFormat: Text.PlainText
        text: "󰍭"
        color: Util.alpha(Color.popups.text, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: "Nothing heard"
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Item {
        id: noticeCloseCountdown
        Layout.preferredWidth: Style.space(30)
        Layout.preferredHeight: Style.space(30)
        property real progress: 1

        onProgressChanged: noticeCountdownCanvas.requestPaint()

        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.space(3)
          radius: width / 2
          color: noticeCloseMouse.containsMouse
            ? Util.alpha(Color.popups.text, 0.12)
            : Util.alpha(Color.popups.text, 0.055)
        }

        Canvas {
          id: noticeCountdownCanvas
          anchors.fill: parent
          onPaint: {
            var context = getContext("2d")
            var center = width / 2
            var radius = Math.max(1, center - Style.space(2))
            context.clearRect(0, 0, width, height)
            context.lineWidth = Math.max(2, Style.space(2))
            context.lineCap = "round"
            context.strokeStyle = Util.alpha(Color.popups.text, 0.16)
            context.beginPath()
            context.arc(center, center, radius, 0, Math.PI * 2)
            context.stroke()
            context.strokeStyle = Color.popups.text
            context.beginPath()
            context.arc(center, center, radius, -Math.PI / 2,
              -Math.PI / 2 + Math.PI * 2 * noticeCloseCountdown.progress)
            context.stroke()
          }
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "Esc"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: noticeCloseMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.dismissResult()
        }

        NumberAnimation on progress {
          from: 1
          to: 0
          duration: root.noticeVisibleMs
          running: root.phase === "notice"
        }
      }
    }
  }

  Component {
    id: resultView

    ColumnLayout {
      spacing: Style.space(9)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.errorText ? "Copy failed" : root.pasteSent ? "Copied and pasted" : root.pasteMode === "clipboard" ? "Ready on your clipboard" : "Copied, not pasted"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Item {
          id: closeCountdown
          Layout.preferredWidth: Style.space(30)
          Layout.preferredHeight: Style.space(30)
          property real progress: 1

          onProgressChanged: countdownCanvas.requestPaint()

          Rectangle {
            anchors.fill: parent
            anchors.margins: Style.space(3)
            radius: width / 2
            color: closeMouse.containsMouse
              ? Util.alpha(Color.popups.text, 0.12)
              : Util.alpha(Color.popups.text, 0.055)
          }

          Canvas {
            id: countdownCanvas
            anchors.fill: parent
            onPaint: {
              var context = getContext("2d")
              var center = width / 2
              var radius = Math.max(1, center - Style.space(2))
              context.clearRect(0, 0, width, height)
              context.lineWidth = Math.max(2, Style.space(2))
              context.lineCap = "round"
              context.strokeStyle = Util.alpha(Color.popups.text, 0.16)
              context.beginPath()
              context.arc(center, center, radius, 0, Math.PI * 2)
              context.stroke()
              context.strokeStyle = Color.accent
              context.beginPath()
              context.arc(center, center, radius, -Math.PI / 2,
                -Math.PI / 2 + Math.PI * 2 * closeCountdown.progress)
              context.stroke()
            }
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "Esc"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.dismissResult()
          }
        }
      }

      Text {
        Layout.fillWidth:true
        visible:root.feedbackError && root.feedback.length>0
        text:root.feedback
        textFormat:Text.PlainText
        wrapMode:Text.Wrap
        color:Color.urgent
        font.family:Style.font.family
        font.pixelSize:Style.font.caption
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: root.errorText
          ? "Your dictation is available below. Try Copy again when the clipboard is available."
          : root.pasteSent
          ? "Review the warning and text below. Check the destination before pasting again. This card stays until you dismiss it."
          : "Your text is on the clipboard. Focus the destination and paste, or copy it again below. This card stays until you dismiss it."
        color: Util.alpha(Color.popups.text, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentWidth: width
        contentHeight: resultText.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Text {
          id: resultText
          width: parent.width
          textFormat: Text.PlainText
          text: root.transcript
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }
      }

      RowLayout {
        Layout.fillWidth: true
        Item { Layout.fillWidth: true }

        ActionButton {
          text: "Copy again"
          foreground: Color.popups.text
          background: Util.alpha(Color.accent, 0.22)
          bordered: true
          onClicked: {
            Quickshell.execDetached(["omaflow", "copy"])
          }
        }
      }
    }
  }

  Component {
    id: errorView

    ColumnLayout {
      spacing: Style.space(9)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "Dictation failed"
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Item {
          id: errorCloseCountdown
          Layout.preferredWidth: Style.space(30)
          Layout.preferredHeight: Style.space(30)
          property real progress: 1

          onProgressChanged: errorCountdownCanvas.requestPaint()

          Rectangle {
            anchors.fill: parent
            anchors.margins: Style.space(3)
            radius: width / 2
            color: errorCloseMouse.containsMouse
              ? Util.alpha(Color.popups.text, 0.12)
              : Util.alpha(Color.popups.text, 0.055)
          }

          Canvas {
            id: errorCountdownCanvas
            anchors.fill: parent
            onPaint: {
              var context = getContext("2d")
              var center = width / 2
              var radius = Math.max(1, center - Style.space(2))
              context.clearRect(0, 0, width, height)
              context.lineWidth = Math.max(2, Style.space(2))
              context.lineCap = "round"
              context.strokeStyle = Util.alpha(Color.popups.text, 0.16)
              context.beginPath()
              context.arc(center, center, radius, 0, Math.PI * 2)
              context.stroke()
              context.strokeStyle = Color.popups.text
              context.beginPath()
              context.arc(center, center, radius, -Math.PI / 2,
                -Math.PI / 2 + Math.PI * 2 * errorCloseCountdown.progress)
              context.stroke()
            }
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "Esc"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: errorCloseMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.dismissResult()
          }

          NumberAnimation on progress {
            from: 1
            to: 0
            duration: root.errorVisibleMs
            running: root.phase === "error"
          }
        }
      }

      Text {
        Layout.fillWidth: true
        Layout.fillHeight: true
        textFormat: Text.PlainText
        text: root.errorText
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        elide: Text.ElideRight
        maximumLineCount: 4
      }

    }
  }

  Component {
    id: idleView

    ColumnLayout {
      function moveCursor(dy) {
        if (pageLoader.item && pageLoader.item.moveCursor) pageLoader.item.moveCursor(dy)
      }
      function activateCursor() {
        if (pageLoader.item && pageLoader.item.activateCursor) pageLoader.item.activateCursor()
      }
      function deleteCursor() {
        if (pageLoader.item && pageLoader.item.deleteCursor) pageLoader.item.deleteCursor()
      }
      function focusSearch() {
        root.idlePage = "history"
        if (pageLoader.item && pageLoader.item.focusSearch) pageLoader.item.focusSearch()
      }
      spacing: Style.space(12)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: "󰍬"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.display
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0

          Text {
            textFormat: Text.PlainText
            text: "OmaFlow"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: !root.binaryFound ? "Daemon not built" : !root.connected ? "Stopped or reconnecting" : root.modelSettings.configured === false ? "Models not configured" : !root.asrRunning ? "Speech model loading" : !root.cleanupEnabled ? "Ready, cleanup off" : !root.cleanupAvailable ? "Ready, cleanup offline" : "Ready"
            color: root.connected ? Util.alpha(Color.popups.text, 0.58) : Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        ActionButton {
          text: "History " + root.history.length
          foreground: Color.popups.text
          background: root.idlePage === "history" ? Util.alpha(Color.accent, 0.22) : "transparent"
          bordered: root.idlePage === "history"
          onClicked: root.idlePage = "history"
        }

        ActionButton {
          text: "Settings"
          foreground: Color.popups.text
          background: root.idlePage === "settings" ? Util.alpha(Color.accent, 0.22) : "transparent"
          bordered: root.idlePage === "settings"
          onClicked: root.idlePage = "settings"
        }

        ActionButton {
          visible: !root.connected && root.binaryFound
          text: "Start"
          foreground: Color.popups.text
          background: Util.alpha(Color.accent, 0.22)
          bordered: true
          onClicked: root.startOmaFlow()
        }
      }

      // `omarchy plugin add` lands the QML with no daemon behind it. Say what
      // to run instead of showing a panel whose every button silently no-ops.
      Rectangle {
        visible: !root.binaryFound
        Layout.fillWidth: true
        Layout.preferredHeight: installBanner.implicitHeight + Style.space(20)
        radius: Style.cornerRadius
        color: Util.alpha(Color.urgent, 0.14)

        RowLayout {
          id: installBanner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.space(10)
          spacing: Style.space(10)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "The bar widget is installed but the dictation daemon is not built yet. Run in a terminal:\n\ncd " + root.pluginDir + " && ./install"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          ActionButton {
            text: "Copy command"
            foreground: Color.popups.text
            background: Util.alpha(Color.accent, 0.22)
            bordered: true
            onClicked: Quickshell.execDetached(["wl-copy", "cd " + root.pluginDir + " && ./install"])
          }
        }
      }

      // The panel opens on History, so an available update has to be visible
      // here rather than only inside Settings.
      Rectangle {
        visible: root.updateAttention
        Layout.fillWidth: true
        Layout.preferredHeight: updateBanner.implicitHeight + Style.space(20)
        radius: Style.cornerRadius
        color: Util.alpha(Color.accent, 0.14)

        RowLayout {
          id: updateBanner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.space(10)
          spacing: Style.space(10)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.needsRebuild || !root.supportedState
              ? "Version " + root.checkoutVersion + " is downloaded and ready to install"
              : root.updateRemoteVersion
                ? "OmaFlow " + root.updateRemoteVersion + " is available"
                : "An OmaFlow update is available"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          ActionButton {
            text: root.needsRebuild || !root.supportedState ? "Finish update" : "Update"
            foreground: Color.popups.text
            background: Util.alpha(Color.accent, 0.28)
            bordered: true
            onClicked: root.needsRebuild || !root.supportedState
              ? root.finishUpdate() : root.applyUpdate()
          }
        }
      }

      Rectangle {
        Layout.fillWidth: true
        height: Style.spacing.hairline
        color: Color.popups.text
        opacity: 0.12
      }

      Text {
        Layout.fillWidth: true
        visible: root.feedback.length > 0
        textFormat: Text.PlainText
        text: root.feedback
        color: root.feedbackError ? Color.urgent : Color.accent
        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      Loader {
        id: pageLoader
        Layout.fillWidth: true
        Layout.fillHeight: true
        active: root.supportedState && root.connected
        sourceComponent: root.idlePage === "settings" ? settingsView : historyView
      }
    }
  }


  Component {
    id: historyView

    Item {
      id: historyPage
      // Searching narrows the list, so the keyboard cursor has to walk the
      // filtered entries rather than the full history behind them.
      readonly property var entries: {
        var query = root.historyQuery.trim().toLowerCase()
        if (query.length === 0) return root.history
        return root.history.filter(function(entry) {
          return String(entry.text || "").toLowerCase().indexOf(query) >= 0
        })
      }
      function moveCursor(dy) {
        if (entries.length === 0) return
        root.selectedHistoryIndex = Math.max(0,
          Math.min(entries.length - 1, root.selectedHistoryIndex + dy))
        historyList.positionViewAtIndex(root.selectedHistoryIndex, ListView.Contain)
      }
      function activateCursor() {
        if (entries.length > 0) root.selectedEntryId = String(entries[root.selectedHistoryIndex].id)
      }
      function deleteCursor() {
        if (entries.length > 0) root.deleteHistory(entries[root.selectedHistoryIndex].id)
      }
      function focusSearch() { searchField.forceActiveFocus() }
      onEntriesChanged: root.selectedHistoryIndex = Math.max(0,
        Math.min(root.selectedHistoryIndex, Math.max(0, entries.length - 1)))

      Text {
        anchors.centerIn: parent
        visible: root.history.length === 0 && !root.selectedEntryId
        textFormat: Text.PlainText
        text: "Hold " + root.hotkeyDisplay + " and speak\nRelease to insert your words.\nDouble-tap to record hands-free.\n\n" + (root.historyLimit > 0 ? "Your dictations will appear here." : "History is off. Text still goes to your clipboard.") + ""
        horizontalAlignment: Text.AlignHCenter
        color: Util.alpha(Color.popups.text, 0.52)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Loader {
        anchors.fill: parent
        active: root.selectedEntry !== null
        sourceComponent: Component {
          TranscriptDetail { flow: root; entry: root.selectedEntry }
        }
      }
      ColumnLayout {
        anchors.fill: parent
        visible: !root.selectedEntryId
        spacing: Style.space(7)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          TextField {
            id: searchField
            Layout.fillWidth: true
            foreground: Color.popups.text
            accent: Color.accent
            placeholderText: "Search " + root.history.length + " dictations"
            text: root.historyQuery
            onTextChanged: root.historyQuery = text
            Keys.onEscapePressed: {
              if (text.length > 0) { text = "" } else { focus = false }
            }
          }

          Text {
            visible: !searchField.activeFocus && root.historyQuery.length === 0
            textFormat: Text.PlainText
            text: "/"
            color: Util.alpha(Color.popups.text, 0.38)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          ActionButton {
            visible: root.canUndoDelete
            text: "Undo"
            foreground: Color.popups.text
            onClicked: root.undoDelete()
          }

          ActionButton {
            visible: root.history.length > 0 && root.historyQuery.length === 0
            text: "Clear"
            foreground: Util.alpha(Color.popups.text, 0.62)
            onClicked: root.clearHistory()
          }
        }

        Text {
          Layout.fillWidth: true
          visible: historyPage.entries.length === 0 && root.historyQuery.length > 0
          textFormat: Text.PlainText
          text: "No dictation matches \"" + root.historyQuery + "\""
          horizontalAlignment: Text.AlignHCenter
          color: Util.alpha(Color.popups.text, 0.52)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        ListView {
          id: historyList
          Layout.fillWidth: true
          Layout.fillHeight: true
          model: historyPage.entries
          spacing: Style.space(8)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          currentIndex: root.selectedHistoryIndex

          delegate: CursorSurface {
            id: historyCard
            required property var modelData
            required property int index
            hasCursor: root.cursorActive && root.selectedHistoryIndex === index
            foreground: Color.popups.text
            accent: Color.accent
            width: ListView.view.width
            height: historyContent.implicitHeight + Style.space(18)
            color: hasCursor
              ? fill : Util.alpha(Color.popups.text, 0.055)

            HoverHandler {
              id: historyHover
              cursorShape: Qt.PointingHandCursor
              onHoveredChanged: if (hovered) {
                root.cursorActive = true
                root.selectedHistoryIndex = historyCard.index
              }
            }

            TapHandler {
              onTapped: {
                root.cursorActive = true
                root.selectedHistoryIndex = historyCard.index
                root.selectedEntryId = String(modelData.id)
              }
            }

            ColumnLayout {
              id: historyContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(5)

              RowLayout {
                Layout.fillWidth: true

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.formatHistoryTime(modelData.created_at_ms)
                  color: Util.alpha(Color.popups.text, 0.52)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                ActionButton { text: "Copy"; tooltipText: "Copy full dictation"; onClicked: root.copyHistory(modelData.id) }
                ActionButton { text: "Delete"; tooltipText: "Delete this dictation (undo available)"; onClicked: root.deleteHistory(modelData.id) }

              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: String(modelData.text || "")
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }


  Component {
    id: settingsView

    Flickable {
      id: settingsFlick
      contentWidth: width
      contentHeight: settingsContent.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      function moveCursor(dy) {
        contentY = Math.max(0, Math.min(contentHeight - height,
          contentY + dy * Style.space(64)))
      }
      function activateCursor() {}
      function deleteCursor() {}

      ColumnLayout {
        id: settingsContent
        width: settingsFlick.width
        spacing: Style.space(12)

        Text {
          Layout.fillWidth: true
          text: "Cleanup"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Toggle {
          Layout.fillWidth: true
          label: "Natural cleanup"
          description: "Removes fillers and repeated words, applies your spoken corrections and adds punctuation and paragraphs, without changing what you said. The title of the focused window tells the model whether it is writing a chat message, an email or code. Off keeps the exact recognized wording. Custom vocabulary applies either way."
          foreground: Color.popups.text
          checked: root.cleanupEnabled && root.writingStyle !== "verbatim"
          onClicked: root.preference("enabled", !checked)
        }
        Text {
          Layout.fillWidth: true
          text: "Privacy"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          Layout.fillWidth: true
          text: "With the default local servers, speech recognition and cleanup run on this computer and no audio or text leaves it. Audio stays in memory and is never written to disk."
          wrapMode: Text.Wrap
          color: Util.alpha(Color.popups.text,0.65)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(7)

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(1)

            Text {
              text: "History retention"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
            }
            Text {
              Layout.fillWidth: true
              text: root.historyLimit === 0
                ? "Nothing is saved. Each dictation is gone once it is pasted."
                : "Keeps the last " + root.historyLimit + " dictations in a file only your user can read, so you can reopen, edit and re-paste them."
              wrapMode: Text.Wrap
              color: Util.alpha(Color.popups.text, 0.52)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: [0, 30, 100, 1000]

            ActionButton {
              required property int modelData
              text: modelData === 0 ? "Off" : String(modelData)
              foreground: Color.popups.text
              fontSize: Style.font.bodySmall
              selected: root.historyLimit === modelData
              tooltipText: modelData === 0
                ? "Do not save dictations"
                : "Keep the last " + modelData + " dictations"
              Accessible.name: tooltipText
              Accessible.checkable: true
              Accessible.checked: selected
              onClicked: root.preference("history_limit", modelData)
            }
          }
        }
        ActionButton {
          text: root.eraseConfirm ? "Confirm: erase all saved dictations" : "Erase saved dictations…"
          tooltipText: "Deletes the history file" + (root.trainingLogEnabled ? " and the training log" : "") + ". The clipboard is not touched."
          foreground: Color.urgent
          onClicked: {
            if (!root.eraseConfirm) root.eraseConfirm = true
            else { Quickshell.execDetached(["omaflow","erase-data"]); root.eraseConfirm = false }
          }
        }        ActionButton { visible:root.eraseConfirm; text:"Keep my data"; onClicked:root.eraseConfirm=false }

        Text {
          text: "Memory"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Toggle {
          Layout.fillWidth: true
          label: "Keep models loaded"
          description: "On: the models stay loaded between dictations, so the hotkey answers at once; with the default models that is about 6 GB of GPU memory. Off: after five minutes without dictation they are unloaded, and the next dictation loads them first, about 2.5 s with the defaults on the reference machine. Servers you run yourself are left alone."
          foreground: Color.popups.text
          checked: root.keepModelsLoaded
          onClicked: root.preference("keep_models_loaded", !checked)
        }

        Text {
          text: "Keyboard"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: shortcutContent.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Util.alpha(Color.popups.text, 0.055)

          RowLayout {
            id: shortcutContent
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(12)

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Text {
                text: root.hotkeyDisplay
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                text: "Hold to talk, double-tap to lock"
                color: Util.alpha(Color.popups.text, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            ActionButton {
              text: root.editShortcut ? "Done" : "Change"
              foreground: Color.popups.text
              bordered: true
              onClicked: root.editHotkey()
            }
          }
        }

        HotkeySettings { Layout.fillWidth: true; visible:root.editShortcut; flow:root }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(7)

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(1)

            Text {
              text: "Paste delivery"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              text: "Auto sends Ctrl+V, or Shift+Insert in terminals."
              color: Util.alpha(Color.popups.text, 0.52)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          Repeater {
            model: [
              { "label": "Auto", "value": "auto" },
              { "label": "Ctrl+V", "value": "ctrl-v" },
              { "label": "Shift+Insert", "value": "shift-insert" },
              { "label": "Copy", "value": "clipboard" }
            ]

            ActionButton {
              required property var modelData
              text: modelData.label
              foreground: Color.popups.text
              background: root.pasteMode === modelData.value
                ? Util.alpha(Color.accent, 0.22) : "transparent"
              bordered: root.pasteMode === modelData.value
              onClicked: root.setPasteMode(modelData.value)
            }
          }
        }

        Text {
          text: "Microphone sensitivity (" + root.meterGateDb + " dB)"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: sensitivityContent.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Util.alpha(Color.popups.text, 0.055)

          ColumnLayout {
            id: sensitivityContent
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(7)

            RowLayout {
              Layout.fillWidth: true

              Text {
                Layout.fillWidth: true
                text: root.voiceDetected ? "Voice detected" : "Speak to test. Set the marker above room noise."
                color: root.voiceDetected ? Color.accent : Util.alpha(Color.popups.text, 0.66)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              ActionButton {
                text: "Reset"
                foreground: Color.popups.text
                onClicked: root.commitMeterGate(-60)
              }
            }

            // One control, not two. The live meter is the track and the
            // threshold marker is its handle, so "where my voice reaches" and
            // "where the cutoff sits" are read on the same scale and set by
            // dragging the thing you are looking at.
            Item {
              id: meterControl
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(22)

              readonly property real minimumDb: -70
              readonly property real maximumDb: -35
              // The meter spans -72..0 dBFS, so the adjustable range covers
              // only the quiet end of the track; clamp rather than rescale, or
              // the marker would stop matching the level it is measuring.
              readonly property real minimumPosition: (minimumDb + 72) / 72
              readonly property real maximumPosition: (maximumDb + 72) / 72
              readonly property real thresholdPosition:
                Math.max(0, Math.min(1, (root.meterGateDb + 72) / 72))

              function dbAt(x) {
                var position = Math.max(minimumPosition,
                  Math.min(maximumPosition, x / Math.max(1, width)))
                return position * 72 - 72
              }

              Rectangle {
                id: meterTrack
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(10)
                radius: height / 2
                color: Util.alpha(Color.popups.text, 0.10)
                clip: true

                Rectangle {
                  width: parent.width * root.micLevel
                  height: parent.height
                  radius: height / 2
                  color: root.voiceDetected ? Color.accent : Util.alpha(Color.popups.text, 0.34)
                  Behavior on width { NumberAnimation { duration: root.reducedMotion ? 0 : 45; easing.type: Easing.OutQuad } }
                }
              }

              Rectangle {
                id: meterHandle
                x: Math.max(0, Math.min(parent.width - width,
                  parent.width * meterControl.thresholdPosition - width / 2))
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(4, Style.space(4))
                height: parent.height
                radius: width / 2
                color: Color.urgent
                scale: meterDrag.pressed ? 1.12 : meterHover.hovered ? 1.06 : 1
                Behavior on scale { NumberAnimation { duration: root.reducedMotion ? 0 : 90 } }
              }

              HoverHandler {
                id: meterHover
                cursorShape: Qt.SizeHorCursor
              }

              Controls.Slider {
                id: meterDrag
                anchors.fill: parent
                from: -72; to: 0; stepSize: 1
                value: root.meterGateDb
                background: Rectangle { color: "transparent"; border.width: meterDrag.activeFocus ? 1 : 0; border.color: Color.accent }
                handle: Item {}
                Accessible.name: "Microphone sensitivity"
                onMoved: pressed ? root.previewMeterGate(value) : root.commitMeterGate(value)
                onPressedChanged: if (!pressed) root.commitMeterGate(value)
              }

            }

            RowLayout {
              Layout.fillWidth: true
              Text {
                text: "More sensitive"
                color: Util.alpha(Color.popups.text, 0.48)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Item { Layout.fillWidth: true }
              Text {
                text: "Less sensitive"
                color: Util.alpha(Color.popups.text, 0.48)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Text {
          text: "Models"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: pipelineGrid.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Util.alpha(Color.popups.text, 0.055)

          GridLayout {
            id: pipelineGrid
            anchors.fill: parent
            anchors.margins: Style.space(10)
            columns: 2
            columnSpacing: Style.space(18)
            rowSpacing: Style.space(8)

            Repeater {
              model: [
                { "label": "Speech", "value": (root.modelSettings.speech_model || "Not selected") + ", " + (root.asrRunning ? (root.modelSettings.speech_engine === "nemo" || root.modelSettings.speech_engine === "parakeet" ? "Running" : "Reachable") : "Stopped"), "ok": root.asrRunning },
                { "label": "Cleanup", "value": (root.modelSettings.cleanup_model || "Not selected") + ", " + (!root.cleanupEnabled ? "Off" : !root.cleanupAvailable ? "Offline" : root.cleanupLoaded ? "Loaded" : "On demand"), "ok": root.cleanupLoaded },
                { "label": "GPU memory", "value": root.gpuMemoryMib > 0 ? (root.gpuMemoryMib / 1024).toFixed(1) + " GB" : "Idle", "ok": root.gpuMemoryMib > 0 },
                { "label": "Training log", "value": root.trainingLogEnabled ? "On" : "Off", "ok": root.trainingLogEnabled }
              ]

              RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Style.space(7)

                Rectangle {
                  Layout.preferredWidth: Style.space(7)
                  Layout.preferredHeight: Style.space(7)
                  radius: width / 2
                  color: modelData.ok ? Color.accent : Util.alpha(Color.popups.text, 0.28)
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Text {
                    text: modelData.label
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WrapAnywhere
                    text: modelData.value
                    color: Util.alpha(Color.popups.text, 0.52)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        ActionButton { text: root.editModels ? "Close model settings" : root.modelSettings.configured === false ? "Set up models" : "Configure models"; onClicked: root.editModels = !root.editModels }
        ModelSettings { Layout.fillWidth:true; visible:root.editModels; flow:root }

        Text {
          text: "Custom vocabulary"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          Layout.fillWidth: true
          text: "Add names, products, and technical terms you want spelled exactly."
          color: Util.alpha(Color.popups.text, 0.52)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Repeater {
          model: root.customVocabulary

          Rectangle {
            required property var modelData
            Layout.fillWidth: true
            Layout.preferredHeight: vocabularyRow.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            color: Util.alpha(Color.popups.text, 0.045)

            HoverHandler { id: vocabularyHover }

            RowLayout {
              id: vocabularyRow
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(6)

              Text {
                Layout.fillWidth: true
                text: String(modelData)
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              ActionButton {
                text: "Remove"
                foreground: Util.alpha(Color.popups.text, 0.62)
                onClicked: root.removeVocabulary(modelData)
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          TextField {
            id: vocabularyField
            Layout.fillWidth: true
            foreground: Color.popups.text
            accent: Color.accent
            placeholderText: "Add a word or phrase"
            maximumLength: 80
            onAccepted: {
              root.addVocabulary(text)
              focus = false
            }
          }

          ActionButton {
            text: "Add"
            foreground: Color.popups.text
            background: Util.alpha(Color.accent, 0.22)
            bordered: true
            enabled: vocabularyField.text.trim().length > 0
            onClicked: {
              root.addVocabulary(vocabularyField.text)
            }
          }
        }

        Text {
          text: "Updates"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: updateContent.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Util.alpha(Color.popups.text, 0.055)

          ColumnLayout {
            id: updateContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(10)
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.updateError
                    ? "Could not check for updates"
                    : !root.supportedState
                      ? "The running daemon is newer than this panel"
                      : root.needsRebuild
                      ? "Version " + root.checkoutVersion + " is ready to install"
                      : root.updateAvailable
                        ? (root.updateRemoteVersion
                          ? "Version " + root.updateRemoteVersion + " is available"
                          : root.updateBehind + (root.updateBehind === 1
                            ? " new commit is available" : " new commits are available"))
                        : root.updateCheckedAtMs === 0 ? "Updates have not been checked" : "OmaFlow " + root.runningVersion + " is up to date"
                  color: root.updateAttention ? Color.accent : Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.Wrap
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.updateError
                    ? "Last check failed: " + root.updateError
                    : root.needsRebuild || !root.supportedState
                      ? "The checkout moved but the daemon was not rebuilt. Finish update rebuilds it."
                      : root.updateCheckedAtMs > 0
                        ? "Checked " + root.formatHistoryTime(root.updateCheckedAtMs).toLowerCase()
                        : "Not checked yet"
                  color: Util.alpha(Color.popups.text, 0.55)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }

              ActionButton {
                visible: root.needsRebuild || !root.supportedState
                text: "Finish update"
                foreground: Color.popups.text
                background: Util.alpha(Color.accent, 0.22)
                bordered: true
                onClicked: root.finishUpdate()
              }

              ActionButton {
                visible: root.updateAvailable && !root.needsRebuild && root.supportedState
                text: "Update"
                foreground: Color.popups.text
                background: Util.alpha(Color.accent, 0.22)
                bordered: true
                onClicked: root.applyUpdate()
              }

              ActionButton {
                visible: !root.updateAttention
                text: checkUpdateProcess.running ? "Checking…" : "Check now"
                enabled: !checkUpdateProcess.running
                foreground: Color.popups.text
                bordered: true
                onClicked: root.checkForUpdate()
              }
            }
          }
        }

        ActionButton {
          text: "Reload config.toml"
          onClicked: Quickshell.execDetached(["omaflow", "reload-config"])
        }
        ActionButton {
          text: "Open config.toml"
          foreground: Color.popups.text
          bordered: true
          onClicked: root.openEditor(root.personalConfigPath)
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
          Layout.preferredHeight: Style.spacing.hairline
          color: Util.alpha(Color.popups.text, 0.12)
        }

        ActionButton {
          Layout.bottomMargin: Style.space(4)
          text: "Quit OmaFlow"
          foreground: Color.urgent
          onClicked: root.quitOmaFlow()
        }
      }
    }
  }
}
