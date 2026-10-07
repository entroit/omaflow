import QtCore
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
  // Open to-dos whose reminder has gone off, by index: they wait in
  // Today's Bubbled up until Done or Later.
  property var reminded: []
  // How long before a to-do's time it reminds you, as the list was read with.
  property int remindBefore: Number(app.todoSettings.remind_before || 0)
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
  // Done starts folded away, and stays as you leave it, across restarts too.
  property bool doneShown: false
  // How you left the page, beside OmaFlow's other state rather than in your
  // config, where it would be a setting nobody chose.
  property url stateFile: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/omaflow/ui.ini"
  Settings {
    location: screen.stateFile
    category: "todos"
    property alias doneShown: screen.doneShown
  }
  property string toast: ""
  property bool toastError: false
  property string toastAction: ""
  // A to-do just ticked out of sight, which Undo in the toast unticks.
  property var ticked: null
  // Tasks just ticked, kept in place while the line is drawn through them.
  property var settling: []
  // Tasks deleted or cleared, shown greyed out in place for the ten seconds
  // they can come back: { kind: "delete" | "clear", items, view, slot }.
  property var pending: null
  // A list just deleted, which Undo in the toast brings back.
  property string deletedList: ""
  property bool makingList: false
  property string renaming: ""
  // Why the last new list or rename did not happen, under its name field
  // until it does.
  property string listError: ""
  property bool listSaving: false
  // The to-do a row, When, reminder or Later menu is open for.
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
  function isReminded(todo) { return reminded.indexOf(todo.index) >= 0 }
  readonly property int todayCount: todos.filter(function(t) { return !t.done && (t.due && t.due <= today || isReminded(t)) }).length
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
  readonly property string nowMoment: today + " " + nowClock

  // A to-do deleted here that Undo can still bring back: the page is not
  // empty while it waits in its place.
  readonly property bool deleting: Boolean(pending) && pending.kind === "delete" && pending.view === viewKey
  // What the page shows, top to bottom: to-dos, the headings between them,
  // the Done group, the Undo bars, or what to say when there is nothing.
  readonly property var rows: {
    var out = []
    // Nothing yet, rather than a moment of "Nothing to do" before the list is read.
    if (!loaded) return out
    var row = function(todo, showList) { return { kind: "row", todo: todo, ghost: false, showList: showList } }
    var cross = hasLists
    if (view === "list") {
      todos.filter(function(t) { return t.list === viewList && isOpen(t) })
        .forEach(function(t) { out.push(row(t, false)) })
      if (out.length === 0 && !listening && !deleting) out.push({ kind: "empty" })
      var done = todos.filter(function(t) { return t.list === viewList && t.done && !isSettling(t) })
      var clearing = pending && pending.kind === "clear" && pending.view === viewKey
      if (done.length > 0 || clearing) {
        out.push({ kind: "done", count: done.length })
        if (doneShown) {
          done.forEach(function(t) { out.push(row(t, false)) })
          if (clearing) pending.items.forEach(function(t) { out.push({ kind: "row", todo: t, ghost: true, showList: false }) })
        }
        // Undo shows even with Done folded away.
        if (clearing) out.push({ kind: "undo", label: pending.items.length === 1 ? "1 done to-do cleared" : pending.items.length + " done to-dos cleared" })
      }
    } else if (view === "today") {
      // What has reminded you comes first, the latest on top, and waits there
      // until Done or Later.
      var bubbled = todos.filter(function(t) { return isOpen(t) && isReminded(t) }).sort(function(a, b) {
        var x = Dates.reminderOf(a, remindBefore), y = Dates.reminderOf(b, remindBefore)
        return x > y ? -1 : x < y ? 1 : a.index - b.index
      })
      if (bubbled.length > 0) out.push({ kind: "bubbled", items: bubbled })
      todos.filter(function(t) { return isOpen(t) && t.due && t.due <= today && !isReminded(t) })
        .map(function(t) { return row(t, cross) }).sort(byDue)
        .forEach(function(r) { out.push(r) })
      if (out.length === 0 && !listening && !deleting) out.push({ kind: "empty" })
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
      if (out.length === 0 && !deleting) out.push({ kind: "empty" })
    } else if (view === "all") {
      [""].concat(lists).forEach(function(list) {
        var items = todos.filter(function(t) { return t.list === list && isOpen(t) })
        if (items.length === 0) return
        out.push({ kind: "heading", label: list || "Inbox", list: list, dot: true, count: items.length })
        items.forEach(function(t) { out.push(row(t, false)) })
      })
      if (out.length === 0 && !deleting) out.push({ kind: "empty" })
    } else if (view === "done") {
      todos.filter(function(t) { return t.done && !isSettling(t) })
        .forEach(function(t) { out.push(row(t, cross)) })
      if (pending && pending.kind === "clear" && pending.view === viewKey) {
        pending.items.forEach(function(t) { out.push({ kind: "row", todo: t, ghost: true, showList: cross }) })
        out.push({ kind: "undo", label: pending.items.length === 1 ? "1 done to-do cleared" : pending.items.length + " done to-dos cleared" })
      } else if (out.length === 0 && !deleting) out.push({ kind: "empty" })
    }
    if (deleting) {
      var at = Math.min(pending.slot, out.length)
      out.splice(at, 0, { kind: "row", todo: pending.items[0], ghost: true, showList: view !== "list" && view !== "all" && cross },
                 { kind: "undo", label: "Deleted" })
    }
    return out
  }
  // What the arrow keys move over: the live to-dos, as shown.
  readonly property var navigable: {
    var out = []
    rows.forEach(function(r) {
      if (r.kind === "bubbled") out = out.concat(r.items)
      else if (r.kind === "row" && !r.ghost) out.push(r.todo)
    })
    return out
  }

  readonly property string title: !loaded ? "" : view === "today" ? "Today" : view === "upcoming" ? "Upcoming"
    : view === "all" ? "All" : view === "done" ? "Done" : viewList || "Inbox"
  readonly property int openLists: [""].concat(lists).filter(function(l) { return openIn(l) > 0 }).length
  readonly property string subtitle: view === "today" ? Dates.long(today, today)
    : view === "all" && openCount > 0 ? openCount + " open in " + openLists + (openLists === 1 ? " list" : " lists")
    : ""
  readonly property string emptyTitle: loadError ? "To-dos.md could not be read."
    : view === "today" ? "Nothing due today."
    : view === "upcoming" ? "Nothing coming up."
    : view === "all" ? "Nothing to do."
    : view === "done" ? "Nothing done yet."
    : todos.some(function(t) { return t.list === viewList && t.done }) ? (viewList ? "All done in " + viewList + "." : "All done.")
    : "Nothing to do yet."
  readonly property string emptyBody: {
    // A missing file reads as an empty list, so a failure is about reading it.
    if (loadError) return "Check that you can read the file, or choose another folder under \u22ef, Reminders and folder."
    // No to-do shortcut yet, which is how it starts: say there is one to set.
    var anyApp = app.todoShortcut ? "" : " To add from any app, set a to-do shortcut in Settings, Hotkeys."
    if (view === "today") {
      var next = todos.filter(function(t) { return !t.done && t.due && t.due > today }).sort(function(a, b) { return a.due < b.due ? -1 : 1 })[0]
      if (next) return "Next: " + next.text + ", " + Dates.due(next.due, today)
      // The very first visit: how to-dos get here at all.
      if (todos.length === 0)
        return (app.todoShortcut ? "Hold " + app.todoShortcut + " in any app and say what you need to do. " : "")
          + "Talk or type below and it's due today. Say several things at once and each gets its own line." + anyApp
      return "Talk or type below and it's due today."
    }
    if (view === "upcoming") return "To-dos with a date after today show here, by day. Say \u201cby Friday\u201d and it gets one."
    if (view === "all" || view === "done") return ""
    var how = app.todoShortcut && (viewList === app.todoList || !hasLists)
      ? "Hold " + app.todoShortcut + " in any app and say what you need to do. Each to-do gets its own line."
      : "Talk or type below. Say several things at once and each gets its own line." + anyApp
    return hasLists ? how : how + " To keep work and errands apart, make a list for each with New list on the left."
  }

  function reload() {
    if (!app) return
    today = app.todayIso()
    app.query(["todos", "list"], function(value, error) {
      if (value) {
        todos = value.todos || []
        lists = value.lists || []
        reminded = value.reminded || []
        if (value.remind_before !== undefined) remindBefore = Number(value.remind_before)
        filePath = String(value.path || "")
        if (value.today) today = String(value.today)
        loadError = ""
        // Opening the tab starts on Today, or where it was asked to, such as
        // Upcoming from a reminder.
        if (!opened) {
          opened = true
          if (startView) { place(startView); startView = "" }
          // Today first, as Todoist and Microsoft To Do open: what is late or
          // due is the answer. New to-dos still go to the current list.
          else { view = "today"; viewList = "" }
        }
        if (view === "list" && viewList && lists.indexOf(viewList) < 0) viewList = ""
      } else {
        // Not the rows from before: they may no longer be what the file says.
        loadError = error
        todos = []
        lists = []
        reminded = []
      }
      loaded = true
      cursor = Math.min(cursor, navigable.length - 1)
    })
  }
  // A view to open on before the list has loaded, or now if it has:
  // "today", "upcoming", "all", "done", or "list:NAME", "list:" being the
  // Inbox. A list that is gone opens the Inbox.
  property string startView: ""
  function openOn(nextView) {
    if (opened) place(nextView)
    else startView = nextView
  }
  function place(key) {
    key = String(key || "")
    if (key.indexOf("list:") === 0) select("list", lists.indexOf(key.slice(5)) >= 0 ? key.slice(5) : "")
    else if (["today", "upcoming", "all", "done"].indexOf(key) >= 0) select(key, "")
  }
  function select(nextView, list) {
    view = nextView
    viewList = list || ""
    editingIndex = -1
    cursor = -1
    // From the top, where Today keeps what has reminded you.
    list.contentY = 0
    screen.focusKeys()
  }
  function flash(message, error, action) {
    toast = message
    toastError = Boolean(error)
    toastAction = action || ""
    ticked = null
    toastTimer.interval = action ? 10000 : 3200
    toastTimer.restart()
  }
  // TODO, when given, is the one to-do the write was about.
  function afterWrite(value, error, todo) {
    if (error) flash(writeError(error, todo), true)
    reload()
  }
  function wrote(todo) { return function(value, error) { afterWrite(value, error, todo) } }
  // The daemon's reason as a sentence. A to-do or list changed in the file
  // since the page read it: the page reads it again, so say to try again,
  // naming the to-do when it was one.
  function writeError(error, todo) {
    var text = String(error).trim()
    var changed = / (is|are) no longer in the (list|file)$/
    if (changed.test(text) && todo && / to-dos? /.test(text)) return "\u201c" + todo.text + "\u201d changed in To-dos.md. The page is up to date now, so try again."
    if (changed.test(text)) return text.replace(changed, " changed in To-dos.md") + ". The page is up to date now, so try again."
    text = text.charAt(0).toUpperCase() + text.slice(1)
    return /[.!?]$/.test(text) ? text : text + "."
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
      // Out of sight once the line is drawn: say so, with the way back.
      if (view !== "list" || !doneShown) {
        flash("Done: " + (edited || todo.text), false, "Undo")
        ticked = { index: todo.index, text: edited || todo.text }
      }
    }
    if (edited) {
      app.query(["todos", "edit", todo.index, todo.text, edited], function(value, error) {
        if (error) afterWrite(value, error, todo)
        else app.query(["todos", "done", todo.index, edited], wrote({ text: edited }))
      })
    } else app.query(["todos", todo.done ? "undone" : "done", todo.index, todo.text], wrote(todo))
  }
  function saveEdit(todo, text) {
    editingIndex = -1
    app.query(["todos", "edit", todo.index, todo.text, text], wrote(todo))
    screen.focusKeys()
  }
  // A new day keeps the to-do's time unless one is given; no date drops both.
  // REMIND is "default", "off" or minutes before; left out, a reminder set
  // by hand moves with the time.
  // Moved out of sight by its new date, it says where it went, as Move does.
  function setDue(todo, due, time, remind) {
    var at = time === undefined ? String(todo.time || "") : time
    app.query(["todos", "due", todo.index, todo.text, due, due ? at : ""].concat(due && at && remind ? [remind] : []), function(value, error) {
      if (!error && !inView(Object.assign({}, todo, { due: due || null }))) {
        var day = due ? Dates.due(due, today) : ""
        if (["Today", "Tomorrow", "Yesterday"].indexOf(day) >= 0) day = day.toLowerCase()
        flash(due ? "Due " + day + (at ? " at " + at : "") : "No date now. It's in " + (todo.list || "the Inbox") + ".", false)
      }
      afterWrite(value, error, todo)
    })
  }
  // One reminder for one to-do: CHOICE is minutes before its time, or "off".
  // The default's own offset keeps following the default, unless the
  // reminder was already set by hand.
  function setReminder(todo, choice) {
    var value = choice === "off" ? "off" : !todo.reminder && Number(choice) === remindBefore ? "default" : String(choice)
    app.query(["todos", "remind", todo.index, todo.text, value], wrote(todo))
  }
  // Later, from Bubbled up: remind again at MOMENT, "YYYY-MM-DD HH:MM", as
  // the minutes from now to it.
  function remindAgainAt(todo, moment) {
    var minutes = Math.max(1, Dates.minutesBetween(nowMoment, moment))
    app.query(["todos", "snooze", todo.index, todo.text, minutes], function(value, error) {
      if (!error) {
        var day = String(value.until).slice(0, 10)
        flash("Reminds you again " + (day === today ? "" : Dates.due(day, today).replace(/^Tomorrow$/, "tomorrow") + " ")
          + "at " + String(value.until).slice(11), false)
      }
      afterWrite(value, error, todo)
    })
  }
  function moveTo(todo, list) {
    app.query(["todos", "move", todo.index, todo.text, list], function(value, error) {
      if (!error) flash("Moved to " + (list || "Inbox"), false)
      afterWrite(value, error, todo)
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
      afterWrite(value, error, todo)
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
  // Undo in the toast: untick what was just ticked, or bring back the last
  // delete.
  function undoToast() {
    if (!ticked) return undo()
    var todo = ticked
    ticked = null
    toast = ""
    app.query(["todos", "undone", todo.index, todo.text], wrote(todo))
  }
  // Ctrl+Z: the last tick while its toast shows, else the last delete.
  function undoLast() {
    if (ticked && toast) undoToast()
    else undo()
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
  // Whether a to-do shows where you are.
  function inView(todo) {
    return view === "list" ? todo.list === viewList
      : view === "today" ? Boolean(todo.due) && todo.due <= today
      : view === "upcoming" ? Boolean(todo.due) && todo.due > today
      : view === "all"
  }
  function addTyped(text) {
    var list = targetList
    app.query(["todos", "add", text, list, targetDue], function(value, error) {
      if (!error) {
        composer.clearInput()
        // Adding to a list makes it the current one.
        if (hasLists && list !== app.todoList) app.todoSetList(list)
        // Added somewhere this view does not show: say where.
        var hidden = (value && value.added || []).filter(function(t) { return !inView(t) })
        if (hidden.length === 1) {
          var day = hidden[0].due ? Dates.due(hidden[0].due, today) : ""
          if (["Today", "Tomorrow", "Yesterday"].indexOf(day) >= 0) day = day.toLowerCase()
          flash("Added to " + (hidden[0].list || "Inbox") + (day ? ", due " + day : ""), false)
        } else if (hidden.length > 1) flash("Added " + hidden.length + " to-dos to " + (list || "Inbox"), false)
      }
      afterWrite(value, error)
    })
  }
  // A failed new list or rename keeps its field open, with why under it.
  // One that failed after you clicked away closes instead, and says why.
  function createList(name, left) {
    name = String(name || "").trim()
    if (!name) { makingList = false; listError = ""; return }
    if (listSaving) return
    listSaving = true
    app.query(["todos", "new-list", name], function(value, error) {
      listSaving = false
      if (value && !error) {
        makingList = false
        listError = ""
        select("list", value.list)
        reload()
      } else if (left) {
        makingList = false
        flash(writeError(error || "The list was not made"), true)
      } else listError = writeError(error || "The list was not made")
    })
  }
  function renameList(name, newName, left) {
    newName = String(newName || "").trim()
    if (!newName || newName === name) { renaming = ""; listError = ""; return }
    if (listSaving) return
    listSaving = true
    app.query(["todos", "rename-list", name, newName], function(value, error) {
      listSaving = false
      if (!(value && !error) && left) {
        renaming = ""
        flash(writeError(error || "The list was not renamed"), true)
      } else if (value && !error) {
        renaming = ""
        listError = ""
        var renamed = String(value.list || newName)
        if (viewList === name) viewList = renamed
        if (app.todoList === name) app.todoSetList(renamed)
        reload()
      } else listError = writeError(error || "The list was not renamed")
    })
  }
  // What deleting a list moves to the Inbox: "2 open and 1 done to-dos".
  function listContents(name) {
    var open = openIn(name)
    var done = todos.filter(function(t) { return t.list === name && t.done }).length
    var noun = open + done === 1 ? " to-do" : " to-dos"
    return open > 0 && done > 0 ? open + " open and " + done + " done" + noun
      : open > 0 ? open + " open" + noun
      : done > 0 ? done + " done" + noun
      : ""
  }
  function deleteList(name) {
    var contents = listContents(name)
    var count = todos.filter(function(t) { return t.list === name }).length
    app.query(["todos", "delete-list", name], function(value, error) {
      if (!error) {
        if (viewList === name) select("list", "")
        if (app.todoList === name) app.todoSetList("")
        pending = null
        deletedList = name
        deleteTimer.restart()
        flash(name + " deleted." + (contents ? " Its " + contents + (count === 1 ? " is" : " are") + " in the Inbox." : ""), false, "Undo")
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

  // The keys that work the to-do the keyboard is on, said under the field.
  readonly property string cursorKeys: {
    var todo = cursor >= 0 && cursor < navigable.length ? navigable[cursor] : null
    if (!todo) return ""
    if (view === "today" && isReminded(todo)) return "Space for Done, L for later"
    return "Space to tick, D for when" + (todo.due && todo.time ? ", R for reminder" : "") + (hasLists ? ", M to move" : "")
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
  onMakingListChanged: listError = ""
  onRenamingChanged: listError = ""
  Component.onCompleted: if (active) reload()

  Connections {
    target: screen.app
    // A capture landed in the list, or Undo took it out. Never reload under
    // an edit you are making.
    function onTodosRevisionChanged() { if (screen.active && screen.editingIndex < 0) screen.reload() }
    // Another folder, or the same to-dos moved there: read the file again.
    function onTodoSettingsChanged() { if (screen.active && screen.editingIndex < 0) screen.reload() }
  }
  Timer { id: toastTimer; interval: 3200; onTriggered: { screen.toast = ""; screen.toastAction = ""; screen.ticked = null } }
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

  // Folding Done from the keyboard redraws the rows; the keyboard stays on
  // the fold.
  function toggleDone() {
    doneShown = !doneShown
    Qt.callLater(function() {
      for (var i = 0; i < rowRepeater.count; i++) {
        var slot = rowRepeater.itemAt(i)
        if (slot && slot.item && slot.modelData.kind === "done") slot.item.focusFold()
      }
    })
  }

  // The row the cursor is on, for menus that open under its buttons.
  function cursorRow() {
    var todo = cursor >= 0 && cursor < navigable.length ? navigable[cursor] : null
    if (!todo) return null
    for (var i = 0; i < rowRepeater.count; i++) {
      var slot = rowRepeater.itemAt(i)
      if (slot && slot.item && slot.modelData.kind === "row" && !slot.modelData.ghost && slot.modelData.todo.index === todo.index) return slot.item
      if (slot && slot.item && slot.modelData.kind === "bubbled" && slot.item.rowFor(todo.index)) return slot.item.rowFor(todo.index)
    }
    return null
  }

  // A row's menus, each under the part of the row it belongs to.
  function openMenu(menu, todo, anchor) {
    menuTodo = todo
    menu.anchorItem = anchor
    menu.open = true
  }

  Keys.onPressed: function(event) {
    var todo = cursor >= 0 && cursor < navigable.length ? navigable[cursor] : null
    var row = todo ? cursorRow() : null
    if ((ticked && toast || pending || deletedList) && event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) undoLast()
    else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) moveCursor(1)
    else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) moveCursor(-1)
    else if (event.key === Qt.Key_BracketRight) step(1)
    else if (event.key === Qt.Key_BracketLeft) step(-1)
    else if (todo && (event.key === Qt.Key_Space || event.key === Qt.Key_X)) toggle(todo)
    else if (todo && !todo.done && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_F2)) startEdit(todo)
    else if (todo && event.key === Qt.Key_Delete) remove(todo)
    // The row's own menus: D when, M Move, R its reminder, L or S Later once
    // it has reminded you, and the menu key the one under ⋯.
    else if (row && !todo.done && event.key === Qt.Key_D) openMenu(whenMenu, todo, row.dueAnchor)
    else if (row && !todo.done && hasLists && event.key === Qt.Key_M) openMenu(rowMenu, todo, row.menuAnchor)
    else if (row && !todo.done && todo.due && todo.time && event.key === Qt.Key_R) openMenu(reminderMenu, todo, row.reminderAnchor)
    else if (row && row.bubbled && (event.key === Qt.Key_L || event.key === Qt.Key_S)) openMenu(laterMenu, todo, row.laterAnchor)
    else if (row && (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier)))) openMenu(rowMenu, todo, row.menuAnchor)
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
      Keycap { anchors.verticalCenter: parent.verticalCenter; compact: true; text: "Ctrl+Z" }
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

  // A to-do on the page, wired to the page's menus and writes.
  component Todo: TodoRow {
    // Found by this name in tests and previews, as the type is Todo here.
    objectName: "TodoRow"
    // Upcoming says the day above; the row need not repeat it.
    showDue: screen.view !== "upcoming"
    today: screen.today
    now: screen.nowClock
    settling: !ghost && screen.isSettling(todo)
    editing: !ghost && !todo.done && screen.editingIndex === todo.index
    draft: editing ? screen.editDraft : ""
    onDraftEdited: function(text) { screen.editDraft = text }
    current: !ghost && screen.cursor >= 0 && screen.cursor < screen.navigable.length
      && screen.navigable[screen.cursor].index === todo.index
    onToggled: screen.toggle(todo)
    onEditRequested: screen.startEdit(todo)
    onCancelRequested: { screen.editingIndex = -1; screen.focusKeys() }
    onSaveRequested: function(text) { screen.saveEdit(todo, text) }
    onDueRequested: function(anchor) { screen.openMenu(whenMenu, todo, anchor) }
    onMenuRequested: function(anchor) { screen.openMenu(rowMenu, todo, anchor) }
    onReminderRequested: function(anchor) { screen.openMenu(reminderMenu, todo, anchor) }
    onLaterRequested: function(anchor) { screen.openMenu(laterMenu, todo, anchor) }
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
    // How many of the count are late, said as well as shown in red.
    property int late: 0
    // A list has Rename and Delete: under ⋯ on hover, or a right-click.
    property bool hasMenu: false
    readonly property bool showMore: hasMenu && (placeMouse.containsMouse || moreArea.containsMouse)
    signal picked()
    signal menuRequested()
    width: parent ? parent.width : 0
    height: 34
    radius: 9
    color: selected ? Theme.fill8 : placeMouse.containsMouse || moreArea.containsMouse ? Theme.hover : "transparent"
    // Tab reaches every place; Enter or Space opens it, the menu key or
    // Shift F10 a list's menu.
    activeFocusOnTab: true
    border.width: activeFocus ? 1.5 : 0
    border.color: Theme.accent
    Keys.onReturnPressed: place.picked()
    Keys.onEnterPressed: place.picked()
    Keys.onSpacePressed: place.picked()
    Keys.onPressed: function(event) {
      if (place.hasMenu && (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier)))) {
        place.menuRequested()
        event.accepted = true
      }
    }
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
      color: place.late > 0 ? Theme.redText : place.selected ? Theme.text : Theme.secondary
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
    Accessible.name: place.label + (place.count > 0 ? ", " + place.count : "") + (place.late > 0 ? ", " + place.late + " late" : "")
  }

  // A list name being typed: a new list, or a rename, with why it failed
  // under it until it works.
  component NameField: Item {
    id: nameField
    property string list: ""
    property alias text: nameInput.text
    // LEFT: the field lost the keyboard, rather than Enter.
    signal done(string text, bool left)
    signal cancelled()
    width: parent ? parent.width : 0
    height: screen.listError ? 34 + errorText.implicitHeight + 10 : 34
    UiText {
      id: errorText
      visible: screen.listError.length > 0
      x: 12; y: 40
      width: parent.width - 20
      wrapMode: Text.Wrap
      font.pixelSize: 12
      color: Theme.redText
      text: screen.listError
    }
    Rectangle {
      width: parent.width
      height: 34
      radius: 9
      color: Theme.fill4
      border.width: 1.5
      border.color: screen.listError ? Theme.red : Theme.accent
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
        // As the list file allows.
        maximumLength: 40
        placeholderTextColor: Theme.secondary
        Component.onCompleted: { forceActiveFocus(); selectAll() }
        onAccepted: nameField.done(text, false)
        Keys.onEscapePressed: { screen.listError = ""; nameField.cancelled() }
        // Clicking away after an error keeps the old name, as Esc does.
        onActiveFocusChanged: if (!activeFocus && visible) {
          if (screen.listError) { screen.listError = ""; nameField.cancelled() }
          else nameField.done(text, true)
        }
        Accessible.name: "List name"
        Accessible.description: screen.listError
      }
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
          Place { label: "Today"; count: screen.todayCount; late: screen.todos.filter(function(t) { return !t.done && t.due && t.due < screen.today }).length; selected: screen.view === "today"; onPicked: screen.select("today", "") }
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
              height: renameField.item ? renameField.item.height : 34
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
                id: renameField
                width: parent.width
                active: screen.renaming === listSlot.modelData
                sourceComponent: NameField {
                  text: listSlot.modelData
                  onDone: function(text, left) { screen.renameList(listSlot.modelData, text, left) }
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
              onDone: function(text, left) { screen.createList(text, left) }
              onCancelled: screen.makingList = false
            }
          }
          Rectangle {
            visible: !screen.makingList
            width: parent.width
            height: 34
            radius: 9
            color: newMouse.containsMouse ? Theme.hover : "transparent"
            activeFocusOnTab: true
            border.width: activeFocus ? 1.5 : 0
            border.color: Theme.accent
            Keys.onReturnPressed: screen.makingList = true
            Keys.onEnterPressed: screen.makingList = true
            Keys.onSpacePressed: screen.makingList = true
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
              id: fileChip
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
                // No folder icon: the chip opens the file; ⋯ opens the folder.
                UiText { anchors.verticalCenter: parent.verticalCenter; text: "To-dos.md"; font.family: Theme.mono; font.pixelSize: 11; muted: true }
              }
              MouseArea { id: fileMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: screen.app.openInEditor(screen.filePath) }
              activeFocusOnTab: visible
              // The keyboard ring, outside the shape like a Pill's.
              Rectangle { anchors.fill: parent; anchors.margins: -3; radius: height / 2; color: "transparent"; border.width: 2; border.color: Theme.accent; visible: fileChip.activeFocus }
              Keys.onReturnPressed: screen.app.openInEditor(screen.filePath)
              Keys.onEnterPressed: screen.app.openInEditor(screen.filePath)
              Keys.onSpacePressed: screen.app.openInEditor(screen.filePath)
              Accessible.role: Accessible.Button
              Accessible.name: "Open To-dos.md in your editor"
            }
            Rectangle {
              id: moreButton
              width: 30; height: 30; radius: 15
              color: moreMouse.containsMouse || moreMenu.open ? Theme.fill8 : "transparent"
              activeFocusOnTab: true
              border.width: activeFocus ? 1.5 : 1
              border.color: activeFocus ? Theme.accent : Theme.divider
              Keys.onReturnPressed: moreMenu.open = true
              Keys.onEnterPressed: moreMenu.open = true
              Keys.onSpacePressed: moreMenu.open = true
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
              id: rowRepeater
              model: screen.rows
              delegate: Loader {
                id: slot
                required property var modelData
                required property int index
                width: body.width
                sourceComponent: modelData.kind === "row" ? rowComponent
                  : modelData.kind === "bubbled" ? bubbledComponent
                  : modelData.kind === "heading" ? headingComponent
                  : modelData.kind === "done" ? doneComponent
                  : modelData.kind === "undo" ? undoComponent
                  : emptyComponent

                Component {
                  id: rowComponent
                  Todo { width: slot.width; todo: slot.modelData.todo; ghost: slot.modelData.ghost; showList: slot.modelData.showList }
                }
                Component {
                  id: bubbledComponent
                  // Bubbled up: what has reminded you, in a group of its own
                  // at the top of Today until Done or Later.
                  Item {
                    width: slot.width
                    height: group.height + 12
                    function rowFor(index) {
                      for (var i = 0; i < bubbledRows.count; i++) if (bubbledRows.itemAt(i).todo.index === index) return bubbledRows.itemAt(i)
                      return null
                    }
                    Rectangle {
                      id: group
                      width: parent.width
                      height: groupColumn.height + 6
                      radius: Theme.radiusPanel
                      color: Theme.fill4
                      border.width: 1
                      border.color: Theme.divider
                      Column {
                        id: groupColumn
                        width: parent.width
                        Row {
                          x: 16
                          height: 32
                          spacing: 8
                          Rectangle { anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: 3; width: 7; height: 7; radius: 3.5; color: Theme.accent }
                          UiText {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: 3
                            text: "Bubbled up"
                            font.pixelSize: 12
                            font.letterSpacing: 0.24
                            weight: Font.DemiBold
                            Accessible.role: Accessible.Heading
                          }
                        }
                        Repeater {
                          id: bubbledRows
                          model: slot.modelData.items
                          Todo {
                            required property var modelData
                            width: groupColumn.width
                            todo: modelData
                            bubbled: true
                            remindedAt: Dates.reminderOf(modelData, screen.remindBefore)
                          }
                        }
                      }
                    }
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
                    function focusFold() { fold.forceActiveFocus() }
                    Rectangle { width: parent.width; height: 1; color: Theme.divider; y: 6 }
                    Row {
                      id: doneHeader
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
                    Item {
                      id: fold
                      x: 4
                      y: 12
                      width: doneHeader.width + 20; height: parent.height - 18
                      activeFocusOnTab: true
                      Rectangle { anchors.fill: parent; radius: 9; color: "transparent"; border.width: 2; border.color: Theme.accent; visible: fold.activeFocus }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: screen.doneShown = !screen.doneShown
                      }
                      Keys.onReturnPressed: screen.toggleDone()
                      Keys.onEnterPressed: screen.toggleDone()
                      Keys.onSpacePressed: screen.toggleDone()
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
                    // What went wrong, word for word, for whoever fixes it.
                    UiText {
                      visible: screen.loadError.length > 0
                      width: parent.width - 64
                      wrapMode: Text.Wrap
                      font.family: Theme.mono
                      font.pixelSize: 11
                      muted: true
                      text: screen.loadError
                    }
                    // Once it is fixed, read the file again here.
                    Pill { visible: screen.loadError.length > 0; kind: "fill"; text: "Try again"; size: 13; onClicked: screen.reload() }
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
          // While you talk, where they go, as the field said before.
          listeningText: screen.hasLists ? "They go to " + (screen.targetList || "Inbox") + (screen.targetDue ? ", due today." : ".")
            : screen.targetDue ? "They're due today." : "Name one thing after another."
          addLabel: screen.hasLists ? "Add to " + (screen.targetList || "Inbox") : "Add"
          placeholder: (screen.hasLists ? "or type a to-do for " + (screen.targetList || "Inbox") : "or type a to-do")
            + (screen.targetDue ? ", due today" : "")
          // From any app, the shortcut adds to the current list; say which
          // when it is not the one on screen.
          // With the keyboard on a to-do, the keys that work it.
          hintText: screen.cursor >= 0 ? screen.cursorKeys
            : !screen.hasLists || !screen.app.todoShortcut ? ""
            : screen.view === "list" && screen.viewList === screen.app.todoList ? screen.app.todoShortcut + " adds here from any app"
            : screen.app.todoShortcut + " adds to " + (screen.app.todoList || "Inbox") + " from any app"
          onTyped: function(text) { screen.addTyped(text) }
          onUndoPressed: screen.undoLast()
        }

        Toast {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 84
          message: screen.toast
          error: screen.toastError
          actionText: screen.toastAction
          actionShortcut: screen.toastAction ? "Ctrl+Z" : ""
          onAction: screen.undoToast()
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
    name: "To-do options"
    // New list is not here: it is always in sight at the foot of the rail.
    items: [
      { label: "Open the folder", action: "folder" },
      { label: "Reminders and folder", action: "settings" }
    ]
    onPicked: function(action) {
      if (action === "settings") folderSheet.open = true
      else screen.app.openExternally(screen.app.todoSettings.folder_path || screen.app.todoSettings.folder)
    }
  }

  // The moments "when" can be, as menu choices for TODO: those that remind
  // you, the current one ticked, under HEADER.
  function momentItems(todo, header, timed) {
    var choices = Dates.moments(nowMoment, today).filter(function(m) { return Boolean(m.time) === timed })
    return [{ header: header }].concat(choices.map(function(m) {
      return { label: m.label, aside: Dates.momentAside(m, today), action: "at:" + m.date + " " + m.time,
               checked: todo.due === m.date && String(todo.time || "") === m.time }
    }))
  }
  // A timed to-do's reminder as one row of times: at the time, earlier,
  // or Off, the current one chosen. One set some other way, such as from
  // Later, shows as itself.
  function reminderItems(todo) {
    var at = todo.due + " " + todo.time
    var current = !todo.reminder ? remindBefore : todo.reminder === "off" ? "off" : Dates.minutesBetween(todo.reminder, at)
    var chips = Dates.remindChoices(at, todo.due).map(function(c) { return { label: c.ahead, name: c.said, means: c.means, action: "remind:" + c.minutes, checked: c.minutes === current } })
    if (current !== "off" && Dates.EARLIER.indexOf(current) < 0) {
      chips.unshift({ label: Dates.clockOn(todo.reminder, todo.due), means: "Reminds you at " + Dates.clockOn(todo.reminder, todo.due), action: "remind:keep", checked: true })
      // Room for six: 5 minutes before goes first.
      chips = chips.filter(function(c) { return c.action !== "remind:5" })
    }
    chips.push({ label: "Off", means: "No reminder", action: "remind:off", checked: current === "off", quiet: true })
    var title = "Reminder for " + todo.time
    return [{ header: title }, { name: title, chips: chips }]
  }
  function pickWhen(todo, action) {
    if (action === "pick") {
      duePicker.anchorItem = whenMenu.anchorItem
      duePicker.date = String(todo.due || "")
      duePicker.time = String(todo.time || "")
      duePicker.reminder = String(todo.reminder || "")
      duePicker.open = true
    } else if (action.indexOf("remind:") === 0) {
      if (action !== "remind:keep") setReminder(todo, action.slice(7))
    } else {
      // A moment comes with the default reminder; a day alone has no time.
      var parts = action.slice(3).split(" ")
      setDue(todo, parts[0], parts[1] || "", parts[1] ? "default" : undefined)
    }
  }

  // ⋯ on a row, or a right-click: Move to the other lists, Edit, Delete.
  PopupMenu {
    id: rowMenu
    panelWidth: 220
    name: screen.menuTodo ? (screen.menuTodo.done ? "Delete " : "Move, edit or delete ") + "\u201c" + screen.menuTodo.text + "\u201d" : ""
    items: !screen.menuTodo ? []
      : screen.menuTodo.done ? [{ label: "Delete", action: "delete", danger: true }]
      : (screen.hasLists ? [{ header: "Move to" }].concat([{ label: "Inbox", action: "list:", dot: "" }]
          .concat(screen.lists.map(function(l) { return { label: l, action: "list:" + l, dot: Theme.listColor(l) } }))
          .filter(function(item) { return item.action !== "list:" + screen.menuTodo.list }), [{ divider: true }]) : [])
        .concat([{ label: "Edit", action: "edit" }, { label: "Delete", action: "delete", danger: true }])
    onPicked: function(action) {
      var todo = screen.menuTodo
      if (!todo) return
      if (action === "edit") screen.startEdit(todo)
      else if (action === "delete") screen.remove(todo)
      else screen.moveTo(todo, action.slice(5))
    }
  }

  // When it is due, from the date on a row: a moment that reminds you, a
  // day alone, any day and time, or no date; for a to-do with a time, its
  // reminder too.
  PopupMenu {
    id: whenMenu
    panelWidth: 340
    name: screen.menuTodo ? "When \u201c" + screen.menuTodo.text + "\u201d is due" : ""
    items: !screen.menuTodo ? [] : screen.momentItems(screen.menuTodo, "Remind me", true)
      .concat([{ divider: true }], screen.momentItems(screen.menuTodo, "Just a day, no reminder", false))
      .concat([{ divider: true }, { label: "Pick a day and time\u2026", action: "pick" }])
      .concat(screen.menuTodo.due ? [{ label: "No date", action: "at:" }] : [])
      .concat(screen.menuTodo.due && screen.menuTodo.time ? [{ divider: true }].concat(screen.reminderItems(screen.menuTodo)) : [])
    onPicked: function(action) { if (screen.menuTodo) screen.pickWhen(screen.menuTodo, action) }
  }

  // The bell on a row, or R: the reminder alone.
  PopupMenu {
    id: reminderMenu
    panelWidth: 340
    name: screen.menuTodo ? "Remind me of \u201c" + screen.menuTodo.text + "\u201d" : ""
    items: screen.menuTodo && screen.menuTodo.due && screen.menuTodo.time ? screen.reminderItems(screen.menuTodo) : []
    onPicked: function(action) { if (screen.menuTodo) screen.pickWhen(screen.menuTodo, action) }
  }

  // Later, in Bubbled up: the same moments, to be reminded again at.
  PopupMenu {
    id: laterMenu
    panelWidth: 280
    name: screen.menuTodo ? "Remind me again about \u201c" + screen.menuTodo.text + "\u201d" : ""
    items: !screen.menuTodo ? [] : screen.momentItems(screen.menuTodo, "Remind me again", true)
      .map(function(item) { return Object.assign({}, item, { checked: undefined }) })
    onPicked: function(action) { if (screen.menuTodo) screen.remindAgainAt(screen.menuTodo, action.slice(3)) }
  }

  DuePicker {
    id: duePicker
    today: screen.today
    now: screen.nowMoment
    remindBefore: screen.remindBefore
    onPicked: function(date, time, remind) { if (screen.menuTodo) screen.setDue(screen.menuTodo, date, time, remind) }
  }

  // A list's own menu, from right-clicking it in the rail.
  PopupMenu {
    id: listMenu
    property string list: ""
    align: "left"
    panelWidth: 230
    name: listMenu.list
    readonly property int count: screen.todos.filter(function(t) { return t.list === listMenu.list }).length
    readonly property string contents: screen.listContents(listMenu.list)
    items: [
      { label: "Rename", action: "rename" },
      { label: "Delete list", action: "delete", danger: true,
        detail: count === 0 ? "It's empty" : "Its " + contents + (count === 1 ? " moves" : " move") + " to the Inbox" }
    ]
    onPicked: function(action) {
      if (action === "rename") screen.renaming = listMenu.list
      else screen.deleteList(listMenu.list)
    }
  }

  // Reminders and where To-dos.md lives, laid out like the journal's settings.
  Sheet {
    id: folderSheet
    panelWidth: 620
    property bool editingFolder: false
    // A new folder for a list that has to-dos: whether to move them there is
    // asked first. The folder asked about, or "".
    property string movingTo: ""
    property bool moving: false
    // What the last folder change did, or why it could not.
    property string folderMessage: ""
    property bool folderError: false
    readonly property string folderName: String(screen.app.todoSettings.folder || "")
    // Spoken to-dos would land in the file being moved, so the move waits
    // for them, and says what for.
    readonly property string moveWait: !screen.app.todoTake ? ""
      : screen.app.phase === "recording" ? "Finish the to-dos you are recording first."
      : screen.app.phase === "processing" ? "Wait until the to-dos are added." : ""
    // Not while the to-dos move: the result would have nowhere to show.
    onClosed: if (!moving) open = false
    onOpenChanged: { editingFolder = false; movingTo = ""; folderMessage = ""; folderError = false }

    function useFolder(value) {
      folderMessage = ""
      folderError = false
      if (value === folderName) editingFolder = false
      // An unreadable file may still hold to-dos, so that asks too.
      else if (screen.todos.length === 0 && !screen.loadError) { screen.app.todoSetting("folder", value); editingFolder = false }
      else movingTo = value
    }
    // The window moves the file, as for the journal: it can write both
    // folders. The move saves the folder with it; telling the daemon then
    // opens the new folder to it.
    function moveTodos() {
      var to = movingTo
      moving = true
      folderError = false
      folderMessage = ""
      var from = folderName
      screen.app.query(["todos", "move-folder", to], function(value, error) {
        moving = false
        if (!value) { folderError = true; folderMessage = error; return }
        screen.app.todoSetting("folder", to)
        var left = value.left_behind || []
        folderMessage = "Moved your to-dos to " + to + "."
          + (left.length > 0 ? " " + (left.length === 1 ? "This" : "These") + " could not be removed from " + from + ": " + left.join(", ") + "."
            + " Delete " + (left.length === 1 ? "it" : "them") + " there yourself once you've checked the new folder." : "")
        movingTo = ""
        editingFolder = false
      })
    }
    function leaveThem() {
      var from = folderName
      screen.app.todoSetting("folder", movingTo)
      folderError = false
      folderMessage = "Your to-dos stay in " + from + "."
      movingTo = ""
      editingFolder = false
    }

    Column {
      width: parent.width
      spacing: 4
      UiText { height: 36; verticalAlignment: Text.AlignVCenter; text: "Reminders and folder"; font.pixelSize: 20; weight: Font.Bold }
      SheetRow {
        title: "Remind me"
        caption: "How long before a to-do's time, such as \u201ccall the bank at 3pm\u201d. To-dos with only a date don't remind you."
        Segmented {
          name: "Remind me"
          size: 12
          horizontalPadding: 10
          options: [{ value: "0", label: "At the time" }, { value: "5", label: "5 min" }, { value: "15", label: "15 min" }, { value: "30", label: "30 min" }, { value: "60", label: "1 hour" }]
          current: String(screen.app.todoSettings.remind_before || 0)
          onPicked: function(value) { screen.app.todoSetting("remind_before", Number(value)) }
        }
      }
      SheetRow {
        title: "Folder"
        caption: folderSheet.folderName.replace(/\/$/, "") + "/To-dos.md"
        monoCaption: true
        visible: !folderSheet.editingFolder
        last: true
        Pill { kind: "outline"; text: "Change"; size: 13; onClicked: { folderSheet.folderMessage = ""; folderSheet.editingFolder = true } }
      }
      // What the folder change did, under the folder it is about.
      UiText {
        visible: !folderSheet.editingFolder && folderSheet.folderMessage.length > 0
        width: parent.width
        bottomPadding: 12
        text: folderSheet.folderMessage
        color: Theme.secondary
        wrapMode: Text.Wrap
      }

      Column {
        visible: folderSheet.editingFolder
        width: parent.width
        spacing: 10
        topPadding: 12
        bottomPadding: 14
        Field {
          id: folder
          visible: folderSheet.movingTo.length === 0
          width: parent.width
          label: "Folder"
          mono: true
          text: folderSheet.folderName
          hint: "To-dos.md lives here."
          problem: /^[~\/]/.test(text.trim()) ? "" : "Use a full path, such as ~/Documents/To-dos."
          onAccepted: if (problem.length === 0 && text.trim().length > 0) folderSheet.useFolder(text.trim())
        }
        Row {
          visible: folderSheet.movingTo.length === 0
          spacing: 8
          Pill { kind: "fill"; text: "Cancel"; size: 13; onClicked: folderSheet.editingFolder = false }
          Pill {
            kind: "primary"; text: "Use this folder"; size: 13
            enabled: folder.problem.length === 0 && folder.text.trim().length > 0
            onClicked: folderSheet.useFolder(folder.text.trim())
          }
        }

        // The consequence first: the to-dos move with the folder, or stay.
        Column {
          visible: folderSheet.movingTo.length > 0
          width: parent.width
          spacing: 10
          UiText {
            width: parent.width
            text: "Move your to-dos to " + folderSheet.movingTo + "?"
            font.pixelSize: 15
            weight: Font.DemiBold
            wrapMode: Text.Wrap
          }
          UiText {
            width: parent.width
            text: folderSheet.moveWait || (folderSheet.moving ? "Moving your to-dos…"
              : "If you don't move them, they stay in " + folderSheet.folderName + " and this page shows the To-dos.md in " + folderSheet.movingTo + ".")
            muted: true
            wrapMode: Text.Wrap
          }
          UiText {
            visible: folderSheet.folderError && folderSheet.folderMessage.length > 0
            width: parent.width
            text: folderSheet.folderMessage
            color: Theme.redText
            wrapMode: Text.Wrap
          }
          Row {
            spacing: 8
            // The new folder may hold a To-dos.md of its own, so not moving
            // is not "starting empty". Moving stays the main way, even after
            // an error that says what to fix first.
            Pill {
              kind: "primary"; text: "Move them"; size: 13
              enabled: !folderSheet.moving && !folderSheet.moveWait
              onClicked: folderSheet.moveTodos()
            }
            Pill { kind: "fill"; text: "Don't move them"; size: 13; enabled: !folderSheet.moving && !folderSheet.moveWait; onClicked: folderSheet.leaveThem() }
            Pill { kind: "link"; text: "Cancel"; size: 13; enabled: !folderSheet.moving; onClicked: { folderSheet.movingTo = ""; folderSheet.folderError = false; folderSheet.folderMessage = "" } }
          }
        }
      }

      // Hidden while a folder change is open: that step ends with its own
      // buttons, not with a Done that would quietly drop it.
      Item {
        visible: !folderSheet.editingFolder
        width: parent.width
        height: 44
        Pill { anchors.right: parent.right; anchors.bottom: parent.bottom; kind: "primary"; text: "Done"; size: 13; verticalPadding: 8; horizontalPadding: 18; onClicked: folderSheet.open = false }
      }
    }
  }
}
