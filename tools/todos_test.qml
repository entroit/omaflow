// The to-do page against a stubbed file with an Inbox and three lists:
// ticking, deleting and clearing with Undo, the views across lists, where
// typed and spoken to-dos go, moving, dates, and deleting a list.
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
  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    host: QtObject {
      function spawn(argv, callback) {
        var args = argv.slice(1)
        root.sent.push(args.join(" "))
        var reply = args[0] === "todos" && args[1] === "list"
          ? JSON.stringify({ path: "/tmp/To-dos.md", today: Fixtures.TODAY, lists: root.lists, current: "Infra", todos: root.list })
          : args[1] === "new-list" ? JSON.stringify({ list: args[2] })
          : args[1] === "rename-list" ? JSON.stringify({ list: args[3] }) : "{}"
        if (callback) Qt.callLater(function() { callback(reply, "", 0) })
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
  TodosScreen { id: screen; anchors.fill: parent; app: app; active: true }

  function writes() { return root.sent.filter(function(line) { return line.indexOf("todos list") < 0 }) }
  function texts() { return screen.rows.filter(function(r) { return r.kind === "row" && !r.ghost }).map(function(r) { return r.todo.text }) }
  function find(item, text) {
    if (item.text === text && item.visible) return item
    for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i], text); if (f) return f }
    return null
  }

  TestCase {
    name: "Todos"
    when: windowShown
    function init() {
      root.sent = []
      root.list = Fixtures.TODOS
      root.lists = Fixtures.LISTS
      screen.pending = null; screen.settling = []; screen.cursor = -1
      screen.reload(); wait(30)
      screen.select("list", "Infra")
    }

    function test_opens_on_the_current_list_with_done_under_it() {
      compare(screen.title, "Infra")
      compare(texts(), ["Renew the TLS certs on the staging box", "Move the backups to the new bucket, and check that the old ones restore before deleting them", "Rotate the deploy key"])
      verify(screen.rows.some(function(r) { return r.kind === "done" && r.count === 1 }))
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
    function test_the_picker_sets_a_day_and_a_time() {
      screen.select("list", "")
      screen.menuTodo = screen.rows[0].todo
      var duePicker = null
      ;(function look(item) { if (String(item).indexOf("DuePicker") === 0) duePicker = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(screen)
      duePicker.date = "2026-09-25"; duePicker.time = ""
      duePicker.open = true
      waitForRendering(screen)
      mouseClick(find(duePicker, "2"))  // the 2nd of the month it opens on
      var field = null
      ;(function look(item) { if (item.Accessible && item.Accessible.name === "Time, such as 15:00 or 3pm") field = item; for (var i = 0; i < item.children.length; i++) look(item.children[i]) })(duePicker)
      mouseClick(field)
      keyClick(Qt.Key_3); keyClick(Qt.Key_P); keyClick(Qt.Key_M)
      compare(duePicker.typedTime, "15:00")
      keyClick(Qt.Key_Return)
      verify(!duePicker.open, "Enter sets it and closes")
      compare(writes(), ["todos due 0 Call Mira about the lease 2026-09-02 15:00"])
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
        if (String(item).indexOf("TodoRow") === 0 && item.todo.index === todo.index && item.todo.done) return item
        for (var i = 0; i < item.children.length; i++) { var f = doneRow(item.children[i]); if (f) return f }
        return null
      }
      var row = doneRow(screen)
      verify(row !== null)
      verify(!row.editing, "a done to-do is never shown as an edit field")
      verify(find(row, todo.text) !== null, "and shows its words")
    }
  }
}
