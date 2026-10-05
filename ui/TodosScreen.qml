import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import "Dates.js" as Dates

// The to-do list, with a rail like the journal's: Today, Upcoming, All and
// Done across every list, then the Inbox, your lists and New list. What you
// talk or type goes to the list you are in; from Today and the other views,
// and from the shortcut in any app, it goes to the current list, the one you
// last added to or picked. It reads To-dos.md through the app, so a task ticked in
// another notes app shows up here ticked.
FocusScope {
  id: screen

  required property var app
  property bool active: false

  property var todos: []
  property var lists: []
  property string today: app.todayIso()
  property string filePath: ""
  property string loadError: ""
  property bool loaded: false
  property bool opened: false

  // "today", "upcoming", "all", "done", or "list" with `viewList`, "" being
  // the Inbox.
  property string view: "list"
  property string viewList: ""

  property int editingIndex: -1
  property string editDraft: ""
  // The keyboard cursor, over the to-dos as shown.
  property int cursor: -1
  property bool doneShown: true
  property string toast: ""
  property bool toastError: false
  property string toastAction: ""
  // Tasks just ticked, kept in place while the line is drawn through them.
  property var settling: []
  // Tasks deleted or cleared, shown greyed out in place for the ten seconds
  // they can come back: { kind: "delete" | "clear", items, view, slot }.
  property var pending: null
  // A list just deleted, which Undo in the toast brings back.
  property string deletedList: ""
  property bool makingList: false
  property string renaming: ""
  // The to-do a Move or date menu is open for.
  property var menuTodo: null

  readonly property bool hasLists: lists.length > 0
  readonly property string viewKey: view === "list" ? "list:" + viewList : view
  // Where typed and spoken to-dos go from here.
  readonly property string targetList: view === "list" ? viewList : app.todoList
  readonly property string targetDue: view === "today" ? today : ""
  readonly property bool listening: app.todoTake && ["recording", "processing"].indexOf(app.phase) >= 0

  function isSettling(todo) {
    return settling.some(function(s) { return s.index === todo.index && s.text === todo.text })
  }
  function isOpen(todo) { return !todo.done || isSettling(todo) }
  function openIn(list) { return todos.filter(function(t) { return !t.done && t.list === list }).length }
  readonly property int todayCount: todos.filter(function(t) { return !t.done && t.due && t.due <= today }).length
  readonly property int upcomingCount: todos.filter(function(t) { return !t.done && t.due && t.due > today }).length
  readonly property int openCount: todos.filter(function(t) { return !t.done }).length
  readonly property int doneCount: todos.filter(function(t) { return t.done && !isSettling(t) }).length
  // By day, then by the clock, a day's to-dos with no time last.
  function dueKey(todo) { return String(todo.due || "") + " " + String(todo.time || "99:99") }
  function byDue(a, b) { var x = dueKey(a.todo), y = dueKey(b.todo); return x < y ? -1 : x > y ? 1 : a.todo.index - b.todo.index }
  readonly property string nowClock: {
    var now = new Date(app.nowMs)
    return String(now.getHours()).padStart(2, "0") + ":" + String(now.getMinutes()).padStart(2, "0")
  }

  // What the page shows, top to bottom: to-dos, the headings between them,
  // the Done group, the Undo bars, or what to say when there is nothing.
  readonly property var rows: {
    var out = []
    var row = function(todo, showList) { return { kind: "row", todo: todo, ghost: false, showList: showList } }
    var cross = hasLists
    if (view === "list") {
      todos.filter(function(t) { return t.list === viewList && isOpen(t) })
        .forEach(function(t) { out.push(row(t, false)) })
      if (out.length === 0 && !listening && !(pending && pending.kind === "delete" && pending.view === viewKey))
        out.push({ kind: "empty" })
      var done = todos.filter(function(t) { return t.list === viewList && t.done && !isSettling(t) })
      var clearing = pending && pending.kind === "clear" && pending.view === viewKey
      if (done.length > 0 || clearing) {
        out.push({ kind: "done", count: done.length })
        if (doneShown) {
          done.forEach(function(t) { out.push(row(t, false)) })
          if (clearing) {
            pending.items.forEach(function(t) { out.push({ kind: "row", todo: t, ghost: true, showList: false }) })
            out.push({ kind: "undo", label: pending.items.length === 1 ? "1 done to-do cleared" : pending.items.length + " done to-dos cleared" })
          }
        }
      }
    } else if (view === "today") {
      todos.filter(function(t) { return isOpen(t) && t.due && t.due <= today })
        .map(function(t) { return row(t, cross) }).sort(byDue)
        .forEach(function(r) { out.push(r) })
      if (out.length === 0 && !listening) out.push({ kind: "empty" })
    } else if (view === "upcoming") {
      var last = ""
      todos.filter(function(t) { return isOpen(t) && t.due && t.due > today })
        .map(function(t) { return row(t, cross) }).sort(byDue)
        .forEach(function(r) {
          if (r.todo.due !== last) {
            last = r.todo.due
            var tomorrow = Dates.due(last, today) === "Tomorrow"
            out.push({ kind: "heading", label: tomorrow ? "Tomorrow" : Dates.long(last, today), detail: tomorrow ? Dates.long(last, today) : "" })
          }
          out.push(r)
        })
      if (out.length === 0) out.push({ kind: "empty" })
    } else if (view === "all") {
      [""].concat(lists).forEach(function(list) {
        var items = todos.filter(function(t) { return t.list === list && isOpen(t) })
        if (items.length === 0) return
        out.push({ kind: "heading", label: list || "Inbox", list: list, dot: true, count: items.length })
        items.forEach(function(t) { out.push(row(t, false)) })
      })
      if (out.length === 0) out.push({ kind: "empty" })
    } else if (view === "done") {
      todos.filter(function(t) { return t.done && !isSettling(t) })
        .forEach(function(t) { out.push(row(t, cross)) })
      if (pending && pending.kind === "clear" && pending.view === viewKey) {
        pending.items.forEach(function(t) { out.push({ kind: "row", todo: t, ghost: true, showList: cross }) })
        out.push({ kind: "undo", label: pending.items.length === 1 ? "1 done to-do cleared" : pending.items.length + " done to-dos cleared" })
      } else if (out.length === 0) out.push({ kind: "empty" })
    }
    if (pending && pending.kind === "delete" && pending.view === viewKey) {
      var at = Math.min(pending.slot, out.length)
      out.splice(at, 0, { kind: "row", todo: pending.items[0], ghost: true, showList: view !== "list" && view !== "all" && cross },
                 { kind: "undo", label: "" })
    }
    return out
  }
  // What the arrow keys move over: the live to-dos, as shown.
  readonly property var navigable: rows.filter(function(r) { return r.kind === "row" && !r.ghost }).map(function(r) { return r.todo })

  readonly property string title: view === "today" ? "Today" : view === "upcoming" ? "Upcoming"
    : view === "all" ? "All" : view === "done" ? "Done" : viewList || "Inbox"
  readonly property string subtitle: view === "today" ? Dates.long(today, today)
    : view === "all" ? openCount + " open in " + [""].concat(lists).filter(function(l) { return openIn(l) > 0 }).length + (hasLists ? " lists" : " list")
    : ""
  readonly property string emptyTitle: loadError ? "The list could not be read."
    : view === "today" ? "Nothing due today."
    : view === "upcoming" ? "Nothing coming up."
    : view === "all" ? "Nothing to do."
    : view === "done" ? "Nothing done yet."
    : todos.some(function(t) { return t.list === viewList && t.done }) ? (viewList ? "All done in " + viewList + "." : "All done.")
    : "Nothing to do yet."
  readonly property string emptyBody: {
    if (loadError) return loadError
    if (view === "today") {
      var next = todos.filter(function(t) { return !t.done && t.due && t.due > today }).sort(function(a, b) { return a.due < b.due ? -1 : 1 })[0]
      return next ? "Next: " + next.text + ", " + Dates.due(next.due, today) : "Talk or type below and it's due today."
    }
    if (view === "upcoming") return "To-dos with a date after today show here, by day. Say \"by Friday\" and it gets one."
    if (view === "all" || view === "done") return ""
    var how = app.todoShortcut && (viewList === app.todoList || !hasLists)
      ? "Hold " + app.todoShortcut + " in any app and say what you need to do. Each task gets its own line."
      : "Talk or type below. Say several things at once and each gets its own line."
    return hasLists ? how : how + " To keep work and errands apart, make a list for each with New list on the left."
  }

  function reload() {
    if (!app) return
    today = app.todayIso()
    app.query(["todos", "list"], function(value, error) {
      if (value) {
        todos = value.todos || []
        lists = value.lists || []
        filePath = String(value.path || "")
        if (value.today) today = String(value.today)
        loadError = ""
        // Opening the tab starts where new to-dos go.
        if (!opened) { opened = true; view = "list"; viewList = lists.length > 0 ? String(value.current || "") : "" }
        if (view === "list" && viewList && lists.indexOf(viewList) < 0) viewList = ""
      } else loadError = error
      loaded = true
      cursor = Math.min(cursor, navigable.length - 1)
    })
  }
  function select(nextView, list) {
    view = nextView
    viewList = list || ""
    editingIndex = -1
    cursor = -1
    doneShown = true
    screen.focusKeys()
  }
  function flash(message, error, action) {
    toast = message
    toastError = Boolean(error)
    toastAction = action || ""
    toastTimer.interval = action ? 10000 : 3200
    toastTimer.restart()
  }
  function afterWrite(value, error) {
    if (error) flash(error, true)
    reload()
  }
  function startEdit(todo) {
    if (todo.done) return
    editingIndex = todo.index
    editDraft = todo.text
  }
  // Ticking the to-do you are editing keeps what you typed, then ticks it.
  function toggle(todo) {
    var edited = ""
    if (editingIndex === todo.index && !todo.done) {
      var draft = editDraft.trim()
      if (draft.length > 0 && draft !== todo.text) edited = draft
      editingIndex = -1
      focusKeys()
    }
    if (!todo.done) {
      settling = settling.concat([{ index: todo.index, text: todo.text }], edited ? [{ index: todo.index, text: edited }] : [])
      settleTimer.restart()
    }
    if (edited) {
      app.query(["todos", "edit", todo.index, todo.text, edited], function(value, error) {
        if (error) afterWrite(value, error)
        else app.query(["todos", "done", todo.index, edited], afterWrite)
      })
    } else app.query(["todos", todo.done ? "undone" : "done", todo.index, todo.text], afterWrite)
  }
  function saveEdit(todo, text) {
    editingIndex = -1
    app.query(["todos", "edit", todo.index, todo.text, text], afterWrite)
    screen.focusKeys()
  }
  // A new day keeps the to-do's time unless one is given; no date drops both.
  function setDue(todo, due, time) {
    var at = time === undefined ? String(todo.time || "") : time
    app.query(["todos", "due", todo.index, todo.text, due, due ? at : ""], afterWrite)
  }
  function moveTo(todo, list) {
    app.query(["todos", "move", todo.index, todo.text, list], function(value, error) {
      if (!error) flash("Moved to " + (list || "Inbox"), false)
      afterWrite(value, error)
    })
  }
  // One click deletes, with Undo for ten seconds instead of a question first.
  // Only the last delete or clear can come back.
  function remove(todo) {
    editingIndex = -1
    var slot = rows.findIndex(function(r) { return r.kind === "row" && !r.ghost && r.todo.index === todo.index })
    pending = { kind: "delete", items: [todo], view: viewKey, slot: Math.max(0, slot) }
    deletedList = ""
    deleteTimer.restart()
    app.query(["todos", "delete", todo.index, todo.text], function(value, error) {
      if (error) { pending = null; deleteTimer.stop() }
      afterWrite(value, error)
    })
  }
  function clearDone() {
    var list = view === "list" ? viewList : null
    var done = todos.filter(function(t) { return t.done && !isSettling(t) && (list === null || t.list === list) })
    if (done.length === 0) return
    pending = { kind: "clear", items: done, view: viewKey, slot: 0 }
    deletedList = ""
    deleteTimer.restart()
    app.query(list === null ? ["todos", "clear-done"] : ["todos", "clear-done", list], function(value, error) {
      if (error) { pending = null; deleteTimer.stop() }
      afterWrite(value, error)
    })
  }
  function undo() {
    if (!pending && !deletedList) return
    pending = null
    deletedList = ""
    toast = ""
    deleteTimer.stop()
    app.query(["todos", "restore"], afterWrite)
  }
  function moveCursor(step) {
    if (navigable.length === 0) return
    cursor = Math.max(0, Math.min(navigable.length - 1, cursor + step))
  }
  function addTyped(text) {
    var list = targetList
    app.query(["todos", "add", text, list, targetDue], function(value, error) {
      if (!error) {
        composer.clearInput()
        // Adding to a list makes it the current one.
        if (hasLists && list !== app.todoList) app.todoSetList(list)
      }
      afterWrite(value, error)
    })
  }
  function createList(name) {
    makingList = false
    name = String(name || "").trim()
    if (!name) return
    app.query(["todos", "new-list", name], function(value, error) {
      if (value) select("list", value.list)
      afterWrite(value, error)
    })
  }
  function renameList(name, newName) {
    renaming = ""
    newName = String(newName || "").trim()
    if (!newName || newName === name) return
    app.query(["todos", "rename-list", name, newName], function(value, error) {
      if (value) {
        var renamed = String(value.list || newName)
        if (viewList === name) viewList = renamed
        if (app.todoList === name) app.todoSetList(renamed)
      }
      afterWrite(value, error)
    })
  }
  function deleteList(name) {
    var count = openIn(name) + todos.filter(function(t) { return t.list === name && t.done }).length
    app.query(["todos", "delete-list", name], function(value, error) {
      if (!error) {
        if (viewList === name) select("list", "")
        if (app.todoList === name) app.todoSetList("")
        pending = null
        deletedList = name
        deleteTimer.restart()
        flash(name + " deleted." + (count === 1 ? " Its to-do is in the Inbox." : count > 1 ? " Its " + count + " to-dos are in the Inbox." : ""), false, "Undo")
      }
      afterWrite(value, error)
    })
  }

  // Rename and Delete for a list, under its place in the rail.
  function openListMenu(name) {
    for (var i = 0; i < railLists.count; i++) {
      var slot = railLists.itemAt(i)
      if (slot && slot.modelData === name) {
        listMenu.list = name
        listMenu.anchorItem = slot
        listMenu.open = true
      }
    }
  }

  // The rail, top to bottom, for [ and ].
  readonly property var places: ["today", "upcoming", "all", "done", "list:"].concat(lists.map(function(l) { return "list:" + l }))
  function step(delta) {
    var at = places.indexOf(viewKey)
    var next = places[(at + delta + places.length) % places.length]
    if (next.indexOf("list:") === 0) select("list", next.slice(5)); else select(next, "")
  }

  // The page's own keys, with no field focused. Focusing the scope itself
  // would hand focus back to the last field in it.
  Item { id: keyTarget; focus: true }
  function focusKeys() { keyTarget.forceActiveFocus() }

  onActiveChanged: if (active) reload()
  Component.onCompleted: if (active) reload()

  Connections {
    target: screen.app
    // A capture landed in the list, or Undo took it out. Never reload under
    // an edit you are making.
    function onTodosRevisionChanged() { if (screen.active && screen.editingIndex < 0) screen.reload() }
  }
  Timer { id: toastTimer; interval: 3200; onTriggered: { screen.toast = ""; screen.toastAction = "" } }
  Timer { id: settleTimer; interval: 700; onTriggered: screen.settling = [] }
  Timer {
    id: deleteTimer
    interval: 10250
    onTriggered: {
      screen.pending = null
      screen.deletedList = ""
      screen.app.spawn(["omaflow", "todos", "forget-deleted"])
    }
  }

  Keys.onPressed: function(event) {
    var todo = cursor >= 0 && cursor < navigable.length ? navigable[cursor] : null
    if ((pending || deletedList) && event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) undo()
    else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) moveCursor(1)
    else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) moveCursor(-1)
    else if (event.key === Qt.Key_BracketRight) step(1)
    else if (event.key === Qt.Key_BracketLeft) step(-1)
    else if (todo && (event.key === Qt.Key_Space || event.key === Qt.Key_X)) toggle(todo)
    else if (todo && !todo.done && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_F2)) startEdit(todo)
    else if (todo && event.key === Qt.Key_Delete) remove(todo)
    else if (event.key === Qt.Key_Escape && cursor >= 0) cursor = -1
    else if (event.key === Qt.Key_N || event.key === Qt.Key_Slash) composer.focusInput()
    else return
    event.accepted = true
  }

  // A deleted or cleared task's Undo, and the time until it is gone.
  component UndoBar: Item {
    id: bar
    property string label: ""
    property real elapsed: 0
    NumberAnimation on elapsed { from: 0; to: 1; duration: 10000; running: true }
    implicitHeight: 34
    Row {
      id: undoRow
      x: 48
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8
      UiText { anchors.verticalCenter: parent.verticalCenter; visible: text.length > 0; text: bar.label; muted: true; rightPadding: 4 }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Undo"; verticalPadding: 4; horizontalPadding: 12; onClicked: screen.undo() }
      Keycap { anchors.verticalCenter: parent.verticalCenter; compact: true; text: "Ctrl Z" }
    }
    Rectangle {
      x: undoRow.x + undoRow.width + 14
      width: parent.width - x - 16
      anchors.verticalCenter: parent.verticalCenter
      height: 3; radius: 1.5
      color: Theme.fill8
      Rectangle { width: parent.width * bar.elapsed; height: parent.height; radius: parent.radius; color: Theme.alpha(Theme.text, 0.4) }
    }
  }

  // A list's dot: its colour, or an empty ring for the Inbox.
  component Dot: Rectangle {
    property string list: ""
    width: 7; height: 7; radius: 3.5
    color: list ? Theme.listColor(list) : "transparent"
    border.width: list ? 0 : 1.2
    border.color: Theme.outline
  }

  // One place in the rail.
  component Place: Rectangle {
    id: place
    property string label: ""
    property int count: 0
    property bool selected: false
    property bool dotted: false
    property string list: ""
    property bool late: false
    // A list has Rename and Delete: under ⋯ on hover, or a right-click.
    property bool hasMenu: false
    readonly property bool showMore: hasMenu && (placeMouse.containsMouse || moreArea.containsMouse)
    signal picked()
    signal menuRequested()
    width: parent ? parent.width : 0
    height: 34
    radius: 9
    color: selected ? Theme.fill8 : placeMouse.containsMouse || moreArea.containsMouse ? Theme.fill4 : "transparent"
    Dot { visible: place.dotted; list: place.list; x: 12; anchors.verticalCenter: parent.verticalCenter }
    UiText {
      x: place.dotted ? 29 : 12
      anchors.verticalCenter: parent.verticalCenter
      width: (place.showMore ? parent.width - 34 : countText.x) - x - 8
      elide: Text.ElideRight
      text: place.label
      font.pixelSize: 14
      weight: place.selected ? Font.DemiBold : Font.Normal
    }
    UiText {
      id: countText
      anchors.right: parent.right
      anchors.rightMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      visible: place.count > 0 && !place.showMore
      text: String(place.count)
      color: place.late ? Theme.redText : place.selected ? Theme.text : Theme.secondary
    }
    MouseArea {
      id: placeMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { if (mouse.button === Qt.RightButton) place.menuRequested(); else place.picked() }
    }
    Rectangle {
      visible: place.showMore
      anchors.right: parent.right
      anchors.rightMargin: 4
      anchors.verticalCenter: parent.verticalCenter
      width: 26; height: 26; radius: 7
      color: moreArea.containsMouse ? Theme.fill8 : "transparent"
      Icon { anchors.centerIn: parent; name: "more"; size: 13; color: Theme.text }
      MouseArea { id: moreArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: place.menuRequested() }
      Accessible.role: Accessible.Button
      Accessible.name: "Rename or delete " + place.label
    }
    Accessible.role: Accessible.PageTab
    Accessible.name: place.label + (place.count > 0 ? ", " + place.count : "")
  }

  // A list name being typed: a new list, or a rename.
  component NameField: Rectangle {
    id: nameField
    property string list: ""
    property alias text: nameInput.text
    signal done(string text)
    signal cancelled()
    width: parent ? parent.width : 0
    height: 34
    radius: 9
    color: Theme.fill4
    border.width: 1.5
    border.color: Theme.accent
    Dot { list: nameInput.text.trim() || "?"; x: 12; anchors.verticalCenter: parent.verticalCenter }
    Controls.TextField {
      id: nameInput
      x: 29 - leftPadding
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - x - 8
      background: null
      color: Theme.text
      font.family: Theme.sans
      font.pixelSize: 14
      selectByMouse: true
      placeholderText: "List name"
      placeholderTextColor: Theme.secondary
      Component.onCompleted: { forceActiveFocus(); selectAll() }
      onAccepted: nameField.done(text)
      Keys.onEscapePressed: nameField.cancelled()
      onActiveFocusChanged: if (!activeFocus && visible) nameField.done(text)
      Accessible.name: "List name"
    }
  }

  RowLayout {
    anchors.fill: parent
    spacing: 0

    // ---------------------------------------------------------------- rail
    Item {
      Layout.preferredWidth: 212
      Layout.fillHeight: true

      Flickable {
        anchors.fill: parent
        anchors.topMargin: 22
        anchors.bottomMargin: 16
        contentHeight: railColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
          id: railColumn
          x: 12
          width: parent.width - 24
          spacing: 2
          Place { label: "Today"; count: screen.todayCount; late: screen.todos.some(function(t) { return !t.done && t.due && t.due < screen.today }); selected: screen.view === "today"; onPicked: screen.select("today", "") }
          Place { label: "Upcoming"; count: screen.upcomingCount; selected: screen.view === "upcoming"; onPicked: screen.select("upcoming", "") }
          Place { label: "All"; count: screen.openCount; selected: screen.view === "all"; onPicked: screen.select("all", "") }
          Place { label: "Done"; count: screen.doneCount; selected: screen.view === "done"; onPicked: screen.select("done", "") }
          Item { width: 1; height: 14 }
          Rectangle { width: parent.width; height: 1; color: Theme.divider }
          Item { width: 1; height: 12 }
          Place { label: "Inbox"; dotted: true; list: ""; count: screen.openIn(""); selected: screen.view === "list" && screen.viewList === ""; onPicked: screen.select("list", "") }
          Repeater {
            id: railLists
            model: screen.lists
            Item {
              id: listSlot
              required property string modelData
              width: railColumn.width
              height: 34
              Place {
                id: listPlace
                visible: screen.renaming !== listSlot.modelData
                label: listSlot.modelData
                dotted: true
                list: listSlot.modelData
                hasMenu: true
                count: screen.openIn(listSlot.modelData)
                selected: screen.view === "list" && screen.viewList === listSlot.modelData
                onPicked: screen.select("list", listSlot.modelData)
                onMenuRequested: screen.openListMenu(listSlot.modelData)
              }
              Loader {
                anchors.fill: parent
                active: screen.renaming === listSlot.modelData
                sourceComponent: NameField {
                  text: listSlot.modelData
                  onDone: function(text) { screen.renameList(listSlot.modelData, text) }
                  onCancelled: screen.renaming = ""
                }
              }
            }
          }
          Loader {
            width: parent.width
            active: screen.makingList
            visible: active
            sourceComponent: NameField {
              onDone: function(text) { screen.createList(text) }
              onCancelled: screen.makingList = false
            }
          }
          Rectangle {
            visible: !screen.makingList
            width: parent.width
            height: 34
            radius: 9
            color: newMouse.containsMouse ? Theme.fill4 : "transparent"
            UiText { x: 10; anchors.verticalCenter: parent.verticalCenter; text: "+"; font.pixelSize: 16; muted: true }
            UiText { x: 29; anchors.verticalCenter: parent.verticalCenter; text: "New list"; font.pixelSize: 14; muted: true }
            MouseArea { id: newMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: screen.makingList = true }
            Accessible.role: Accessible.Button
            Accessible.name: "New list"
          }
        }
      }
    }

    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.divider }

    // ---------------------------------------------------------------- page
    Item {
      id: page
      Layout.fillWidth: true
      Layout.fillHeight: true

      // One column, the width of a list you can read down at a glance.
      Item {
        id: column
        y: 26
        width: Math.min(parent.width - 44, 720)
        height: parent.height - 46
        anchors.horizontalCenter: parent.horizontalCenter

        Item {
          id: titleRow
          width: parent.width
          height: 64
          Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.right: titleActions.left
            anchors.rightMargin: 12
            anchors.top: parent.top
            height: 46
            spacing: 14
            BookText {
              id: titleText
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width)
              elide: Text.ElideRight
              wrapMode: Text.NoWrap
              text: screen.title
              size: 36
              weight: Font.Medium
              font.letterSpacing: -0.54
              Accessible.role: Accessible.Heading
            }
            UiText {
              anchors.baseline: titleText.baseline
              visible: text.length > 0
              text: screen.subtitle
              muted: true
            }
          }
          Row {
            id: titleActions
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.top: parent.top
            anchors.topMargin: 8
            spacing: 8
            Pill {
              anchors.verticalCenter: parent.verticalCenter
              visible: screen.view === "done" && screen.doneCount > 0 && !(screen.pending && screen.pending.kind === "clear")
              kind: "link"
              text: "Clear done"
              size: 13
              hint: "Take every done to-do out of the file. Undo brings them back."
              onClicked: screen.clearDone()
            }
            Rectangle {
              visible: screen.todos.length > 0
              anchors.verticalCenter: parent.verticalCenter
              height: 26
              width: fileRow.implicitWidth + 24
              radius: 13
              color: fileMouse.containsMouse ? Theme.fill8 : "transparent"
              border.width: 1
              border.color: Theme.divider
              Row {
                id: fileRow
                anchors.centerIn: parent
                spacing: 7
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "folder"; size: 13; color: Theme.secondary }
                UiText { anchors.verticalCenter: parent.verticalCenter; text: "To-dos.md"; font.family: Theme.mono; font.pixelSize: 11; muted: true }
              }
              MouseArea { id: fileMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: screen.app.openInEditor(screen.filePath) }
              Accessible.role: Accessible.Button
              Accessible.name: "Open To-dos.md in your editor"
            }
            Rectangle {
              id: moreButton
              width: 30; height: 30; radius: 15
              color: moreMouse.containsMouse || moreMenu.open ? Theme.fill8 : "transparent"
              border.width: 1
              border.color: Theme.divider
              Icon { anchors.centerIn: parent; name: "more"; size: 14; color: Theme.text }
              MouseArea { id: moreMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: moreMenu.open = !moreMenu.open }
              Accessible.role: Accessible.Button
              Accessible.name: "To-do options"
            }
          }
        }

        Flickable {
          id: list
          anchors.top: titleRow.bottom
          anchors.bottom: composer.top
          anchors.bottomMargin: 14
          width: parent.width
          clip: true
          contentHeight: body.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: body
            width: list.width
            Repeater {
              model: screen.rows
              delegate: Loader {
                id: slot
                required property var modelData
                required property int index
                width: body.width
                sourceComponent: modelData.kind === "row" ? rowComponent
                  : modelData.kind === "heading" ? headingComponent
                  : modelData.kind === "done" ? doneComponent
                  : modelData.kind === "undo" ? undoComponent
                  : emptyComponent

                Component {
                  id: rowComponent
                  TodoRow {
                    width: slot.width
                    todo: slot.modelData.todo
                    ghost: slot.modelData.ghost
                    showList: slot.modelData.showList
                    // Upcoming says the day above; the row need not repeat it.
                    showDue: screen.view !== "upcoming"
                    today: screen.today
                    now: screen.nowClock
                    canMove: screen.hasLists
                    settling: !slot.modelData.ghost && screen.isSettling(slot.modelData.todo)
                    editing: !slot.modelData.ghost && !slot.modelData.todo.done && screen.editingIndex === slot.modelData.todo.index
                    draft: editing ? screen.editDraft : ""
                    onDraftEdited: function(text) { screen.editDraft = text }
                    current: !slot.modelData.ghost && screen.cursor >= 0 && screen.cursor < screen.navigable.length
                      && screen.navigable[screen.cursor].index === slot.modelData.todo.index
                    onToggled: screen.toggle(slot.modelData.todo)
                    onEditRequested: screen.startEdit(slot.modelData.todo)
                    onCancelRequested: { screen.editingIndex = -1; screen.focusKeys() }
                    onSaveRequested: function(text) { screen.saveEdit(slot.modelData.todo, text) }
                    onDeleteRequested: screen.remove(slot.modelData.todo)
                    onMoveRequested: function(anchor) { screen.menuTodo = slot.modelData.todo; moveMenu.anchorItem = anchor; moveMenu.open = true }
                    onDueRequested: function(anchor) { screen.menuTodo = slot.modelData.todo; dueMenu.anchorItem = anchor; dueMenu.open = true }
                  }
                }
                Component {
                  id: headingComponent
                  // A list's name in All, or a day in Upcoming, lined up with
                  // the circles and the words under it.
                  Item {
                    width: slot.width
                    height: slot.index === 0 ? 30 : 44
                    Dot { visible: Boolean(slot.modelData.dot); list: slot.modelData.list || ""; x: 20; anchors.bottom: parent.bottom; anchors.bottomMargin: 11 }
                    Row {
                      x: 48
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: 6
                      spacing: 8
                      UiText { text: slot.modelData.label; weight: Font.DemiBold }
                      UiText { visible: slot.modelData.count > 0; text: String(slot.modelData.count || ""); muted: true }
                      UiText { visible: Boolean(slot.modelData.detail) && slot.modelData.detail !== slot.modelData.label; text: slot.modelData.detail || ""; muted: true }
                    }
                  }
                }
                Component {
                  id: doneComponent
                  // Done: finished tasks, out of the way but one click from coming back.
                  Item {
                    width: slot.width
                    height: 48
                    Rectangle { width: parent.width; height: 1; color: Theme.divider; y: 6 }
                    Row {
                      x: 14
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.verticalCenterOffset: 3
                      spacing: 8
                      Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "down"; size: 12; color: Theme.secondary
                        rotation: screen.doneShown ? 0 : -90
                        Behavior on rotation { NumberAnimation { duration: 120 } }
                      }
                      UiText { anchors.verticalCenter: parent.verticalCenter; text: "Done"; weight: Font.DemiBold }
                      UiText { anchors.verticalCenter: parent.verticalCenter; text: String(slot.modelData.count); muted: true; visible: slot.modelData.count > 0 }
                    }
                    MouseArea {
                      width: 140; height: parent.height
                      cursorShape: Qt.PointingHandCursor
                      onClicked: screen.doneShown = !screen.doneShown
                      Accessible.role: Accessible.Button
                      Accessible.name: screen.doneShown ? "Hide done" : "Show done"
                    }
                    Pill {
                      anchors.right: parent.right
                      anchors.rightMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.verticalCenterOffset: 3
                      visible: slot.modelData.count > 0 && !(screen.pending && screen.pending.kind === "clear")
                      kind: "link"
                      text: "Clear done"
                      size: 13
                      hint: "Take the done to-dos out of the list. Undo brings them back."
                      onClicked: screen.clearDone()
                    }
                  }
                }
                Component {
                  id: undoComponent
                  UndoBar { width: slot.width; label: slot.modelData.label }
                }
                Component {
                  id: emptyComponent
                  // Nothing here: say so, and how more get here.
                  // Padding, not x: the Loader sizes this to the full width.
                  Column {
                    width: slot.width
                    leftPadding: 48
                    rightPadding: 16
                    topPadding: 14
                    bottomPadding: 18
                    spacing: 8
                    BookText {
                      width: parent.width - 64
                      text: screen.emptyTitle
                      color: screen.loadError ? Theme.redText : Theme.secondary
                      font.italic: true
                      size: 22
                    }
                    UiText {
                      visible: text.length > 0
                      width: parent.width - 64
                      wrapMode: Text.Wrap
                      muted: true
                      text: screen.emptyBody
                    }
                  }
                }
              }
            }
          }
        }

        JournalComposer {
          id: composer
          todo: true
          anchors.bottom: parent.bottom
          width: parent.width
          app: screen.app
          todoTarget: ({ list: screen.targetList, due: screen.targetDue })
          placeholder: screen.hasLists
            ? "or type a to-do for " + (screen.targetList || "Inbox") + (screen.targetDue ? ", due today" : "")
            : "or type a to-do"
          // From any app, the shortcut adds to the current list; say which
          // when it is not the one on screen.
          hintText: !screen.hasLists || !screen.app.todoShortcut ? ""
            : screen.view === "list" && screen.viewList === screen.app.todoList ? screen.app.todoShortcut + " adds here from any app"
            : screen.app.todoShortcut + " adds to " + (screen.app.todoList || "Inbox") + " from any app"
          onTyped: function(text) { screen.addTyped(text) }
        }

        Toast {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 84
          message: screen.toast
          error: screen.toastError
          actionText: screen.toastAction
          onAction: screen.undo()
        }
      }
    }
  }

  // While a to-do is being edited, pressing anywhere else keeps what you
  // typed, as most lists do, and the press still reaches what you pressed.
  MouseArea {
    anchors.fill: parent
    z: 80
    enabled: screen.editingIndex >= 0
    onPressed: function(mouse) {
      var field = screen.Window.activeFocusItem
      if (!field || !field.contains(mapToItem(field, mouse.x, mouse.y))) screen.focusKeys()
      mouse.accepted = false
    }
  }

  PopupMenu {
    id: moreMenu
    anchorItem: moreButton
    items: [
      { label: "New list", action: "new" },
      { label: "Open the folder", action: "folder" },
      { label: "Change folder", action: "settings" }
    ]
    onPicked: function(action) {
      if (action === "new") screen.makingList = true
      else if (action === "settings") folderSheet.open = true
      else screen.app.openExternally(screen.app.todoSettings.folder_path || screen.app.todoSettings.folder)
    }
  }

  // Move to: every other list.
  PopupMenu {
    id: moveMenu
    panelWidth: 200
    items: !screen.menuTodo ? [] : [{ label: "Inbox", action: "list:", dot: "" }]
      .concat(screen.lists.map(function(l) { return { label: l, action: "list:" + l, dot: Theme.listColor(l) } }))
      .filter(function(item) { return item.action !== "list:" + screen.menuTodo.list })
    onPicked: function(action) { if (screen.menuTodo) screen.moveTo(screen.menuTodo, action.slice(5)) }
  }

  // When it is due: this week by name, next Monday, any day and time, or
  // no date.
  PopupMenu {
    id: dueMenu
    panelWidth: 210
    items: !screen.menuTodo ? [] : Dates.dueChoices(screen.today)
      .map(function(c) { return { label: c.label, detail: c.detail, action: "due:" + c.value, checked: c.value === screen.menuTodo.due } })
      .concat([{ label: "Pick a date and time…", action: "pick" }])
      .concat(screen.menuTodo.due ? [{ label: "No date", action: "due:" }] : [])
    onPicked: function(action) {
      if (!screen.menuTodo) return
      if (action === "pick") {
        duePicker.anchorItem = dueMenu.anchorItem
        duePicker.date = String(screen.menuTodo.due || "")
        duePicker.time = String(screen.menuTodo.time || "")
        duePicker.open = true
      } else screen.setDue(screen.menuTodo, action.slice(4))
    }
  }

  DuePicker {
    id: duePicker
    today: screen.today
    onPicked: function(date, time) { if (screen.menuTodo) screen.setDue(screen.menuTodo, date, time) }
  }

  // A list's own menu, from right-clicking it in the rail.
  PopupMenu {
    id: listMenu
    property string list: ""
    align: "left"
    panelWidth: 230
    readonly property int count: screen.todos.filter(function(t) { return t.list === listMenu.list }).length
    items: [
      { label: "Rename", action: "rename" },
      { label: "Delete list", action: "delete", danger: true,
        detail: count === 0 ? "It's empty" : count === 1 ? "Its to-do moves to the Inbox" : "Its " + count + " to-dos move to the Inbox" }
    ]
    onPicked: function(action) {
      if (action === "rename") screen.renaming = listMenu.list
      else screen.deleteList(listMenu.list)
    }
  }

  Sheet {
    id: folderSheet
    panelWidth: 480
    onClosed: open = false
    Column {
      width: parent.width
      spacing: 12
      UiText { text: "To-do folder"; font.pixelSize: 20; weight: Font.Bold }
      Field {
        id: folder
        width: parent.width
        label: "Folder"
        mono: true
        text: String(screen.app.todoSettings.folder || "")
        hint: "To-dos.md lives here. Moving to a new folder starts a new list; move the file yourself to keep this one."
        problem: /^[~\/]/.test(text.trim()) ? "" : "Use a full path, such as ~/Documents/To-dos."
        onAccepted: if (problem.length === 0) save()
        function save() { screen.app.todoSetting("folder", text.trim()); folderSheet.open = false }
      }
      Row {
        spacing: 8
        Pill { kind: "fill"; text: "Cancel"; size: 13; onClicked: folderSheet.open = false }
        Pill {
          kind: "primary"; text: "Use this folder"; size: 13
          enabled: folder.problem.length === 0 && folder.text.trim().length > 0
          onClicked: folder.save()
        }
      }
    }
  }
}
