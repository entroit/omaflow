import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "../../ui"
import "../../ui/Dates.js" as Dates

// OmaFlow inside the Omarchy shell: the bar icon, the window, and the card at
// the bottom of the screen. Everything you see is the shared UI in ../../ui;
// this file only connects it to Quickshell: files to watch, processes to run,
// windows to put it in.
Panel {
  id: root
  moduleName: "entroit.omaflow"
  ipcTarget: "entroit.omaflow"
  manageIpc: false

  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config"
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  function showWindow(page) {
    view.show(page || view.page)
    window.visible = true
  }
  function toggleWindow() {
    if (window.visible) window.visible = false
    else showWindow("")
  }
  function toggleJournal() {
    if (window.visible && view.page === "journal") window.visible = false
    else showWindow("journal")
  }
  function toggleTodos() {
    if (window.visible && view.page === "todos") window.visible = false
    else showWindow("todos")
  }

  App {
    id: flow
    pluginDir: root.configHome + "/omarchy/plugins/entroit.omaflow"
    host: QtObject {
      readonly property string trustedRunner: Quickshell.env("HOME") + "/.local/lib/omaflow/trusted-runner"
      function spawn(argv, callback, input) {
        var job = jobComponent.createObject(root, { command: argv, callback: callback, input: input || "" })
        job.running = true
      }
      function copy(text) { Quickshell.execDetached(["wl-copy", "--", text]) }
      function openInEditor(path) { window.visible = false; Quickshell.execDetached(["omarchy-launch-editor", path]) }
      function openExternally(target) { Quickshell.execDetached(["xdg-open", target]) }
      function hideWindow() { window.visible = false }
      function showWindow(page) { root.showWindow(page) }
    }
  }
  Component { id: jobComponent; Job {} }


  // Motion follows the desktop: with Hyprland's animations off, cards cut.
  Component.onCompleted: flow.spawn(["hyprctl", "getoption", "animations:enabled", "-j"], function(stdout) {
    try { Theme.motion = JSON.parse(stdout).bool !== false } catch (error) {}
  })

  // ------------------------------------------------------------ the daemon
  FileView {
    id: stateFile
    path: root.runtimeDir + "/omaflow-state.json"
    watchChanges: true
    printErrors: false
    onLoaded: if (!flow.applyState(text())) retry.restart()
    onLoadFailed: flow.connected = false
    onFileChanged: reload()
  }
  Timer { id: retry; interval: 12; onTriggered: stateFile.reload() }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: stateFile.reload() }

  FileView {
    path: root.runtimeDir + "/omaflow-level"
    watchChanges: true
    printErrors: false
    onLoaded: flow.applyLevel(text())
    onFileChanged: reload()
  }

  // Your settings, live: saving ~/.config/omaflow/config.toml applies it the
  // way the Settings panel does. Editors save in bursts, so wait for the file
  // to settle and reload once. The Settings panel writes this file too; a
  // reload that changes nothing does nothing.
  FileView {
    path: root.configHome + "/omaflow/config.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); configSettle.restart() }
  }
  Timer { id: configSettle; interval: 400; onTriggered: root.reloadConfig() }
  function reloadConfig() {
    flow.spawn(["omaflow", "reload-config"], function(stdout, stderr, code) {
      if (code !== 0) {
        var reason = String(stderr || "").trim()
        try { reason = JSON.parse(stdout).message || reason } catch (error) {}
        Quickshell.execDetached(["notify-send", "-a", "OmaFlow", "config.toml was not applied",
          (reason || "Check the file with: omaflow effective-config") + "\nThe previous settings stay in use."])
      }
      flow.openJournalFolder()
    })
  }

  // Theme colours, live when `omarchy-theme-set` switches themes.
  FileView {
    path: root.stateHome + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: Theme.load(text())
    onFileChanged: reload()
  }

  FileView {
    path: root.stateHome + "/omaflow/update/offer.json"
    watchChanges: true
    printErrors: false
    onLoaded: { try { flow.updateOffer = JSON.parse(text() || "{}") } catch (error) { flow.updateOffer = ({ error: "Saved update information is invalid." }) } }
    onFileChanged: reload()
  }
  FileView {
    path: root.stateHome + "/omaflow/update/transaction.json"
    watchChanges: true
    printErrors: false
    onLoaded: { try { flow.updateTransaction = JSON.parse(text() || "{}") } catch (error) { flow.updateTransaction = ({ state: "needs-recovery", message: "Saved update progress is invalid." }) } }
    onFileChanged: reload()
  }
  FileView {
    path: root.stateHome + "/omaflow/update/deferral.json"
    watchChanges: true
    printErrors: false
    onLoaded: { try { flow.updateDeferral = JSON.parse(text() || "{}") } catch (error) { flow.updateDeferral = ({}) } }
    onLoadFailed: flow.updateDeferral = ({})
    onFileChanged: reload()
  }

  // `omarchy plugin add` copies the files but never builds the daemon.
  Process {
    id: binaryProbe
    command: ["sh", "-c", "command -v omaflow"]
    running: true
    onExited: function(code) {
      flow.binaryFound = code === 0
      // Installs updated without link-local still need the journal folder
      // opened to the sandboxed daemon; this is a no-op once it is.
      if (flow.binaryFound) { flow.openJournalFolder(); root.deliverNotes() }
    }
  }

  // Notes you wrote ahead to today arrive as a notification, once each. The
  // shell asks when it starts and every half hour, so a day that begins while
  // it is running is not missed.
  function deliverNotes() {
    flow.query(["journal", "due"], function(value) {
      if (!value || !value.notes) return
      value.notes.forEach(function(note) {
        flow.spawn(["notify-send", "-a", "OmaFlow", "-A", "open=Open the journal",
          "A note from " + Dates.full(note.written), "You wrote yourself a note for today."],
          function(stdout) { if (String(stdout).trim() === "open") root.showWindow("journal") })
      })
    })
  }
  Timer { interval: 30 * 60 * 1000; running: flow.binaryFound; repeat: true; onTriggered: root.deliverNotes() }

  // A to-do's time has come: a notification, once each, with Done to tick
  // it off and Open to see the list.
  function deliverReminders() {
    flow.query(["todos", "reminders"], function(value) {
      if (!value || !value.reminders) return
      var today = flow.todayIso()
      value.reminders.forEach(function(todo) {
        var when = (todo.due === today ? "Due at " : "Was due " + Dates.due(todo.due, today).toLowerCase() + " at ") + todo.time
        flow.spawn(["notify-send", "-a", "OmaFlow", "-u", "critical", "-A", "done=Done", "-A", "open=Open",
          todo.text, when + (todo.list ? ", in " + todo.list : "")],
          function(stdout) {
            var answer = String(stdout).trim()
            if (answer === "done") flow.query(["todos", "done", todo.index, todo.text], function() { flow.todosRevision += 1 })
            else if (answer === "open") root.showWindow("todos")
          })
      })
    })
  }
  Timer { interval: 30 * 1000; running: flow.binaryFound; repeat: true; triggeredOnStart: true; onTriggered: root.deliverReminders() }

  IpcHandler {
    target: "entroit.omaflow"
    function open(): void { root.showWindow("") }
    function show(): void { root.showWindow("") }
    function close(): void { window.visible = false }
    function hide(): void { window.visible = false }
    function toggle(): void { root.toggleWindow() }
    function history(): void { root.showWindow("history") }
    function journal(): void { root.showWindow("journal") }
    function toggleJournal(): void { root.toggleJournal() }
    function todos(): void { root.showWindow("todos") }
    function toggleTodos(): void { root.toggleTodos() }
    function settings(): void { root.showWindow("settings") }
  }

  // --------------------------------------------------------------- bar icon
  // It changes colour and never moves: red while recording, the accent while
  // transcribing. A meter in the corner of the screen only distracts; the card
  // at the bottom shows the level.
  Component {
    id: barMark
    Mark {
      width: 16; height: 16
      color: flow.phase === "recording" || flow.phase === "error" ? Theme.red
        : flow.phase === "processing" ? Theme.accent
        : barButton.foreground
      badge: flow.phase === "idle" && (flow.updateAttention || !flow.binaryFound || flow.setupUnfinished)
      badgeColor: flow.updateAttention ? Theme.accent : Theme.yellow
    }
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: ""
    iconComponent: barMark
    foreground: root.bar ? root.bar.foreground : Color.foreground
    active: flow.phase === "recording"
    activeColor: Color.urgent
    slotSize: Style.bar.statusSlot
    tooltipText: !flow.connected ? "OmaFlow is stopped. Click to start it."
      : flow.phase === "recording" ? (flow.journalTake ? "Recording a journal entry. " + (flow.journalShortcut ? flow.journalShortcut : "Click") + " saves it."
        : flow.todoTake ? "Listening for to-dos. " + (flow.todoShortcut ? flow.todoShortcut : "Click") + " adds them."
        : flow.latched ? "Recording hands-free. Press " + flow.hotkeyLabel + " or click to stop."
        : "Recording. Let go of " + flow.hotkeyLabel + " to finish.")
      : flow.phase === "processing" ? "Transcribing"
      : "Hold " + flow.hotkeyLabel + " to dictate. Right-click for the journal."
    onPressed: function(button) {
      if (!flow.connected && flow.binaryFound) { flow.start(); return }
      if (flow.phase === "recording" && flow.latched) {
        if (flow.journalTake) flow.journalToggle()
        else if (flow.todoTake) flow.todoToggle()
        else flow.stopRecording()
        return
      }
      if (button === Qt.RightButton) root.showWindow("journal")
      else root.toggleWindow()
    }
  }

  // ----------------------------------------------------------------- window
  FloatingWindow {
    id: window
    title: "OmaFlow"
    visible: false
    color: Theme.background
    implicitWidth: 880
    implicitHeight: 720
    minimumSize: Qt.size(760, 560)

    MainView {
      id: view
      anchors.fill: parent
      app: flow
      shown: window.visible
      Keys.onEscapePressed: window.visible = false
    }
    onVisibleChanged: if (visible) { stateFile.reload(); binaryProbe.running = true; view.focusPage() }
    // Super+W (Hyprland's close) destroys the surface without touching
    // `visible`; treat it as hiding, so the next open shows the window again.
    onClosed: visible = false
  }

  // ---------------------------------------------------------------- overlay
  PanelWindow {
    id: overlayWindow
    // The card follows the monitor you are working on.
    screen: {
      var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++)
        if (screens[i].name === focused) return screens[i]
      return null
    }
    // Stays up while the last card fades out.
    visible: flow.connected && flow.supportedState && (flow.phase !== "idle" || card.visible)
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omaflow"
    WlrLayershell.layer: WlrLayer.Overlay
    // Only the to-dos card can be typed into, and only once you click it;
    // otherwise the app you are in keeps the keyboard.
    WlrLayershell.keyboardFocus: card.mode === "todos-saved" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // The card, and the list menu that opens above it.
    mask: Region { item: card; Region { item: card.menuArea } }

    OverlayCard {
      id: card
      app: flow
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 67
    }
  }

  // The level meter only runs while someone can see it.
  Connections {
    target: window
    function onVisibleChanged() { if (!window.visible) flow.setMeterPreview(false) }
  }
}
