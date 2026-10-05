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
  width: mode.indexOf("overlay-") === 0 ? 720 : 880
  height: mode.indexOf("overlay-") !== 0 ? 720
    : mode.indexOf("todos-saved") > 0 ? (mode.indexOf("-menu") > 0 ? 440 : 300)
    : mode.indexOf("-menu") > 0 ? 330 : 200
  visible: true
  color: Theme.background

  readonly property var args: Qt.application.arguments
  readonly property string mode: args.length >= 2 ? args[args.length - 2] : "journal"
  readonly property string output: args.length >= 1 ? args[args.length - 1] : "/tmp/preview.png"

  Rectangle { anchors.fill: parent; color: Theme.background }

  App {
    id: appState
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    host: QtObject {
      function spawn(argv, callback) {
        var reply = ""
        if (argv[1] === "journal") {
          var command = argv[2]
          if (command === "day") reply = window.mode === "journal-first" ? JSON.stringify({ date: argv[3], title: "", file: "", exists: false, entries: [] })
            : window.mode === "journal-empty" ? JSON.stringify({ date: argv[3], title: "", file: "", exists: false, entries: [] })
            : JSON.stringify(Fixtures.DAY)
          else if (command === "month") reply = window.mode === "journal-first" ? JSON.stringify({ month: argv[3], days: [] }) : JSON.stringify(Fixtures.MONTH)
          else if (command === "year-ago") reply = window.mode === "journal-first" ? "null" : JSON.stringify(Fixtures.YEAR_AGO)
          else if (command === "stats") reply = JSON.stringify({ days: window.mode === "journal-first" ? 0 : 16 })
          else if (command === "search") reply = JSON.stringify(Fixtures.SEARCH)
        } else if (argv[1] === "todos" && argv[2] === "list") {
          var flat = Fixtures.FLAT_MODES.indexOf(window.mode) >= 0 || window.mode.indexOf("overlay-") === 0 && window.mode.indexOf("-inbox") > 0
          reply = JSON.stringify({ path: "/home/you/Documents/To-dos/To-dos.md", today: Fixtures.TODAY,
            lists: flat ? [] : Fixtures.LISTS, current: "Infra",
            todos: window.mode === "todos-empty" ? [] : flat ? Fixtures.FLAT : Fixtures.TODOS })
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
      if (window.mode === "journal-talking" || window.mode === "overlay-journal" || window.mode.indexOf("overlay-todo") === 0 || window.mode === "todos-talking" || window.mode === "overlay-holding" || window.mode === "overlay-locked") {
        var wave = []
        for (var i = 0; i < 120; i++) wave.push(0.2 + 0.65 * Math.abs(Math.sin(i * 1.7) * Math.cos(i * 0.31)))
        waveHistory = wave
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
      var views = { "todos-today": "today", "todos-upcoming": "upcoming", "todos-all": "all", "todos-done": "done" }
      if (views[window.mode]) find(root, "TodosScreen", function(item) { item.select(views[window.mode], "") })
      if (window.mode === "todos-hover" || window.mode === "todos-move" || window.mode === "todos-due")
        find(root, "TodoRow", function(item, index) { if (index === 1) {
          item.current = true
          if (window.mode === "todos-move") item.moveRequested(item.moveAnchor)
          if (window.mode === "todos-due") item.dueRequested(item.dueAnchor)
        } })
      if (window.mode === "todos-picker")
        find(root, "TodoRow", function(row, index) { if (index === 1) {
          row.current = true
          find(root, "TodosScreen", function(screen) { screen.menuTodo = row.todo })
          find(root, "DuePicker", function(picker) { picker.anchorItem = row.dueAnchor; picker.date = row.todo.due; picker.time = "9:30"; picker.open = true })
        } })
      if (window.mode === "todos-listmenu") find(root, "TodosScreen", function(item) { item.openListMenu("Dev") })
      if (window.mode === "todos-newlist") find(root, "TodosScreen", function(item) { item.makingList = true })
      if (window.mode === "overlay-todos-saved-editing") find(root, "OverlayCard", function(card) { card.editingIndex = Fixtures.TODOS[3].index })
      if (window.mode === "overlay-todo-menu" || window.mode === "overlay-todos-saved-menu") find(root, "OverlayCard", function(card) { card.menuArea.x = window.mode === "overlay-todo-menu" ? 152 : 172; card.menuArea.open = true })
      if (window.mode === "todos-editing") find(root, "TodoRow", function(item, index) { if (index === 0) item.editing = true })
      if (window.mode === "todos-settling") find(root, "TodoRow", function(item, index) { if (index === 2) item.settling = true })
      if (window.mode === "todos-undo") find(root, "TodosScreen", function(item) {
        var gone = Fixtures.FLAT[2]
        item.todos = Fixtures.FLAT.filter(function(t) { return t !== gone })
        item.pending = { kind: "delete", items: [gone], view: item.viewKey, slot: 2 }
      })
      if (window.mode === "journal-hover") find(root, "JournalEntry", function(item, index) { if (index === 1) item.current = true })
      if (window.mode === "settings-ownmodel-server") find(root, "SettingsOwnModel", function(item) { item.engine = "openai" })
    }
  }
  function find(item, type, action) {
    var found = 0
    function walk(node) {
      if (String(node).indexOf(type + "_QML") === 0 || String(node).indexOf(type + "(") === 0) action(node, found++)
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
