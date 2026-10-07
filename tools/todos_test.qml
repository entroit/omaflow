// The to-do page against a stubbed file with an Inbox and three lists:
// ticking, deleting and clearing with Undo, the views across lists, where
// typed and spoken to-dos go, the row's lanes and menus, the When menu and
// its moments, reminders, Bubbled up, deleting a list, and the keys that
// reach all of it.
//   qmltestrunner -input tools/todos_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
import "preview/Fixtures.js" as Fixtures
import "../ui/Dates.js" as Dates

Item {
  id: root
  width: 880; height: 640
  property var sent: []
  property var list: Fixtures.TODOS
  property var lists: Fixtures.LISTS
  property var reminded: []
  // What the next new list or rename answers with instead of working.
  property string listFails: ""
  // What reading the file or moving it answers with instead of working.
  property string readFails: ""
  property string moveFails: ""
  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    host: QtObject {
      function spawn(argv, callback) {
        var args = argv.slice(1)
        root.sent.push(args.join(" "))
        var failed = root.listFails && (args[1] === "new-list" || args[1] === "rename-list")
        var reply = args[0] === "todos" && args[1] === "list" && root.readFails ? JSON.stringify({ error: root.readFails })
          : args[0] === "todos" && args[1] === "move-folder" && root.moveFails ? JSON.stringify({ error: root.moveFails })
          : args[0] === "todos" && args[1] === "move-folder" ? JSON.stringify({ moved: true, folder: args[2] })
          : args[0] === "todos" && args[1] === "list"
          ? JSON.stringify({ path: "/tmp/To-dos.md", today: Fixtures.TODAY, lists: root.lists, current: "Infra", todos: root.list, reminded: root.reminded })
          : failed ? JSON.stringify({ error: root.listFails })
          : args[1] === "add" ? JSON.stringify({ added: [{ index: 10, text: args[2].replace(" by Monday", ""), done: false, list: args[3], due: args[2].indexOf("by Monday") > 0 ? "2026-09-28" : args[4] || null }] })
          : args[1] === "new-list" ? JSON.stringify({ list: args[2] })
          : args[1] === "rename-list" ? JSON.stringify({ list: args[3] })
          : args[1] === "snooze" ? JSON.stringify({ until: args[4] === "tomorrow" ? "2026-09-26 18:42" : "2026-09-25 18:57" }) : "{}"
        if (callback) Qt.callLater(function() { callback(reply, "", failed ? 1 : 0) })
      }
      function copy(text) {}
      function openInEditor(path) {}
      function openExternally(target) {}
    }
    Component.onCompleted: {
      var state = Fixtures.state("todos-list", Fixtures.NOW)
      applyState(JSON.stringify(state))
    }
  }
  // Away from your own ~/.local/state.
  readonly property string stateFile: "file:///tmp/omaflow-todos-test/ui.ini"
  TodosScreen { id: screen; anchors.fill: parent; app: app; active: true; stateFile: root.stateFile }
  Component { id: anotherScreen; TodosScreen { stateFile: root.stateFile } }

  function writes() { return root.sent.filter(function(line) { return line.indexOf("todos list") < 0 }) }
  function texts() { return screen.rows.filter(function(r) { return r.kind === "row" && !r.ghost }).map(function(r) { return r.todo.text }) }
  function find(item, text) {
    if (item.text === text && item.visible) return item
    for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i], text); if (f) return f }
    return null
  }
  function named(item, name) {
    if (item.Accessible && item.Accessible.name === name && item.visible) return item
    for (var i = 0; i < item.children.length; i++) { var f = named(item.children[i], name); if (f) return f }
    return null
  }
  // The page's rows, as TodoRow is wired up there under another name.
  function rowsOf(item, out) {
    out = out || []
    if (item.objectName === "TodoRow") out.push(item)
    for (var i = 0; i < item.children.length; i++) rowsOf(item.children[i], out)
    return out
  }
  function rowOf(text) { return rowsOf(screen).filter(function(r) { return r.todo.text === text && !r.ghost })[0] || null }
  function openMenu() {
    for (var i = 0; i < screen.children.length; i++) if (String(screen.children[i]).indexOf("PopupMenu") === 0 && screen.children[i].open) return screen.children[i]
    return null
  }
  // A button by its words, as the rail and the time field can say the same.
  function pill(item, text, kind) {
    if (item.text === text && item.kind === kind && item.visible) return item
    for (var i = 0; i < item.children.length; i++) { var f = pill(item.children[i], text, kind); if (f) return f }
    return null
  }

  TestCase {
    name: "Todos"
    when: windowShown
    function init() {
      root.sent = []
      root.list = Fixtures.TODOS
      root.lists = Fixtures.LISTS
      root.reminded = []
      root.listFails = ""
      root.readFails = ""
      root.moveFails = ""
      screen.pending = null; screen.settling = []; screen.cursor = -1
      screen.doneShown = false; screen.toast = ""; screen.ticked = null
      screen.reload(); wait(30)
      screen.select("list", "Infra")
    }

    function test_opens_on_the_current_list_with_done_under_it() {
      compare(screen.title, "Infra")
      compare(texts(), ["Renew the TLS certs on the staging box", "Move the backups to the new bucket, and check that the old ones restore before deleting them"], "Done starts folded")
      verify(screen.rows.some(function(r) { return r.kind === "done" && r.count === 1 }))
      screen.doneShown = true
      compare(texts()[2], "Rotate the deploy key")
      screen.select("list", "Dev")
      verify(screen.doneShown, "and stays open from list to list")
    }
    function test_done_stays_as_you_left_it_after_a_restart() {
      var before = anotherScreen.createObject(root, { app: app })
      before.doneShown = true
      before.destroy(); wait(0)
      var after = anotherScreen.createObject(root, { app: app })
      verify(after.doneShown, "open")
      after.doneShown = false
      after.destroy(); wait(0)
      var again = anotherScreen.createObject(root, { app: app })
      verify(!again.doneShown, "and folded")
      again.destroy()
    }
    function test_the_page_opens_on_today() {
      screen.opened = false
      screen.reload(); wait(30)
      compare(screen.view, "today")
      compare(screen.title, "Today")
    }
    function test_nothing_is_said_before_the_list_is_read() {
      screen.loaded = false
      compare(screen.rows, [])
      compare(screen.title, "")
      screen.reload(); wait(30)
      compare(screen.title, "Infra")
    }
    function test_views_across_lists() {
      screen.select("today", "")
      compare(texts(), ["Renew the TLS certs on the staging box", "Call Mira about the lease", "Fix the AltGr binding when Super is held first"], "late first, then today")
      verify(screen.rows[0].showList, "each says its list")
      screen.select("upcoming", "")
      compare(screen.rows.filter(function(r) { return r.kind === "heading" }).length, 2)
      screen.select("all", "")
      compare(screen.rows.filter(function(r) { return r.kind === "heading" }).map(function(r) { return r.label }), ["Inbox", "Infra", "Dev", "Feature"])
      screen.select("done", "")
      compare(texts().length, 3)
    }
    function test_typing_adds_to_the_list_on_screen_and_makes_it_current() {
      screen.select("list", "Dev")
      screen.addTyped("Review the PR")
      tryVerify(function() { return writes().indexOf("todo-list Dev") >= 0 })
      compare(writes()[0], "todos add Review the PR Dev ")
    }
    function test_today_adds_to_the_current_list_due_today() {
      screen.select("today", "")
      screen.addTyped("Book the train")
      compare(writes()[0], "todos add Book the train Infra " + Fixtures.TODAY)
    }
    function test_talk_sends_the_list_on_screen() {
      screen.select("list", "Feature")
      mouseClick(find(screen, "Talk"))
      compare(writes(), ["todo-toggle {\"list\":\"Feature\",\"due\":\"\"}"])
    }
    function test_tick_stays_in_place_then_moves() {
      screen.toggle(screen.rows[0].todo)
      compare(writes(), ["todos done 2 Renew the TLS certs on the staging box"])
      compare(screen.rows[0].todo.index, 2, "still in place while the line is drawn")
      tryCompare(screen, "settling", [], 2000)
    }
    function test_keyboard_delete_and_undo() {
      screen.focusKeys()
      keyClick(Qt.Key_Down)
      keyClick(Qt.Key_Delete)
      compare(writes(), ["todos delete 2 Renew the TLS certs on the staging box"])
      verify(screen.rows[0].ghost, "greyed out in its place")
      keyClick(Qt.Key_Z, Qt.ControlModifier)
      compare(writes()[1], "todos restore")
      compare(screen.pending, null)
    }
    function test_clear_done_clears_only_this_list() {
      screen.clearDone()
      compare(writes(), ["todos clear-done Infra"])
      compare(screen.pending.items.length, 1)
    }
    function test_move_and_date() {
      var todo = screen.rows[1].todo
      screen.moveTo(todo, "Dev")
      screen.setDue(todo, "2026-09-26")
      compare(writes(), ["todos move 3 " + todo.text + " Dev", "todos due 3 " + todo.text + " 2026-09-26 "])
    }
    function test_a_new_day_keeps_the_time_and_no_date_drops_it() {
      var timed = Object.assign({}, Fixtures.TODOS[0])
      screen.setDue(timed, "2026-09-28")
      screen.setDue(timed, "")
      compare(writes(), ["todos due 0 Call Mira about the lease 2026-09-28 15:00", "todos due 0 Call Mira about the lease  "])
    }
    function picker() {
      var duePicker = null
      ;(function look(item) { if (String(item).indexOf("DuePicker") === 0) duePicker = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(screen)
      return duePicker
    }
    function test_the_picker_sets_a_day_and_a_time() {
      screen.select("list", "")
      screen.menuTodo = screen.rows[0].todo
      var duePicker = picker()
      duePicker.date = "2026-09-25"; duePicker.time = ""; duePicker.reminder = ""
      duePicker.open = true
      waitForRendering(screen)
      compare(Dates.fortnight(duePicker.start).length, 14, "two weeks")
      compare(duePicker.start, "2026-09-21", "this week and next")
      mouseClick(find(duePicker, "2"))  // Friday 2 October, in the second week
      compare(duePicker.chosen, "2026-10-02")
      mouseClick(named(duePicker, "Type another time"))
      verify(named(duePicker, "Time, such as 15:00 or 3pm").activeFocus, "Other… opens the typed time")
      keyClick(Qt.Key_3); keyClick(Qt.Key_P); keyClick(Qt.Key_M)
      compare(duePicker.typedTime, "15:00")
      verify(find(duePicker, "Friday 15:00") === null && find(duePicker, "2 Oct 15:00") !== null, "the result, as the row will say it")
      keyClick(Qt.Key_Return)
      verify(!duePicker.open, "Enter sets it and closes")
      compare(writes(), ["todos due 0 Call Mira about the lease 2026-10-02 15:00 default"], "on the default, 15 minutes before")
    }
    function test_the_picker_offers_the_times_a_reminder_can_be() {
      var fix = Fixtures.TODOS[5]
      screen.menuTodo = fix
      var duePicker = picker()
      duePicker.date = fix.due; duePicker.time = fix.time; duePicker.reminder = fix.reminder
      duePicker.open = true
      waitForRendering(screen)
      compare(duePicker.remind, "30", "16:30 set by hand on a 17:00 to-do")
      verify(find(duePicker, "At 16:30") !== null, "one line says what will happen")
      var remindMenu = null
      ;(function look(item) { if (String(item).indexOf("PopupMenu") === 0) remindMenu = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(duePicker)
      mouseClick(named(duePicker, "Remind me: At 16:30"))
      verify(remindMenu.open)
      waitForRendering(screen)
      verify(find(remindMenu, "16:45") !== null && find(remindMenu, "16:00") !== null && find(remindMenu, "Off") !== null, "the choices are times, not offsets")
      mouseClick(find(remindMenu, "17:00"))
      compare(duePicker.remind, "0")
      verify(duePicker.open, "choosing one keeps the picker open")
      duePicker.set()
      duePicker.reminder = "off"; duePicker.open = true
      waitForRendering(screen)
      compare(duePicker.remind, "off")
      verify(find(duePicker, "Off") !== null)
      remindMenu.open = true
      waitForRendering(screen)
      verify(find(remindMenu, "Default") !== null, "the choice that is the default says so")
      mouseClick(find(remindMenu, "16:45"))
      duePicker.set()
      duePicker.reminder = "2026-09-25 18:57"; duePicker.open = true
      compare(duePicker.remind, "keep", "a snooze is none of the choices")
      duePicker.set()
      compare(writes(), [
        "todos due 5 Fix the AltGr binding when Super is held first 2026-09-25 17:00 0",
        "todos due 5 Fix the AltGr binding when Super is held first 2026-09-25 17:00 15",
        "todos due 5 Fix the AltGr binding when Super is held first 2026-09-25 17:00"], "the default's own time, picked by hand, is kept as that time")
    }
    function test_a_reminder_across_midnight_says_the_day() {
      compare(Dates.clockOn(Dates.later("2026-09-25 00:10", -30), "2026-09-25"), "Thu 23:40")
      compare(Dates.clockOn("2026-09-25 16:30", "2026-09-25"), "16:30")
      compare(Dates.remindSaid("2026-09-25 16:30", "2026-09-25", "2026-09-25"), "at 16:30")
      compare(Dates.remindSaid("2026-09-24 23:40", "2026-09-25", "2026-09-25"), "yesterday at 23:40")
    }
    function test_a_date_alone_says_how_to_be_reminded() {
      screen.menuTodo = screen.rows[0].todo
      var duePicker = picker()
      duePicker.date = "2026-09-25"; duePicker.time = ""; duePicker.reminder = ""
      duePicker.open = true
      waitForRendering(screen)
      verify(find(duePicker, "Add a time to be reminded") !== null)
      duePicker.open = false
    }
    function test_a_reminder_by_hand_or_none_shows_on_the_row() {
      screen.select("all", "")
      waitForRendering(screen)
      verify(find(screen, "16:30") !== null, "the time it reminds you instead")
      var off = null
      ;(function look(item) { if (item.Accessible && item.Accessible.name === "No reminder" && item.visible) off = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(screen)
      ;(function look(item) { if (item.Accessible && item.Accessible.name.indexOf("No reminder.") === 0 && item.visible) off = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(screen)
      verify(off !== null, "a struck bell where there is none")
      compare(find(screen, "Snooze"), null, "nothing has reminded you yet")
    }
    function test_bubbled_up_holds_what_reminded_you_until_done_or_later() {
      root.reminded = [0, 5]
      screen.select("today", "")
      screen.reload(); wait(30)
      waitForRendering(screen)
      compare(screen.rows[0].kind, "bubbled")
      compare(screen.rows[0].items.map(function(t) { return t.index }), [5, 0], "the latest reminder first: 16:30, then 14:45")
      compare(texts(), ["Renew the TLS certs on the staging box"], "out of the list below")
      verify(find(screen, "Bubbled up") !== null)
      verify(find(screen, "Reminded at 14:45") !== null && find(screen, "Reminded at 16:30") !== null)
      compare(find(screen, "Snooze"), null, "no Snooze of its own")
      var mira = rowOf("Call Mira about the lease")
      verify(mira.bubbled)
      mouseClick(mira.laterAnchor)
      var menu = openMenu()
      verify(menu !== null, "Later opens the moments")
      waitForRendering(screen)
      verify(find(menu, "Remind me again") !== null)
      compare(find(menu, "Today"), null, "only moments that remind you")
      mouseClick(find(menu, "Tomorrow morning"))
      compare(writes(), ["todos snooze 0 Call Mira about the lease 858"], "18:42 to 09:00 tomorrow")
      tryCompare(screen, "toast", "Reminds you again at 18:57")
      root.reminded = [5]
      screen.reload(); wait(30)
      compare(screen.rows[0].items.length, 1, "Later takes it out")
      verify(texts().indexOf("Call Mira about the lease") >= 0, "back in the list")
      mouseClick(pill(screen, "Done", "primary"))
      compare(writes()[1], "todos done 5 Fix the AltGr binding when Super is held first")
      root.reminded = []
      root.list = Fixtures.TODOS.map(function(t) { return t.index === 5 ? Object.assign({}, t, { done: true }) : t })
      screen.reload(); wait(30)
      tryCompare(screen, "settling", [], 2000)
      verify(!screen.rows.some(function(r) { return r.kind === "bubbled" }), "and Done leaves nothing behind")
    }
    function test_bubbled_up_counts_in_today_even_when_due_later() {
      root.reminded = [3]
      root.list = Fixtures.TODOS.map(function(t) { return t.index === 3 ? Object.assign({}, t, { time: "09:00", reminder: "2026-09-25 12:00" }) : t })
      screen.select("today", "")
      screen.reload(); wait(30)
      compare(screen.rows[0].items[0].index, 3, "due Monday, but it has reminded you")
      compare(screen.todayCount, 4)
    }
    function test_reminder_moments_count_across_midnight() {
      compare(Dates.later("2026-09-25 00:10", -30), "2026-09-24 23:40")
      compare(Dates.minutesBetween("2026-09-24 23:40", "2026-09-25 00:10"), 30)
      compare(Dates.remindAt("2026-09-25 16:30", "2026-09-25", "2026-09-25"), "16:30")
      compare(Dates.remindAt("2026-09-24 23:40", "2026-09-25", "2026-09-25"), "Yesterday 23:40")
    }
    function test_typed_times_are_read_like_people_write_them() {
      compare(Dates.clockTime("15:00"), "15:00")
      compare(Dates.clockTime("9"), "09:00")
      compare(Dates.clockTime("3pm"), "15:00")
      compare(Dates.clockTime("3:30 p.m."), "15:30")
      compare(Dates.clockTime("12am"), "00:00")
      compare(Dates.clockTime(""), "")
      compare(Dates.clockTime("25:00"), null)
      compare(Dates.clockTime("soon"), null)
      compare(Dates.dueAt("2026-09-26", "09:30", "2026-09-25"), "Tomorrow 09:30")
    }
    function test_a_time_passed_today_is_late() {
      screen.select("today", "")
      var mira = screen.rows.filter(function(r) { return r.kind === "row" && r.todo.text === "Call Mira about the lease" })[0]
      verify(mira, "timed to-do is due today")
      var late = find(screen, "Today 15:00")
      verify(late !== null && late.color === Theme.redText, "15:00 has passed at 18:42")
    }
    function test_brackets_walk_the_rail() {
      screen.focusKeys()
      keyClick(Qt.Key_BracketRight)
      compare(screen.viewKey, "list:Dev")
      keyClick(Qt.Key_BracketLeft)
      keyClick(Qt.Key_BracketLeft)
      compare(screen.viewKey, "list:")
    }
    function test_deleting_a_list_offers_undo() {
      screen.deleteList("Infra")
      tryCompare(screen, "deletedList", "Infra")
      compare(screen.viewKey, "list:", "back to the Inbox")
      verify(writes().indexOf("todo-list ") >= 0, "the current list falls back to the Inbox")
      compare(screen.toastAction, "Undo")
      screen.undo()
      verify(writes().indexOf("todos restore") >= 0)
    }
    function test_a_list_shows_its_menu_on_hover() {
      var place = find(screen, "Dev")
      verify(place, "Dev is in the rail")
      mouseMove(place, 10, 5)
      var more = null
      tryVerify(function() { more = find(screen, "Dev").parent; return more.showMore })
      mouseClick(more, more.width - 17, more.height / 2)
      tryVerify(function() { return find(screen, "Rename") !== null })
      waitForRendering(screen)
      mouseClick(find(screen, "Rename"))
      compare(screen.renaming, "Dev")
      keyClick(Qt.Key_Escape)
      compare(screen.renaming, "", "Escape leaves the name as it was")
      verify(writes().every(function(line) { return line.indexOf("rename-list") < 0 }))
    }
    function test_renaming_a_list_follows_it() {
      screen.select("list", "Dev")
      screen.renameList("Dev", "Backend")
      tryVerify(function() { return writes().indexOf("todos rename-list Dev Backend") >= 0 })
    }
    function test_enter_edits_and_escape_cancels() {
      screen.focusKeys()
      keyClick(Qt.Key_Down)
      keyClick(Qt.Key_Return)
      compare(screen.editingIndex, screen.navigable[0].index)
      keyClick(Qt.Key_Escape)
      compare(screen.editingIndex, -1)
      compare(writes(), [], "nothing written")
      // The list's keys work again: Delete deletes the to-do, not a letter.
      keyClick(Qt.Key_Delete)
      compare(writes(), ["todos delete 2 Renew the TLS certs on the staging box"])
    }
    function test_a_reminder_opens_on_today() {
      screen.openOn("today")
      compare(screen.view, "today", "already loaded: straight to Today")
      screen.opened = false
      screen.openOn("upcoming")
      screen.reload(); wait(30)
      compare(screen.view, "upcoming", "not loaded yet: that view once it is")
    }
    function test_without_lists_new_list_is_in_sight() {
      root.lists = []
      root.list = Fixtures.FLAT
      screen.reload(); wait(30)
      verify(!screen.hasLists)
      compare(screen.title, "Inbox")
      verify(find(screen, "Today") !== null, "Today, Upcoming and the rest are there without lists")
      mouseClick(find(screen, "New list"))
      verify(screen.makingList)
      waitForRendering(screen)
      keyClick(Qt.Key_W); keyClick(Qt.Key_O); keyClick(Qt.Key_R); keyClick(Qt.Key_K)
      keyClick(Qt.Key_Return)
      tryVerify(function() { return writes().indexOf("todos new-list work") >= 0 })
    }
    function test_edit_puts_the_cursor_at_the_end() {
      var todo = screen.rows[0].todo
      screen.startEdit(todo)
      waitForRendering(screen)
      keyClick(Qt.Key_S)
      compare(screen.editDraft, todo.text + "s", "a key adds a letter, it does not replace the words")
      keyClick(Qt.Key_Return)
      compare(writes(), ["todos edit 2 " + todo.text + " " + todo.text + "s"])
    }
    function test_ticking_while_editing_keeps_the_words_and_ticks() {
      var todo = screen.rows[0].todo
      screen.startEdit(todo)
      waitForRendering(screen)
      keyClick(Qt.Key_S)
      screen.toggle(todo)
      compare(screen.editingIndex, -1, "the edit ends")
      tryVerify(function() { return writes().length === 2 })
      compare(writes(), ["todos edit 2 " + todo.text + " " + todo.text + "s", "todos done 2 " + todo.text + "s"])
    }
    function test_clicking_elsewhere_keeps_the_edit() {
      var todo = screen.rows[0].todo
      screen.startEdit(todo)
      waitForRendering(screen)
      keyClick(Qt.Key_S)
      mouseClick(screen, screen.width - 40, screen.height / 2)
      compare(screen.editingIndex, -1)
      compare(writes(), ["todos edit 2 " + todo.text + " " + todo.text + "s"])
    }
    function test_clicking_inside_the_field_keeps_editing() {
      var todo = screen.rows[0].todo
      screen.startEdit(todo)
      waitForRendering(screen)
      var field = screen.Window.activeFocusItem
      mouseClick(field, 10, field.height / 2)
      compare(screen.editingIndex, todo.index)
      verify(field.activeFocus)
      keyClick(Qt.Key_Escape)
    }
    function test_ticking_while_editing_unchanged_just_ticks() {
      var todo = screen.rows[0].todo
      screen.startEdit(todo)
      waitForRendering(screen)
      screen.toggle(todo)
      compare(writes(), ["todos done 2 " + todo.text])
      // Rebuilt as done, the row shows its words, not an empty edit field.
      root.list = Fixtures.TODOS.map(function(t) { return t.index === todo.index ? Object.assign({}, t, { done: true }) : t })
      screen.editingIndex = todo.index  // even if an edit were still marked
      screen.reload(); wait(30)
      tryCompare(screen, "settling", [], 2000)
      wait(30)
      function doneRow(item) {
        if (item.objectName === "TodoRow" && item.todo.index === todo.index && item.todo.done) return item
        for (var i = 0; i < item.children.length; i++) { var f = doneRow(item.children[i]); if (f) return f }
        return null
      }
      screen.doneShown = true
      wait(30)
      var row = doneRow(screen)
      verify(row !== null)
      verify(!row.editing, "a done to-do is never shown as an edit field")
      verify(find(row, todo.text) !== null, "and shows its words")
    }

    function test_typing_where_it_will_not_show_says_where_it_went() {
      screen.select("upcoming", "")
      screen.addTyped("Book the train")
      tryCompare(screen, "toast", "Added to Infra")
      screen.select("list", "Dev")
      screen.addTyped("Ship it by Monday")
      wait(30)
      compare(screen.toast, "Added to Infra", "it shows in Dev, so nothing new is said")
      screen.select("done", "")
      screen.addTyped("Ship it by Monday")
      tryCompare(screen, "toast", "Added to Infra, due Monday")
    }
    function test_the_add_button_names_the_list() {
      var composer = null
      ;(function look(item) { if (String(item).indexOf("JournalComposer") === 0) composer = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(screen)
      compare(composer.addLabel, "Add to Infra")
      screen.select("list", "")
      compare(composer.addLabel, "Add to Inbox")
    }
    function test_ticking_out_of_sight_offers_undo() {
      screen.select("today", "")
      var todo = screen.navigable[1]
      screen.toggle(todo)
      compare(screen.toast, "Done: " + todo.text)
      compare(screen.toastAction, "Undo")
      screen.focusKeys()
      keyClick(Qt.Key_Z, Qt.ControlModifier)
      compare(writes(), ["todos done 0 " + todo.text, "todos undone 0 " + todo.text])
      compare(screen.toast, "")
    }
    function test_opens_on_a_list_by_name() {
      screen.openOn("list:Dev")
      compare(screen.viewKey, "list:Dev")
      screen.openOn("list:")
      compare(screen.viewKey, "list:")
      screen.openOn("list:Gone")
      compare(screen.viewKey, "list:", "a list that is gone opens the Inbox")
      screen.opened = false
      screen.openOn("list:Feature")
      screen.reload(); wait(30)
      compare(screen.viewKey, "list:Feature", "before the list is read too")
    }
    function test_keys_open_the_rows_menus() {
      screen.select("today", "")
      waitForRendering(screen)
      screen.focusKeys()
      keyClick(Qt.Key_Down)
      keyClick(Qt.Key_D)
      var menu = openMenu()
      verify(menu !== null, "D opens the When menu")
      tryVerify(function() { return screen.Window.activeFocusItem && screen.Window.activeFocusItem.Accessible.name === "Tomorrow morning" }, 1000, "its first choice has the keyboard, past the heading")
      keyClick(Qt.Key_Down)
      compare(screen.Window.activeFocusItem.Accessible.name, "Monday morning")
      keyClick(Qt.Key_Escape)
      verify(!menu.open)
      keyClick(Qt.Key_M)
      tryVerify(function() { return screen.Window.activeFocusItem && screen.Window.activeFocusItem.Accessible.name === "Inbox" }, 1000, "M opens Move to")
      keyClick(Qt.Key_Escape)
      keyClick(Qt.Key_Down); keyClick(Qt.Key_Down)
      keyClick(Qt.Key_R)
      tryVerify(function() { return screen.Window.activeFocusItem && screen.Window.activeFocusItem.Accessible.name === "Reminder for 17:00, 30 minutes before, at 16:30" }, 1000, "R opens the reminder, on the one set")
      keyClick(Qt.Key_Right)
      keyClick(Qt.Key_Return)
      tryVerify(function() { return writes().indexOf("todos remind 5 Fix the AltGr binding when Super is held first 60") >= 0 }, 1000, "the arrows walk the times")
    }
    function test_l_asks_when_to_remind_again() {
      root.reminded = [0]
      screen.select("today", "")
      screen.reload(); wait(30)
      screen.focusKeys()
      keyClick(Qt.Key_Down)
      compare(screen.navigable[0].index, 0, "Bubbled up comes first for the keys too")
      keyClick(Qt.Key_L)
      tryVerify(function() { return screen.Window.activeFocusItem && screen.Window.activeFocusItem.Accessible.name === "Tomorrow morning" })
      keyClick(Qt.Key_Down)
      keyClick(Qt.Key_Return)
      tryVerify(function() { return writes().indexOf("todos snooze 0 Call Mira about the lease " + (3 * 24 * 60 + 9 * 60 - (18 * 60 + 42))) >= 0 }, 1000, "Monday 09:00")
    }
    function test_moments_follow_the_clock() {
      function labels(now, today) { return Dates.moments(now, today).map(function(m) { return m.label + " " + Dates.momentAside(m, today) }) }
      // Friday 25 September 2026.
      compare(labels("2026-09-25 08:00", "2026-09-25"), ["Later today 18:00", "Tomorrow morning Sat 09:00", "Monday morning Mon 09:00", "Next week Fri 2 Oct, 09:00", "Today Fri 25 Sep", "Tomorrow Sat 26 Sep"])
      compare(labels("2026-09-25 14:59", "2026-09-25")[0], "Later today 18:00")
      compare(labels("2026-09-25 15:00", "2026-09-25")[0], "This evening 20:00", "from 15:00, the evening")
      compare(labels("2026-09-25 17:59", "2026-09-25")[0], "This evening 20:00")
      compare(labels("2026-09-25 18:00", "2026-09-25")[0], "Tomorrow morning Sat 09:00", "from 18:00, nothing more today")
      // Sunday: Monday morning is tomorrow morning.
      compare(labels("2026-09-27 10:00", "2026-09-27"), ["Later today 18:00", "Tomorrow morning Mon 09:00", "Next week Sun 4 Oct, 09:00", "Today Sun 27 Sep", "Tomorrow Mon 28 Sep"])
      // Monday: next Monday is next week.
      compare(labels("2026-09-28 19:00", "2026-09-28"), ["Tomorrow morning Tue 09:00", "Next week Mon 5 Oct, 09:00", "Today Mon 28 Sep", "Tomorrow Tue 29 Sep"])
      // Saturday, across the end of the month and the year.
      compare(labels("2026-12-26 16:00", "2026-12-26"), ["This evening 20:00", "Tomorrow morning Sun 09:00", "Monday morning Mon 09:00", "Next week Sat 2 Jan, 09:00", "Today Sat 26 Dec", "Tomorrow Sun 27 Dec"])
      var m = Dates.moments("2026-09-25 08:00", "2026-09-25")
      compare([m[0].date, m[0].time, m[4].date, m[4].time], ["2026-09-25", "18:00", "2026-09-25", ""], "a day alone has no time")
      compare(Dates.fortnightTitle("2026-09-21"), "Sep \u2013 Oct 2026")
      compare(Dates.fortnightTitle("2026-09-07"), "September 2026")
    }
    function test_the_row_menu_moves_edits_and_deletes() {
      waitForRendering(screen)
      var renew = rowOf("Renew the TLS certs on the staging box")
      mouseClick(renew.menuAnchor)
      var menu = openMenu()
      waitForRendering(screen)
      verify(find(menu, "Move to") !== null && find(menu, "Infra") === null, "every other list")
      mouseClick(find(menu, "Dev"))
      compare(writes(), ["todos move 2 Renew the TLS certs on the staging box Dev"])
      mouseClick(renew, renew.width / 2, renew.height / 2, Qt.RightButton)
      menu = openMenu()
      verify(menu !== null, "a right-click opens the same menu")
      waitForRendering(screen)
      mouseClick(find(menu, "Edit"))
      compare(screen.editingIndex, 2)
      keyClick(Qt.Key_Escape)
      renew = rowOf("Renew the TLS certs on the staging box")
      mouseClick(renew.menuAnchor)
      menu = openMenu()
      waitForRendering(screen)
      mouseClick(find(menu, "Delete"))
      compare(writes()[1], "todos delete 2 Renew the TLS certs on the staging box")
      verify(screen.rows[0].ghost, "greyed out in its place, with Undo")
    }
    function test_the_when_menu_sets_the_day_and_time() {
      screen.select("list", "")
      waitForRendering(screen)
      var milk = rowOf("Buy oat milk")
      verify(find(milk, "No date") !== null, "a to-do without a date says so, in the same lane")
      mouseClick(milk.dueAnchor)
      var menu = openMenu()
      waitForRendering(screen)
      verify(find(menu, "Remind me") !== null && find(menu, "Just a day, no reminder") !== null)
      compare(find(menu, "No date"), null, "No date only when it has one")
      compare(find(menu, "Reminder for 15:00"), null, "no reminder without a time")
      mouseClick(find(menu, "Tomorrow morning"))
      mouseClick(rowOf("Buy oat milk").dueAnchor)
      menu = openMenu()
      waitForRendering(screen)
      mouseClick(find(menu, "Today"))
      compare(writes(), ["todos due 1 Buy oat milk 2026-09-26 09:00 default", "todos due 1 Buy oat milk 2026-09-25 "], "a moment with its time, a day alone without")
      root.list = Fixtures.TODOS.map(function(t) { return t.index === 1 ? Object.assign({}, t, { due: "2026-09-26", time: "09:00" }) : t })
      screen.reload(); wait(30)
      mouseClick(rowOf("Buy oat milk").dueAnchor)
      menu = openMenu()
      waitForRendering(screen)
      var item = named(menu, "Tomorrow morning")
      verify(item.Accessible.checked, "the current choice is ticked")
      verify(!named(menu, "Tomorrow").Accessible.checked)
      mouseClick(find(menu, "Pick a day and time\u2026"))
      verify(picker().open)
      compare(picker().chosen, "2026-09-26")
      picker().open = false
    }
    function test_the_reminder_is_one_click_from_the_when_menu_and_the_bell() {
      waitForRendering(screen)
      screen.select("today", "")
      waitForRendering(screen)
      mouseClick(rowOf("Call Mira about the lease").dueAnchor)
      var menu = openMenu()
      waitForRendering(screen)
      verify(find(menu, "Reminder for 15:00") !== null)
      var chips = menu.items[menu.items.length - 1].chips
      compare(chips.map(function(c) { return c.label }), ["On time", "5 min", "15 min", "30 min", "1 hour", "Off"], "short chips")
      compare(chips.map(function(c) { return c.name || c.label }).slice(0, 2), ["On time, at 15:00", "5 minutes before, at 14:55"], "the clock time is in the name")
      compare(chips.filter(function(c) { return c.checked }).map(function(c) { return c.label }), ["15 min"], "the default, as it follows it")
      verify(find(menu, "15 min before, at 14:45") !== null, "what it means is said once, under the chips")
      keyClick(Qt.Key_Escape)
      verify(!menu.open)
      var expect = { "15 min": "default", "30 min": "30", "On time": "0", "Off": "off" }
      for (var label in expect) {
        mouseClick(rowOf("Call Mira about the lease").dueAnchor)
        menu = openMenu()
        waitForRendering(screen)
        mouseClick(find(menu, label))
        compare(writes()[writes().length - 1], "todos remind 0 Call Mira about the lease " + expect[label], label)
      }
      var fix = rowOf("Fix the AltGr binding when Super is held first")
      verify(fix.reminderAnchor !== fix.dueAnchor, "a reminder set by hand shows its bell")
      mouseClick(fix.reminderAnchor)
      menu = openMenu()
      verify(menu !== null, "the bell opens the reminder")
      waitForRendering(screen)
      compare(find(menu, "Remind me"), null, "and only the reminder")
      verify(named(menu, "Reminder for 17:00, 30 minutes before, at 16:30") !== null, "the one set by hand is chosen")
      mouseClick(find(menu, "15 min"))
      compare(writes()[writes().length - 1], "todos remind 5 Fix the AltGr binding when Super is held first 15", "set by hand, the default's time stays a time")
    }
    function test_a_reminder_from_later_shows_as_itself() {
      var todo = Object.assign({}, Fixtures.TODOS[0], { reminder: "2026-09-25 18:57" })
      var items = screen.reminderItems(todo)
      compare(items[1].chips.map(function(c) { return c.label + (c.checked ? "*" : "") }), ["18:57*", "On time", "15 min", "30 min", "1 hour", "Off"])
    }
    function test_nothing_moves_under_the_pointer() {
      screen.select("today", "")
      waitForRendering(screen)
      var row = rowOf("Call Mira about the lease")
      function lanes(item, out) {
        out = out || []
        for (var i = 0; i < item.children.length; i++) {
          var child = item.children[i]
          if (!child.visible) continue
          var at = child.mapToItem(row, 0, 0)
          out.push(String(child).replace(/\(.*/, "") + " " + Math.round(at.x) + "," + Math.round(at.y) + " " + Math.round(child.width))
          lanes(child, out)
        }
        return out
      }
      mouseMove(screen, 2, screen.height - 2)
      waitForRendering(screen)
      verify(!row.lifted)
      var before = lanes(row)
      mouseMove(row, 60, row.height / 2)
      waitForRendering(screen)
      verify(row.lifted, "under the pointer")
      compare(lanes(row), before, "every part keeps its place and size")
      verify(Qt.colorEqual(row.color, Theme.hover), "and it lifts at once, in the theme's hover surface, with no fade")
      var other = rowOf("Renew the TLS certs on the staging box")
      compare(other.dueAnchor.mapToItem(screen, other.dueAnchor.width, 0).x, row.dueAnchor.mapToItem(screen, row.dueAnchor.width, 0).x, "dates end in one column")
      compare(other.menuAnchor.mapToItem(screen, 0, 0).x, row.menuAnchor.mapToItem(screen, 0, 0).x, "and ⋯ in another")
    }
    function test_tab_reaches_the_rail() {
      screen.focusKeys()
      keyClick(Qt.Key_Tab)
      compare(screen.Window.activeFocusItem.Accessible.name.indexOf("Today"), 0)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Return)
      compare(screen.view, "upcoming")
    }
    function test_deleting_a_list_says_what_moves() {
      compare(screen.listContents("Infra"), "2 open and 1 done to-dos")
      compare(screen.listContents("Feature"), "1 open and 1 done to-dos")
      screen.openListMenu("Infra")
      waitForRendering(screen)
      verify(find(screen, "Its 2 open and 1 done to-dos move to the Inbox") !== null, "the menu says it before you delete")
      keyClick(Qt.Key_Escape)
      screen.deleteList("Infra")
      tryCompare(screen, "toast", "Infra deleted. Its 2 open and 1 done to-dos are in the Inbox.")
    }
    function test_a_list_that_cannot_be_made_keeps_its_name() {
      root.listFails = "A list called Dev is already in the file"
      screen.makingList = true
      waitForRendering(screen)
      keyClick(Qt.Key_D); keyClick(Qt.Key_E); keyClick(Qt.Key_V)
      keyClick(Qt.Key_Return)
      tryCompare(screen, "listError", "A list called Dev is already in the file.")
      verify(screen.makingList, "the field stays open")
      verify(find(screen, "A list called Dev is already in the file.") !== null, "with why under it")
      root.listFails = ""
      keyClick(Qt.Key_S)
      keyClick(Qt.Key_Return)
      tryVerify(function() { return !screen.makingList })
      compare(screen.listError, "")
      verify(writes().indexOf("todos new-list devs") >= 0, "and is made once it can be")
    }
    function test_a_read_failure_shows_instead_of_the_old_rows() {
      root.readFails = "could not read /tmp/To-dos.md: Permission denied"
      screen.reload(); wait(30)
      compare(texts(), [], "no rows from before")
      compare(screen.lists, [])
      verify(find(screen, "To-dos.md could not be read.") !== null)
      verify(find(screen, "could not read /tmp/To-dos.md: Permission denied") !== null)
      root.readFails = ""
      screen.reload(); wait(30)
      compare(screen.loadError, "")
    }
    function test_the_field_says_where_and_when() {
      var input = null
      ;(function look(item) { if (item.Accessible && item.Accessible.name === "Type a to-do") input = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(screen)
      screen.select("today", "")
      compare(input.placeholderText, "or type a to-do for Infra, due today")
      root.lists = []; root.list = Fixtures.FLAT
      screen.reload(); wait(30)
      compare(input.placeholderText, "or type a to-do, due today", "without lists, still says when")
      root.list = []
      screen.reload(); wait(30)
      compare(screen.emptyBody, "Hold " + app.todoShortcut + " in any app and say what you need to do. Talk or type below and it's due today. Say several things at once and each gets its own line.", "the first visit says how")
    }
    function test_a_move_waits_for_spoken_to_dos() {
      var sheet = null
      for (var i = 0; i < screen.children.length; i++) if (String(screen.children[i]).indexOf("Sheet_") === 0) sheet = screen.children[i]
      sheet.open = true
      tryVerify(function() { return sheet.opacity === 1 })
      sheet.editingFolder = true
      sheet.useFolder("~/Notes")
      try {
        app.applyState(JSON.stringify(Fixtures.state("todos-talking", Fixtures.NOW)))
        verify(find(sheet, "Finish the to-dos you are recording first.") !== null)
        compare(pill(sheet, "Move them", "primary").enabled, false)
        compare(pill(sheet, "Don't move them", "fill").enabled, false, "the to-dos being said would land in one folder or the other")
        var state = Fixtures.state("todos-talking", Fixtures.NOW)
        state.phase = "processing"
        app.applyState(JSON.stringify(state))
        verify(find(sheet, "Wait until the to-dos are added.") !== null, "and while they are added")
        compare(pill(sheet, "Move them", "primary").enabled, false)
      } finally {
        app.applyState(JSON.stringify(Fixtures.state("todos-list", Fixtures.NOW)))
      }
      verify(find(sheet, "If you don't move them, they stay in ~/Documents/To-dos and this page shows the To-dos.md in ~/Notes.") !== null)
      compare(pill(sheet, "Move them", "primary").enabled, true)
      compare(pill(sheet, "Don't move them", "fill").enabled, true)
      sheet.open = false
      tryVerify(function() { return !sheet.visible })
    }
    function test_a_new_folder_asks_before_it_moves_the_to_dos() {
      var sheet = null
      for (var i = 0; i < screen.children.length; i++) if (String(screen.children[i]).indexOf("Sheet_") === 0) sheet = screen.children[i]
      sheet.open = true
      tryVerify(function() { return sheet.opacity === 1 })
      sheet.editingFolder = true
      sheet.useFolder("~/Notes")
      verify(find(sheet, "Move your to-dos to ~/Notes?") !== null, "the consequence first")
      verify(find(sheet, "If you don't move them, they stay in ~/Documents/To-dos and this page shows the To-dos.md in ~/Notes.") !== null)
      compare(pill(sheet, "Done", "primary"), null, "and no Done to drop the question")
      compare(writes(), [], "and nothing moves until you say")
      root.moveFails = "To-dos.md already exists in ~/Notes. Nothing was moved. Move or rename it there, or choose another folder."
      waitForRendering(sheet)
      mouseClick(pill(sheet, "Move them", "primary"))
      compare(writes(), ["todos move-folder ~/Notes"])
      tryVerify(function() { return find(sheet, root.moveFails) !== null }, 1000, "why, where it was asked")
      verify(pill(sheet, "Move them", "primary") !== null, "moving stays the way on, once it is fixed")
      verify(pill(sheet, "Don't move them", "fill") !== null)
      root.moveFails = ""
      root.sent = []
      waitForRendering(sheet)
      mouseClick(pill(sheet, "Move them", "primary"))
      tryVerify(function() { return find(sheet, "Moved your to-dos to ~/Notes.") !== null })
      compare(writes()[0], "todos move-folder ~/Notes")
      compare(writes()[1], "configure todos_folder \"~/Notes\"", "then the daemon gets the folder")
      root.sent = []
      sheet.editingFolder = true
      sheet.useFolder("~/Elsewhere")
      waitForRendering(sheet)
      mouseClick(pill(sheet, "Don't move them", "fill"))
      compare(writes(), ["configure todos_folder \"~/Elsewhere\""], "nothing moves")
      verify(find(sheet, "Your to-dos stay in ~/Documents/To-dos.") !== null)
      verify(pill(sheet, "Done", "primary") !== null, "Done is back once the folder step is over")
      sheet.open = false
      tryVerify(function() { return !sheet.visible })
    }
    function test_the_picker_takes_the_keyboard_and_esc_closes_it() {
      screen.menuTodo = screen.rows[0].todo
      var duePicker = picker()
      duePicker.date = "2026-09-25"; duePicker.time = ""; duePicker.reminder = ""
      duePicker.open = true
      tryVerify(function() { return screen.Window.activeFocusItem && screen.Window.activeFocusItem.Accessible.name === "Friday, 25 September 2026, today" }, 1000, "the chosen day has the keyboard")
      keyClick(Qt.Key_Escape)
      verify(!duePicker.open)
      duePicker.open = true
      var day = null
      ;(function look(item) { if (item.Accessible && item.Accessible.name === "Monday, 28 September 2026") day = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(duePicker)
      wait(20)
      day.forceActiveFocus()
      keyClick(Qt.Key_Escape)
      verify(!duePicker.open, "Esc closes it from a day too")
      compare(writes(), [])
    }
    function test_tab_stays_in_the_picker_and_the_menu() {
      screen.menuTodo = screen.rows[0].todo
      var duePicker = picker()
      duePicker.date = "2026-09-25"; duePicker.time = "15:00"; duePicker.reminder = ""
      duePicker.open = true
      tryVerify(function() { return screen.Window.activeFocusItem && screen.Window.activeFocusItem.Accessible.name === "Friday, 25 September 2026, today" })
      function inside(item, top) { for (var at = item; at; at = at.parent) if (at === top) return true; return false }
      for (var i = 0; i < 30; i++) {
        keyClick(Qt.Key_Tab)
        verify(inside(screen.Window.activeFocusItem, duePicker), "Tab " + (i + 1) + " is still in the picker")
      }
      keyClick(Qt.Key_Backtab)
      verify(inside(screen.Window.activeFocusItem, duePicker), "and Shift+Tab")
      keyClick(Qt.Key_Escape)
      verify(!duePicker.open)
      var menu = null
      for (i = 0; i < screen.children.length; i++) if (String(screen.children[i]).indexOf("PopupMenu") === 0 && String(screen.children[i].name).indexOf("Move, edit or delete") === 0) menu = screen.children[i]
      menu.anchorItem = screen
      menu.open = true
      tryVerify(function() { return screen.Window.activeFocusItem && screen.Window.activeFocusItem.Accessible.name === "Inbox" })
      compare(menu.name, "Move, edit or delete \u201c" + screen.menuTodo.text + "\u201d", "the menu says what it is for")
      for (i = 0; i < 4; i++) keyClick(Qt.Key_Tab)
      verify(inside(screen.Window.activeFocusItem, menu), "Tab stays in the menu")
      keyClick(Qt.Key_Escape)
      verify(!menu.open)
    }
    function test_a_reminder_set_by_hand_moves_with_the_time() {
      screen.menuTodo = screen.rows[0].todo
      var duePicker = picker()
      duePicker.date = "2026-09-25"; duePicker.time = "17:00"; duePicker.reminder = "2026-09-25 16:20"
      duePicker.open = true
      compare(duePicker.remind, "keep")
      compare(duePicker.kept, "2026-09-25 16:20", "as set while the time stays")
      var field = null
      ;(function look(item) { if (item.Accessible && item.Accessible.name === "Time, such as 15:00 or 3pm") field = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(duePicker)
      field.text = "18:00"
      compare(duePicker.kept, "2026-09-25 17:20", "forty minutes before the new time, as the list will set it")
      verify(find(duePicker, "At 17:20") !== null)
      duePicker.open = false
    }
    function test_the_last_deleted_to_do_of_a_view_is_not_an_empty_page() {
      screen.select("today", "")
      var todo = screen.navigable[0]
      root.list = Fixtures.TODOS.filter(function(t) { return !(t.due && t.due <= Fixtures.TODAY) })
      screen.reload(); wait(30)
      screen.pending = { kind: "delete", items: [todo], view: "today", slot: 0 }
      verify(!screen.rows.some(function(r) { return r.kind === "empty" }), "no Nothing due today under a to-do Undo can bring back")
      compare(screen.rows[1].label, "Deleted", "and the Undo bar says what happened")
      screen.pending = null
      verify(screen.rows.some(function(r) { return r.kind === "empty" }))
    }
    function test_clicking_away_from_a_name_in_error_keeps_the_old_one() {
      root.listFails = "A list called Dev is already in the file"
      screen.makingList = true
      waitForRendering(screen)
      keyClick(Qt.Key_D); keyClick(Qt.Key_E); keyClick(Qt.Key_V)
      keyClick(Qt.Key_Return)
      tryCompare(screen, "listError", "A list called Dev is already in the file.")
      screen.focusKeys()
      verify(!screen.makingList, "the field closes")
      compare(screen.listError, "")
    }
    function test_tab_reaches_the_file_and_the_done_fold() {
      screen.focusKeys()
      var names = []
      for (var i = 0; i < 14; i++) { keyClick(Qt.Key_Tab); names.push(screen.Window.activeFocusItem.Accessible.name) }
      verify(names.indexOf("Open To-dos.md in your editor") >= 0, "the file")
      screen.focusKeys()
      for (i = 0; i < 14 && screen.Window.activeFocusItem.Accessible.name !== "Show done"; i++) keyClick(Qt.Key_Tab)
      compare(screen.Window.activeFocusItem.Accessible.name, "Show done", "the Done fold")
      keyClick(Qt.Key_Space)
      verify(screen.doneShown)
      tryCompare(screen.Window.activeFocusItem.Accessible, "name", "Hide done", 1000, "the keyboard stays on it")
      keyClick(Qt.Key_Return)
      verify(!screen.doneShown)
    }
    function test_a_read_failure_says_what_to_do() {
      screen.loadError = "could not read /tmp/To-dos.md: Permission denied"
      compare(screen.emptyTitle, "To-dos.md could not be read.")
      compare(screen.emptyBody, "Check that you can read the file, or choose another folder under \u22ef, Reminders and folder.")
      screen.loadError = ""
    }
    function test_a_write_that_finds_the_file_changed_says_to_try_again() {
      compare(screen.writeError("That to-do is no longer in the list"), "That to-do changed in To-dos.md. The page is up to date now, so try again.")
      compare(screen.writeError("Those to-dos are no longer in the list"), "Those to-dos changed in To-dos.md. The page is up to date now, so try again.")
      compare(screen.writeError("could not write /tmp/To-dos.md: disk full"), "Could not write /tmp/To-dos.md: disk full.")
      compare(screen.writeError("Those to-dos are no longer in the list", { text: "Buy oat milk" }),
        "\u201cBuy oat milk\u201d changed in To-dos.md. The page is up to date now, so try again.", "one to-do is named")
      compare(screen.writeError("That list is no longer in the file", { text: "Buy oat milk" }), "That list changed in To-dos.md. The page is up to date now, so try again.")
    }
    function test_the_all_subtitle_counts_lists_by_number() {
      screen.select("all", "")
      tryVerify(function() { return screen.subtitle.indexOf(" open in ") > 0 })
      var lists = screen.openLists
      compare(screen.subtitle, screen.openCount + " open in " + lists + (lists === 1 ? " list" : " lists"))
      screen.select("today", "")
    }
    function test_a_new_date_out_of_sight_says_where_it_went() {
      screen.select("today", "")
      screen.reload(); wait(30)
      var todo = screen.rows[0].todo
      screen.setDue(todo, "2026-09-26")
      wait(30)
      compare(screen.toast, "Due tomorrow" + (todo.time ? " at " + todo.time : ""))
      screen.toast = ""
      screen.setDue(todo, "")
      wait(30)
      compare(screen.toast, "No date now. It's in " + (todo.list || "the Inbox") + ".", "and where it is now")
      screen.toast = ""
    }
    function test_the_picker_says_when_a_reminder_has_passed() {
      var duePicker = picker()
      duePicker.date = "2026-09-25"; duePicker.time = "18:00"; duePicker.reminder = ""
      duePicker.open = true
      verify(find(duePicker, "That time has passed, so it reminds you as soon as you set it.") !== null, "18:00 less 15 minutes is before 18:42")
      duePicker.open = false
      duePicker.date = "2026-09-25"; duePicker.time = "20:00"
      duePicker.open = true
      compare(find(duePicker, "That time has passed, so it reminds you as soon as you set it."), null)
      duePicker.open = false
    }
    function test_ctrl_z_in_the_empty_field_undoes_the_delete() {
      screen.select("today", "")
      screen.reload(); wait(30)
      var todo = screen.rows[0].todo
      screen.remove(todo)
      wait(30)
      var field = null
      ;(function look(item) { if (item.Accessible && item.Accessible.name === "Type a to-do") field = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(screen)
      field.forceActiveFocus()
      root.sent = []
      keyClick(Qt.Key_Z, Qt.ControlModifier)
      compare(writes(), ["todos restore"], "the field has nothing to undo, so the page's Undo runs")
      compare(screen.pending, null)
    }
    function test_the_edit_field_has_the_row_to_itself() {
      screen.select("today", "")
      screen.reload(); wait(30)
      var todo = screen.rows[0].todo
      verify(find(screen, "Infra") !== null, "the list badge, before editing")
      screen.startEdit(todo)
      wait(20)
      var row = null
      row = rowsOf(screen).filter(function(r) { return r.editing })[0]
      compare(find(row, "Infra"), null, "no badge over the words being edited")
      screen.editingIndex = -1
    }
    function test_menu_items_tell_assistive_tech_their_detail_and_state() {
      screen.openListMenu("Dev")
      var item = null
      ;(function look(node) { if (node.Accessible && node.Accessible.name === "Delete list") item = node; for (var i = 0; i < node.children.length; i++) look(node.children[i]) })(screen)
      verify(item.Accessible.description.indexOf("to the Inbox") > 0)
      wait(20)
      keyClick(Qt.Key_Escape)
    }
  }
}
