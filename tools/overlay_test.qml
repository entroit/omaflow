// The finished cards: the Esc ring counts down and closes, pointing at a card
// stops its clock, and the to-dos card edits and takes out its to-dos in place.
//   qmltestrunner -input tools/overlay_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
import "preview/Fixtures.js" as Fixtures

Item {
  id: root
  width: 720; height: 400
  property var sent: []
  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    host: QtObject {
      function spawn(argv, callback) {
        var args = argv.slice(1)
        root.sent.push(args.join(" "))
        var reply = args[0] === "todos" ? JSON.stringify({ lists: Fixtures.LISTS, todos: [] }) : "{}"
        if (callback) Qt.callLater(function() { callback(reply, "", 0) })
      }
      function copy(text) {}
      function showWindow(page) { root.sent.push("show " + page) }
    }
  }
  OverlayCard { id: card; app: app; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 60 }

  function show(mode) { app.applyState(JSON.stringify(Fixtures.state(mode, Fixtures.NOW))) }
  function commands() { return root.sent.filter(function(line) { return line.indexOf("todos list") < 0 }) }
  function find(item, test) {
    if (item.visible && test(item)) return item
    for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i], test); if (f) return f }
    return null
  }
  function text(value) { return find(card, function(item) { return item.text === value }) }
  function ring() { return find(card, function(item) { return item.Accessible.name === "Close" }) }

  TestCase {
    name: "Overlay"
    when: windowShown
    function init() {
      show("overlay-todos-saved")
      wait(350)  // past the card's reshape, as a person would be
      mouseMove(root, 5, 5)
      root.sent = []
    }

    function test_the_ring_fills_as_the_time_runs_out() {
      verify(card.elapsed > 0.25 && card.elapsed < 0.6, "about a third gone: " + card.elapsed)
      var before = card.elapsed
      wait(300)
      verify(card.elapsed > before, "and it keeps filling")
    }
    function test_the_ring_closes_the_card() {
      mouseClick(ring())
      compare(commands(), ["dismiss"])
    }
    function test_cards_you_can_act_on_have_the_ring() {
      ["overlay-result", "overlay-error", "overlay-journal-saved"].forEach(function(mode) {
        show(mode); wait(20)
        verify(ring() !== null, mode)
      })
      // Nothing to act on: they just go.
      ;["overlay-success", "overlay-notice"].forEach(function(mode) {
        show(mode); wait(20)
        verify(ring() === null, mode)
      })
    }
    function test_pointing_at_the_card_stops_the_clock() {
      mouseMove(text("Rotate the deploy key"))
      tryCompare(card, "hold", "hover")
      compare(commands(), ["card-hold"])
      mouseMove(root, 5, 5)
      tryCompare(card, "hold", "")
      compare(commands(), ["card-hold", "card-resume"])
    }
    function test_a_to_do_is_edited_in_place() {
      var item = text("Rotate the deploy key")
      mouseClick(item)
      compare(card.hold, "edit", "Esc cannot close the card mid-edit")
      waitForRendering(card)
      keyClick(Qt.Key_Space); keyClick(Qt.Key_N); keyClick(Qt.Key_O); keyClick(Qt.Key_W)
      keyClick(Qt.Key_Return)
      compare(card.editingIndex, -1)
      verify(commands().indexOf("todo-card-edit " + Fixtures.TODOS[4].index + " Rotate the deploy key Rotate the deploy key now") >= 0, commands().join(" | "))
    }
    function test_esc_drops_an_edit_and_keeps_the_card() {
      mouseClick(text("Rotate the deploy key"))
      waitForRendering(card)
      keyClick(Qt.Key_X)
      keyClick(Qt.Key_Escape)
      compare(card.editingIndex, -1)
      compare(card.hold, "edit", "held a moment longer, past the Esc binding")
      tryVerify(function() { return card.hold !== "edit" }, 1000)
      verify(commands().every(function(line) { return line.indexOf("todo-card-edit") < 0 }), "nothing changed")
    }
    function test_x_takes_one_to_do_out() {
      var item = text("Rotate the deploy key")
      mouseMove(item)
      var remove = find(card, function(i) { return i.Accessible.name === "Take out Rotate the deploy key" && i.opacity > 0 })
      verify(remove !== null)
      mouseClick(remove)
      verify(commands().indexOf("todo-card-remove " + Fixtures.TODOS[4].index + " Rotate the deploy key") >= 0, commands().join(" | "))
    }
    function test_a_kept_recording_can_be_tried_again() {
      show("overlay-error-kept"); wait(350)
      mouseClick(text("Try again"))
      compare(commands(), ["retry"])
      show("overlay-error"); wait(350)
      verify(text("Try again") === null, "nothing kept, nothing to try again")
    }
    function test_more_than_six_say_how_many_more() {
      var state = Fixtures.state("overlay-todos-saved", Fixtures.NOW)
      var many = []
      for (var i = 0; i < 9; i++) many.push({ index: i, text: "Task " + (i + 1), done: false, list: "Infra" })
      state.todos_saved = { items: many, moved: false }
      app.applyState(JSON.stringify(state)); wait(20)
      verify(text("Task 6") !== null && text("Task 7") === null)
      verify(text("and 3 more") !== null)
    }
  }
}
