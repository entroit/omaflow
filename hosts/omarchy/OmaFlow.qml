import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "../../ui"
import "../../ui/Dates.js" as Dates
import "Copies.js" as Copies

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

  // With a bar on each monitor there is a copy of this file for each. Only
  // the leader delivers reminders and notes, shows the card, answers
  // keybindings and owns the window; see Copies.js.
  property bool leader: false
  function main() { return leader ? root : Copies.leader() || root }
  Component.onDestruction: Copies.leave(root)

  function showWindow(page) {
    if (main() !== root) return main().showWindow(page)
    // An empty route keeps the page the window was on.
    view.show(page)
    window.visible = true
  }
  // `page` is where it opens, "" for the page it was on.
  function toggleWindow(page) {
    if (main() !== root) return main().toggleWindow(page)
    if (window.visible) window.visible = false
    else showWindow(page || "")
  }
  function toggleJournal() {
    if (main() !== root) return main().toggleJournal()
    if (window.visible && view.page === "journal") window.visible = false
    else showWindow("journal")
  }
  function toggleTodos() {
    if (main() !== root) return main().toggleTodos()
    if (window.visible && view.page === "todos") window.visible = false
    else showWindow("todos")
  }
  function hideWindow() {
    if (main() !== root) return main().hideWindow()
    window.visible = false
  }
  // Started from the copy whose window shows it, so the window says
  // "Starting OmaFlow" and, if it fails, why.
  function start() {
    if (main() !== root) return main().start()
    flow.start()
  }

  // The shell calls these to summon the widget, as clicking the update
  // notification does: open where the update waits, if one does.
  function open() { showWindow(flow.updateAttention || root.updatePaused ? "settings/updates" : "") }
  function close() { hideWindow() }

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
  Component.onCompleted: {
    Copies.join(root)
    flow.spawn(["hyprctl", "getoption", "animations:enabled", "-j"], function(stdout) {
      try { Theme.motion = JSON.parse(stdout).bool !== false } catch (error) {}
    })
  }

  // ------------------------------------------------------------ the daemon
  FileView {
    id: stateFile
    path: root.runtimeDir + "/omaflow-state.json"
    watchChanges: true
    printErrors: false
    onLoaded: { root.stateRead = true; if (!flow.applyState(text())) retry.restart() }
    onLoadFailed: { root.stateRead = true; flow.connected = false }
    onFileChanged: reload()
  }
  // Whether the state file has been looked at, so the bar does not call
  // OmaFlow stopped in the moment before it is read.
  property bool stateRead: false
  Timer { id: retry; interval: 12; onTriggered: stateFile.reload() }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: { stateFile.reload(); root.leader = Copies.leader() === root } }

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
    onFileChanged: { reload(); if (root.leader) configSettle.restart() }
  }
  Timer { id: configSettle; interval: 400; onTriggered: root.reloadConfig() }
  function reloadConfig() {
    flow.spawn(["omaflow", "reload-config"], function(stdout, stderr, code) {
      if (code !== 0) {
        var reason = String(stderr || "").trim()
        try { reason = JSON.parse(stdout).message || reason } catch (error) {}
        // "--" ends the options, so a reason that starts with "-" is still text.
        Quickshell.execDetached(["notify-send", "-a", "OmaFlow", "--", "config.toml was not applied",
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
    onLoaded: { try { flow.updateOffer = JSON.parse(text() || "{}") } catch (error) { flow.updateOffer = ({ error: "Saved update information could not be read. Check for updates again." }) } }
    onFileChanged: reload()
  }
  FileView {
    path: root.stateHome + "/omaflow/update/transaction.json"
    watchChanges: true
    printErrors: false
    // An unreadable file pauses dictation in the daemon too; checking for
    // updates puts it right when the installed version is whole.
    onLoaded: { try { flow.updateTransaction = JSON.parse(text() || "{}") } catch (error) { flow.updateTransaction = ({ state: "needs-recovery", message: "OmaFlow could not read where the last update stopped, so dictation is paused. Choose Check now. If it stays paused, this page says what is left." }) } }
    onLoadFailed: flow.updateTransaction = ({})
    onFileChanged: reload()
  }
  // The file says running until the updater writes otherwise, which one that
  // died never does. While it says running, ask OmaFlow whether the updater
  // is still there: one that is gone reads "interrupted", like a failed
  // update, and the bar can say OmaFlow is stopped again.
  Timer {
    interval: 10000
    running: flow.updateRunning && flow.binaryFound
    repeat: true
    triggeredOnStart: true
    onTriggered: flow.spawn(["omaflow", "update", "status"], function(stdout, stderr, code) {
      if (code !== 0) return
      try {
        var value = JSON.parse(stdout)
        if (value.state === "interrupted") flow.updateTransaction = value
      } catch (error) {}
    })
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
      if (flow.binaryFound && root.leader) { flow.openJournalFolder(); root.deliverNotes() }
    }
  }

  // Notes you wrote ahead to today arrive as a notification, once each, with
  // their first words. The shell asks when it starts and every half hour, so
  // a day that begins while it is running is not missed.
  function deliverNotes() {
    flow.query(["journal", "due"], function(value) {
      if (!value || !value.notes) return
      var day = String(value.date || flow.todayIso())
      value.notes.forEach(function(note) {
        var text = String(note.text || "").replace(/\s+/g, " ").trim()
        // "default" is the action Omarchy runs when the notification is clicked.
        // "--" ends the options: a note such as "- call mom" is text, and
        // notify-send would otherwise refuse it after it was marked delivered.
        flow.spawn(["notify-send", "-a", "OmaFlow", "-A", "default=Open the journal", "--",
          "A note you wrote on " + Dates.long(note.written, day),
          text.length > 120 ? text.slice(0, 119).trim() + "\u2026" : text],
          function(stdout) { if (String(stdout).trim() === "default") root.showWindow("journal/" + day) })
      })
    })
  }
  Timer { interval: 30 * 60 * 1000; running: flow.binaryFound && root.leader; repeat: true; onTriggered: root.deliverNotes() }

  // A to-do's time has come: a notification, once each. Clicking it opens the
  // to-dos (Omarchy runs the "default" action on a click); notification
  // daemons that draw buttons also offer Done, which ticks it off.
  function deliverReminders() {
    flow.query(["todos", "reminders"], function(value) {
      if (!value || !value.reminders) return
      var today = flow.todayIso()
      var now = Dates.momentText(new Date())
      value.reminders.forEach(function(todo) {
        // Said from the to-do's time, whether the reminder is the default
        // or one set on this to-do: "In 30 minutes, at 15:00".
        var minutes = Dates.minutesBetween(now, todo.due + " " + todo.time)
        var day = Dates.due(todo.due, today)
        if (["Today", "Tomorrow", "Yesterday"].indexOf(day) >= 0) day = day.toLowerCase()
        var hours = Math.floor(minutes / 60)
        var lead = "In " + (hours > 0 ? hours + (hours === 1 ? " hour" : " hours") : "")
          + (hours > 0 && minutes % 60 > 0 ? " " : "")
          + (minutes % 60 > 0 ? minutes % 60 + (minutes % 60 === 1 ? " minute" : " minutes") : "")
        var when = minutes < 0 ? (todo.due === today ? "Was due at " : "Was due " + day + " at ") + todo.time
          : minutes === 0 ? "Due at " + todo.time
          : todo.due === today ? lead + ", at " + todo.time
          : "Due " + day + " at " + todo.time
        // "--" so a to-do that starts with "-" is shown, not taken as an option.
        flow.spawn(["notify-send", "-a", "OmaFlow", "-u", "critical", "-A", "default=Open", "-A", "done=Done", "--",
          todo.text, when + (todo.list ? ", in " + todo.list : "")],
          function(stdout) {
            var answer = String(stdout).trim()
            if (answer === "done") flow.query(["todos", "done", todo.index, todo.text], function(value, error) {
              flow.todosRevision += 1
              // The reminder is gone by now, so a tick that failed says so.
              if (error) Quickshell.execDetached(["notify-send", "-a", "OmaFlow", "--", "\u201c" + todo.text + "\u201d is still open",
                error.replace(/\.$/, "") + ". Open the to-dos to tick it."])
            })
            // A to-do that reminded you waits in Bubbled up, at the top of Today.
            else if (answer === "default") root.showWindow("todos/today")
          })
      })
      // An open to-dos page bubbles them up, with Later and Done.
      if (value.reminders.length > 0) flow.todosRevision += 1
    })
  }
  // On the minute: reminders are set to the minute, so checking just after
  // each one turns over delivers a 15:00 reminder at 15:00, not up to a
  // minute late.
  Timer {
    id: reminderClock
    running: flow.binaryFound && root.leader
    triggeredOnStart: true
    interval: 60000 - Date.now() % 60000 + 250
    onTriggered: {
      root.deliverReminders()
      interval = 60000 - Date.now() % 60000 + 250
      restart()
    }
  }

  IpcHandler {
    enabled: root.leader
    target: "entroit.omaflow"
    function open(): void { root.showWindow("") }
    function show(): void { root.showWindow("") }
    function close(): void { root.hideWindow() }
    function hide(): void { root.hideWindow() }
    function toggle(): void { root.toggleWindow() }
    function history(): void { root.showWindow("history") }
    function journal(): void { root.showWindow("journal") }
    function toggleJournal(): void { root.toggleJournal() }
    function todos(): void { root.showWindow("todos") }
    function toggleTodos(): void { root.toggleTodos() }
    function settings(): void { root.showWindow("settings") }
    function models(): void { root.showWindow("settings/models") }
    function cleanup(): void { root.showWindow("settings/cleanup") }
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
      badge: root.stopped || root.speechStopped || root.updatePaused
        || flow.phase === "idle" && (flow.updateAttention || flow.partlyUpdated || !flow.binaryFound || flow.setupUnfinished)
      // Red where the window's header is red: nothing dictates until it is put right.
      badgeColor: root.stopped || root.speechStopped || root.updatePaused || !flow.binaryFound || flow.partlyUpdated ? Theme.red
        : flow.updateAttention ? Theme.accent : Theme.yellow
      // A ring, not a dot, where dictation cannot run: themes in greys tell it apart by shape.
      badgeRing: root.stopped || root.updatePaused
    }
  }

  // Installed and built, but the daemon is not running: nothing you hold
  // will dictate until it starts. An update stops it on purpose for a moment.
  readonly property bool stopped: stateRead && flow.binaryFound && !flow.connected && !flow.updateRunning
  // The daemon runs but its speech model stopped; the window's header
  // restarts it. Read in the same order as that header's line.
  readonly property bool speechStopped: flow.connected && flow.asrFailed && !flow.setupUnfinished && !flow.speechDownloading
  // What stands before the first dictation; the window's History page says
  // how to finish it.
  readonly property bool unfinished: !flow.binaryFound || flow.connected && flow.setupUnfinished && !flow.speechDownloading
  // The first speech model on its way; the window shows how far along.
  readonly property bool firstDownload: flow.connected && flow.setupUnfinished && flow.speechDownloading
  // An update stopped partway and the daemon refuses new dictation until it
  // is put right from Settings, Updates and app.
  readonly property bool updatePaused: flow.connected && flow.updatePausesDictation
  // Something on Settings, Updates and app waits for you, or shows how far an
  // update is; a click goes there.
  readonly property bool updateNeedsYou: root.updatePaused || flow.partlyUpdated || flow.updateAttention

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
    // WidgetButton names nothing for assistive tech; the tooltip is the state.
    Accessible.name: "OmaFlow"
    Accessible.description: tooltipText
    // Until the state file is read, nothing is known: no claim, no action.
    tooltipText: !root.stateRead ? "OmaFlow"
      : !flow.binaryFound ? "OmaFlow is not installed yet. Click for the one command that finishes it."
      : flow.updateRunning && !(flow.connected && (flow.phase === "recording" || flow.phase === "processing"))
        ? "OmaFlow is updating. Dictation is back in a moment. Click to see how far along it is."
      : !flow.connected ? "OmaFlow is stopped. Click to start it."
      : flow.phase === "recording" ? (flow.journalTake ? "Recording a journal entry. " + (flow.journalShortcut ? flow.journalShortcut : "Click") + " saves it."
        : flow.todoTake ? "Recording to-dos. " + (flow.todoShortcut ? flow.todoShortcut : "Click") + " adds them."
        : flow.latched ? "Recording hands-free. Press " + flow.hotkeyLabel + " or click to stop."
        : "Recording. Let go of " + flow.hotkeyLabel + " to finish.")
      : flow.phase === "processing" ? (flow.journalTake ? "Writing your journal entry down."
        : flow.todoTake ? "Adding your to-dos."
        : flow.cleanupLevel === "medium" ? "Transcribing and cleaning up your dictation." : "Transcribing your dictation.")
      // The icon is red for a failed take as for a recording; the card says why.
      : flow.phase === "error" ? (flow.journalTake ? "The journal entry was not saved."
        : flow.todoTake ? "The to-dos were not added." : "The last dictation failed.")
        + " The card at the bottom of the screen says what to do."
      : root.updatePaused ? "An update did not finish, so dictation is paused. Click to put your previous version back."
      : root.speechStopped ? "The speech model stopped. Click to open OmaFlow and restart it."
      // The tooltip is not redrawn while the pointer stays, so no percent here.
      : root.firstDownload ? "Downloading the speech model. Dictation starts when it finishes. Click to see how far along it is."
      : root.unfinished ? (flow.missingSpeechModel ? "Download the speech model" : "Choose a speech model")
        + " to start dictating. Click to open OmaFlow."
      : flow.partlyUpdated ? "OmaFlow is partly updated. Click to finish the update."
      : flow.updateFailed ? "An update did not finish. Click to see why and try again."
      : flow.updateAttention && flow.updateAvailable ? "OmaFlow " + flow.verifiedUpdate.version + " is ready to install. Click to see what changed."
      : flow.updateAttention && flow.updateOffer.externalCheckoutWarning ? "The OmaFlow folder changed outside OmaFlow. Click to see what to do."
      : "Hold " + flow.hotkeyLabel + " to dictate. Right-click for the journal."
    onPressed: function(button) {
      if (!root.stateRead) return
      // The window opens first, so a start that fails says why in it.
      if (!flow.connected && flow.binaryFound && !flow.updateRunning) { root.showWindow(""); root.start(); return }
      if (flow.phase === "recording" && flow.latched) {
        if (flow.journalTake) flow.journalToggle()
        else if (flow.todoTake) flow.todoToggle()
        else flow.stopRecording()
        return
      }
      if (root.unfinished) root.showWindow("history")
      else if (root.firstDownload) root.showWindow("settings/models")
      else if (root.speechStopped) root.showWindow("")
      else if (button === Qt.RightButton) root.showWindow("journal")
      else root.toggleWindow(root.updateNeedsYou ? "settings/updates" : "")
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
    visible: root.leader && flow.connected && flow.supportedState && (flow.phase !== "idle" || card.visible)
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omaflow"
    WlrLayershell.layer: WlrLayer.Overlay
    // Only the to-dos card, a failed take's card that keeps its recording and
    // a card that holds the only copy of the words take the keyboard, and
    // only once you click them, so Tab reaches Try again, Copy again and
    // Discard; otherwise the app you are in keeps the keyboard.
    WlrLayershell.keyboardFocus: card.mode === "todos-saved" || card.mode === "error" && flow.canRetry || card.holdsWords
      ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
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
