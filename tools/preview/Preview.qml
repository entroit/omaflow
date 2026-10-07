import QtQuick
import QtQuick.Window
import "../../ui"
import "Fixtures.js" as Fixtures

// Renders one screen of the shared UI with sample data and saves it as a PNG.
//   qml6 tools/preview/Preview.qml -- MODE OUTPUT.png
// Runs on plain Qt, without Quickshell, which is also the proof that the
// shared UI does not depend on the Omarchy shell.
Window {
  id: window
  // "-narrow" modes, or PREVIEW_NARROW for any mode: the window at its narrowest.
  width: mode.indexOf("overlay-") === 0 ? 720 : mode.indexOf("-narrow") > 0 || args.indexOf("--narrow") >= 0 ? 760 : 880
  height: mode.indexOf("overlay-") !== 0 ? 720
    : mode.indexOf("todos-saved") > 0 ? (mode.indexOf("-menu") > 0 ? 440 : 300)
    : mode.indexOf("-menu") > 0 ? 330
    : mode.indexOf("warning") > 0 ? 230 : 200
  visible: true
  color: Theme.background

  readonly property var args: Qt.application.arguments
  readonly property string mode: args.length >= 2 ? args[args.length - 2] : "journal"
  readonly property string output: args.length >= 1 ? args[args.length - 1] : "/tmp/preview.png"

  Rectangle { anchors.fill: parent; color: Theme.background }
  // A theme's colors.toml, passed before the mode by PREVIEW_THEME in render.sh.
  Component.onCompleted: if (args.length >= 3 && String(args[args.length - 3]).indexOf("background") >= 0) Theme.load(args[args.length - 3])

  App {
    id: appState
    clockOverride: Fixtures.NOW
    // The host always knows its plugin folder; the install command shows it.
    pluginDir: "/home/you/.config/omarchy/plugins/entroit.omaflow"
    nowMs: Fixtures.NOW
    host: QtObject {
      function spawn(argv, callback) {
        var reply = ""
        if (argv[1] === "journal") {
          var command = argv[2]
          if (window.mode === "journal-unreadable" && (command === "day" || command === "stats"))
            reply = JSON.stringify({ error: "Permission denied (os error 13)" })
          else if (command === "day") reply = window.mode === "journal-first" ? JSON.stringify({ date: argv[3], title: "", file: "", exists: false, entries: [] })
            : window.mode === "journal-empty" || window.mode === "journal-past-empty" ? JSON.stringify({ date: argv[3], title: "", file: "", exists: false, entries: [] })
            : window.mode === "journal-past" ? JSON.stringify(Fixtures.PAST_DAY)
            : JSON.stringify(Fixtures.DAY)
          else if (command === "month") reply = window.mode === "journal-first" ? JSON.stringify({ month: argv[3], days: [] }) : JSON.stringify(Fixtures.MONTH)
          else if (command === "year-ago") reply = window.mode === "journal-first" ? "null" : JSON.stringify(Fixtures.YEAR_AGO)
          else if (command === "stats") reply = JSON.stringify({ days: window.mode === "journal-first" ? 0 : 16 })
          else if (command === "search") reply = window.mode === "journal-search-fail" ? JSON.stringify({ error: "Permission denied (os error 13)" })
            : window.mode === "journal-search-note" ? JSON.stringify(Fixtures.SEARCH_NOTE) : JSON.stringify(Fixtures.SEARCH)
        } else if (argv[1] === "todos" && argv[2] === "list" && window.mode === "todos-loaderror") {
          reply = JSON.stringify({ error: "could not read /home/you/Documents/To-dos/To-dos.md: Permission denied (os error 13)" })
        } else if (argv[1] === "todos" && argv[2] === "list") {
          var flat = Fixtures.FLAT_MODES.indexOf(window.mode) >= 0 || window.mode.indexOf("overlay-") === 0 && window.mode.indexOf("-inbox") > 0
          reply = JSON.stringify({ path: "/home/you/Documents/To-dos/To-dos.md", today: Fixtures.TODAY,
            lists: flat ? [] : Fixtures.LISTS, current: "Infra",
            reminded: window.mode === "todos-bubbled" || window.mode === "todos-later" ? [0, 5] : [], remind_before: 15,
            todos: window.mode === "todos-empty" ? [] : flat ? Fixtures.FLAT
              : window.mode === "todos-inbox-empty" ? Fixtures.TODOS.filter(function(t) { return t.list !== "" }) : Fixtures.TODOS })
        }
        Qt.callLater(function() { callback(reply, "", 0) })
      }
      function copy(text) {}
      function openInEditor(path) {}
      function openExternally(target) {}
      function hideWindow() {}
      function showWindow(page) {}
    }
    Component.onCompleted: {
      applyState(JSON.stringify(Fixtures.state(window.mode, Fixtures.NOW)))
      if (window.mode === "journal-talking" || window.mode === "overlay-journal" || window.mode.indexOf("overlay-journal-for-") === 0 || window.mode.indexOf("overlay-todo") === 0 || window.mode === "todos-talking" || window.mode === "overlay-holding" || window.mode.indexOf("overlay-locked") === 0) {
        var wave = []
        for (var i = 0; i < 120; i++) wave.push(0.2 + 0.65 * Math.abs(Math.sin(i * 1.7) * Math.cos(i * 0.31)))
        waveHistory = wave
        micDetected = true
      }
    }
  }

  Loader {
    anchors.fill: parent
    active: window.mode.indexOf("overlay-") !== 0
    sourceComponent: MainView {
      id: main
      app: appState
      Component.onCompleted: {
        var m = window.mode
        show(m.indexOf("journal") === 0 ? "journal" : m.indexOf("todos") === 0 ? "todos" : m.indexOf("settings") === 0 ? "settings/" + (m.split("-")[1] || "basics") : "history")
      }
    }
  }

  Loader {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 79
    active: window.mode.indexOf("overlay-") === 0
    sourceComponent: OverlayCard { app: appState }
  }

  // Interactions a screenshot cannot reach on its own.
  Timer {
    interval: 350
    running: true
    onTriggered: {
      var root = window.contentItem
      if (window.mode === "journal-search") find(root, "SearchField", function(item) { item.text = "workshop" })
      if (window.mode === "journal-settings") find(root, "JournalSettingsSheet", function(item) { item.open = true })
      var views = { "todos-today": "today", "todos-bubbled": "today", "todos-later": "today", "todos-reminder": "today", "todos-keyboard": "today", "todos-lastdelete": "today", "todos-picker-keep": "today", "todos-uphover": "upcoming", "todos-editlists": "today", "todos-picker-past": "today", "todos-narrow": "today", "todos-upcoming": "upcoming", "todos-all": "all", "todos-done": "done",
        "todos-list": "list:Infra", "todos-inbox-empty": "list:" }
      if (views[window.mode]) find(root, "TodosScreen", function(item) { item.place(views[window.mode]) })
      // The When menu in the morning, when Later today is still on offer.
      if (window.mode === "todos-due-morning") { appState.clockOverride = new Date(2026, 8, 25, 8, 30).getTime(); appState.nowMs = appState.clockOverride }
      if (window.mode === "todos-hover" || window.mode === "todos-rowmenu" || window.mode === "todos-due" || window.mode === "todos-due-morning")
        find(root, "TodoRow", function(item, index) { if (index === 1) {
          item.current = true
          if (window.mode === "todos-rowmenu") item.menuRequested(item.menuAnchor)
          if (window.mode.indexOf("todos-due") === 0) item.dueRequested(item.dueAnchor)
        } })
      if (window.mode === "todos-later")
        find(root, "TodoRow", function(row, index) { if (index === 0) row.laterRequested(row.laterAnchor) })
      // The bell on a to-do whose reminder was set by hand.
      if (window.mode === "todos-reminder")
        find(root, "TodoRow", function(row) { if (row.todo.index === 5) row.reminderRequested(row.reminderAnchor) })
      if (window.mode === "todos-picker")
        find(root, "TodoRow", function(row, index) { if (index === 1) {
          row.current = true
          find(root, "TodosScreen", function(screen) { screen.menuTodo = row.todo })
          find(root, "DuePicker", function(picker) { picker.anchorItem = row.dueAnchor; picker.date = row.todo.due; picker.time = "9:30"; picker.open = true })
        } })
      // The picker's Remind me line, open on its times.
      if (window.mode === "todos-remindmenu")
        find(root, "TodoRow", function(row, index) { if (index === 1) {
          find(root, "TodosScreen", function(screen) { screen.menuTodo = row.todo })
          find(root, "DuePicker", function(picker) {
            picker.anchorItem = row.dueAnchor; picker.date = "2026-09-28"; picker.time = "15:00"; picker.open = true
            find(picker, "PopupMenu", function(menu) { menu.open = true })
          })
        } })
      if (window.mode === "todos-settings") find(root, "TodosScreen", function(item) { for (var i = 0; i < item.children.length; i++) if (String(item.children[i]).indexOf("Sheet") === 0) item.children[i].open = true })
      if (window.mode === "todos-folder-move") find(root, "Sheet", function(item) { item.open = true; item.editingFolder = true; item.useFolder("~/Notes/To-dos") })
      if (window.mode === "todos-listmenu") find(root, "TodosScreen", function(item) { item.openListMenu("Dev") })
      if (window.mode === "todos-newlist") find(root, "TodosScreen", function(item) { item.makingList = true })
      if (window.mode === "overlay-todos-saved-editing") find(root, "OverlayCard", function(card) { card.editingIndex = Fixtures.SAVED[1].index })
      // Said while the take records; the first click on Discard of a long take.
      if (window.mode === "overlay-locked-busy") appState.feedbackSerial += 1
      if (window.mode === "overlay-locked-asking") find(root, "DiscardTake", function(pill) { pill.clicked() })
      if (window.mode === "overlay-todo-menu" || window.mode === "overlay-todos-saved-menu") find(root, "OverlayCard", function(card) { card.menuArea.x = window.mode === "overlay-todo-menu" ? 152 : 172; card.menuArea.open = true })
      if (window.mode === "todos-editing") find(root, "TodoRow", function(item, index) { if (index === 0) item.editing = true })
      if (window.mode === "todos-settling") find(root, "TodoRow", function(item, index) { if (index === 2) item.settling = true })
      if (window.mode === "todos-undo") find(root, "TodosScreen", function(item) {
        var gone = Fixtures.FLAT[2]
        item.todos = Fixtures.FLAT.filter(function(t) { return t !== gone })
        item.pending = { kind: "delete", items: [gone], view: item.viewKey, slot: 2 }
      })
      if (window.mode === "history-notinstalled") { appState.binaryFound = false; appState.history = []; appState.pluginDir = "/home/you/.config/omarchy/plugins/entroit.omaflow" }
      if (window.mode === "history-raw") find(root, "HistoryScreen", function(item) { item.view = "raw" })
      if (window.mode === "history-skipped") find(root, "HistoryScreen", function(item) { item.selectedId = "3" })
      // The dot on the mark: an update ready, and one that did not finish.
      if (window.mode === "history-update" || window.mode === "history-update-failed")
        appState.updateOffer = { checkedAtMs: Fixtures.NOW, target: { commit: "abc123", version: "0.20.0", summary: "", changes: [] } }
      if (window.mode === "history-update-failed") appState.updateTransaction = { state: "rolled-back", targetCommit: "abc123", targetVersion: "0.20.0", message: "The update did not finish. Your previous version is still running." }
      if (window.mode === "history-restarting") appState.pendingAction = "restart"
      if (window.mode === "history-tabhint") find(root, "MainView", function(view) { find(root, "Pill", function(pill) { if (pill.hint === "Ctrl+2") view.hoveredTab = pill }) })
      if (window.mode === "settings-privacy-trim") find(root, "SettingsPrivacy", function(item) { item.confirmLimit = 2 })
      if (window.mode === "history-edited") find(root, "HistoryScreen", function(item) { item.view = "changes" })
      if (window.mode === "history-dirty") find(root, "TextArea", function(item) { item.text += " Thanks!" })
      if (window.mode.indexOf("settings-updates-") === 0) {
        appState.updateOffer = { checkedAtMs: Fixtures.NOW, target: { commit: "abc123", version: "0.20.0", summary: "Spoken to-dos get reminders.", changes: ["Reminders for to-dos with a time.", "Copy in History copies what you see."] } }
        if (window.mode === "settings-updates-later") appState.updateDeferral = { commit: "abc123", untilMs: Fixtures.NOW + 86400000 }
        if (window.mode === "settings-updates-failed") appState.updateRequestError = "The OmaFlow folder changed outside OmaFlow. Choose Check now to see what to do."
        // What `omaflow update status` says once the updater is gone.
        if (window.mode === "settings-updates-interrupted") appState.updateTransaction = { state: "interrupted", targetCommit: "abc123", targetVersion: "0.20.0", message: "The update stopped before it installed anything. Your current version still works. Try again to install it." }
        // Half replaced: dictation is paused until Put back brings the old version back.
        if (window.mode === "settings-updates-paused") appState.updateTransaction = { state: "interrupted", blocksDictation: true, targetCommit: "abc123", targetVersion: "0.20.0", originalRelease: { version: "0.19.0" }, message: "The update stopped partway through. Put back 0.19.0 to dictate again, then update." }
        // The folder moved off the installed version, and a check under way.
        if (window.mode === "settings-updates-folder") appState.updateOffer = Object.assign({}, appState.updateOffer, { externalCheckoutWarning: "Updates are paused. Review the changes in /home/you/.config/omarchy/plugins/entroit.omaflow with git, then choose Check now. To go back to OmaFlow 0.19.0, run: git -C /home/you/.config/omarchy/plugins/entroit.omaflow checkout 3f9c2a1b7d4e" })
        if (window.mode === "settings-updates-checking") { appState.updateOffer = { checkedAtMs: Fixtures.NOW }; appState.updateChecking = true }
      }
      // A voice above the threshold, which the room's noise put at -52 dB.
      if (window.mode.indexOf("settings-audio") === 0) appState.applyLevel("0.550 -40.0 1" + " 0.400".repeat(13) + " -52")
      if (window.mode === "journal-hover" || window.mode === "journal-playing-hover" || window.mode === "journal-narrow")
        find(root, "JournalEntry", function(item, index) { if (index === 1) item.current = true })
      if (window.mode === "journal-search-fail") find(root, "SearchField", function(item) { item.text = "workshop" })
      if (window.mode === "journal-search-note") find(root, "SearchField", function(item) { item.text = "Mira" })
      // A day a year back, and a search result on a long day name: the title
      // keeps its year above the way back.
      if (window.mode === "journal-other-year") find(root, "JournalScreen", function(screen) { screen.openDay("2025-09-24") })
      if (window.mode === "journal-hit-long") {
        find(root, "SearchField", function(item) { item.text = "workshop" })
        find(root, "JournalScreen", function(screen) { screen.results = Fixtures.SEARCH; screen.openResult(3) })
      }
      if (window.mode === "journal-toast-error") find(root, "JournalScreen", function(screen) { screen.flash(screen.writeError("That entry is no longer in the file", Fixtures.TODAY), true) })
      if (window.mode === "journal-export-fail") find(root, "JournalSettingsSheet", function(item) {
        item.open = true
        item.exportError = true
        item.exportMessage = "Couldn't export: Could not write /home/you/Downloads/Journal 2026-09-25.md: No space left on device (os error 28)."
      })
      // To-dos: the date's own action under the pointer in Upcoming, the
      // keyboard on a row, the last to-do of Today deleted, a name that is
      // taken, and a reminder set by hand as the time moves.
      if (window.mode === "todos-uphover") find(root, "TodoRow", function(item, index) { if (index === 0) item.current = true })
      if (window.mode === "todos-keyboard") find(root, "TodosScreen", function(item) { item.cursor = 1 })
      if (window.mode === "todos-lastdelete") find(root, "TodosScreen", function(item) {
        item.todos = Fixtures.TODOS.filter(function(t) { return !(t.due && t.due <= Fixtures.TODAY) })
        item.pending = { kind: "delete", items: [Fixtures.TODOS[0]], view: "today", slot: 0 }
      })
      if (window.mode === "todos-listerror") find(root, "TodosScreen", function(item) { item.makingList = true; item.listError = "A list called Dev is already in the file." })
      if (window.mode === "todos-picker-keep")
        find(root, "TodoRow", function(row, index) { if (index === 2) {
          find(root, "TodosScreen", function(screen) { screen.menuTodo = row.todo })
          find(root, "DuePicker", function(picker) {
            picker.anchorItem = row.dueAnchor; picker.date = "2026-09-25"; picker.time = "17:00"; picker.reminder = "2026-09-25 16:20"; picker.open = true
            find(picker, "TextField", function(field) { field.text = "18:00" })
          })
        } })
      if (window.mode === "journal-editing") find(root, "JournalScreen", function(screen) { screen.editingId = String(Fixtures.DAY.entries[0].id) })
      if (window.mode === "journal-deleted") find(root, "JournalScreen", function(screen) { screen.deleteEntry(Fixtures.TODAY, Fixtures.DAY.entries[0], 0) })
      if (window.mode === "todos-editlists") find(root, "TodoRow", function(item, index) { if (index === 0) item.editing = true })
      if (window.mode === "todos-folder-edit") find(root, "Sheet", function(item) { item.open = true; item.editingFolder = true })
      if (window.mode === "todos-picker-past")
        find(root, "TodoRow", function(row, index) { if (index === 0) {
          find(root, "TodosScreen", function(screen) { screen.menuTodo = row.todo })
          find(root, "DuePicker", function(picker) { picker.anchorItem = row.dueAnchor; picker.date = "2026-09-25"; picker.time = "18:30"; picker.open = true })
        } })
      if (window.mode === "journal-hit") {
        find(root, "SearchField", function(item) { item.text = "workshop" })
        find(root, "JournalScreen", function(screen) { screen.results = Fixtures.SEARCH; screen.openResult(0) })
      }
      if (window.mode === "journal-past" || window.mode === "journal-past-empty") find(root, "JournalScreen", function(screen) { screen.openDay("2026-09-18") })
      if (window.mode === "journal-move" || window.mode === "journal-move-clash") find(root, "JournalSettingsSheet", function(item) {
        item.open = true
        item.editingFolder = true
        item.useFolder("~/Notes/Journal")
        if (window.mode === "journal-move-clash") { item.folderError = true; item.folderMessage = "2 days already exist in ~/Notes/Journal: 2026-09-24, 2026-09-25. Nothing was moved." }
      })
      if (window.mode === "journal-typing") find(root, "TextArea", function(field) {
        if (field.Accessible.name === "Type a journal entry") field.text = "Ran 5 km along the river.\nKnee fine, and the light on the water was something."
      })
      if (window.mode === "journal-settings-confirm") {
        appState.cleanupEnabled = false
        appState.journalSettings = Object.assign({}, appState.journalSettings, { cleanup: "medium" })
        find(root, "JournalSettingsSheet", function(item) { item.open = true; item.confirmRecordings = true })
      }
      if (window.mode === "settings-ownmodel-server") find(root, "SettingsOwnModel", function(item) { item.engine = "openai" })
      if (window.mode === "settings-privacy-off") find(root, "SettingsPrivacy", function(item) { item.confirmLimit = 0 })
      if (window.mode === "settings-privacy-audio") find(root, "SettingsPrivacy", function(item) { item.confirmAudio = true })
      if (window.mode === "settings-basics-recording") find(root, "SettingsBasics", function(item) { item.recordingHold = true })
      if (window.mode === "settings-cleanup-server") find(root, "SettingsCleanup", function(item) { item.showServer = true })
      // The erase confirm sits at the bottom of the page.
      if (window.mode === "settings-privacy-erase") find(root, "SettingsPrivacy", function(item) {
        item.confirmErase = true
        find(root, "QQuickFlickable", function(flick) { flick.contentY = Math.max(0, flick.contentHeight - flick.height) })
      })
      if (window.mode === "settings-ownmodel-whisper") find(root, "SettingsOwnModel", function(item) { item.engine = "whisper-cpp" })
      if (window.mode === "settings-hotkeys-window" || window.mode === "settings-hotkeys-dictate")
        find(root, "SettingsHotkeys", function(item) { item.editing = window.mode.slice(17) })
    }
  }
  function find(item, type, action) {
    var found = 0
    function walk(node) {
      if (String(node).indexOf(type + "_QML") === 0 || String(node).indexOf(type + "(") === 0 || node.objectName === type) action(node, found++)
      for (var i = 0; i < node.children.length; i++) walk(node.children[i])
    }
    walk(item)
  }

  Timer {
    interval: 1100
    running: true
    onTriggered: window.contentItem.grabToImage(function(result) {
      result.saveToFile(window.output)
      Qt.quit()
    })
  }
}
