// The journal's Talk button: a click starts a hands-free entry that Stop
// saves; holding it records until you let go.
//   qmltestrunner -input tools/journal_talk_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
import "preview/Fixtures.js" as Fixtures

Item {
  id: root
  width: 700; height: 120
  property var sent: []
  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    host: QtObject { function spawn(argv, callback) { root.sent.push(argv.slice(1).join(" ")) } function copy(text) {} }
    Component.onCompleted: applyState(JSON.stringify(Fixtures.state("journal", Fixtures.NOW)))
  }
  JournalComposer { id: composer; width: 660; app: app }
  function talk() {
    function find(item) {
      if (item.text === "Talk" || item.text === "Stop" || item.text === "Let go to save") return item
      for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i]); if (f) return f }
      return null
    }
    return find(composer)
  }
  function recording(on) { app.applyState(JSON.stringify(Fixtures.state(on ? "journal-talking" : "journal", Fixtures.NOW))) }

  TestCase {
    name: "JournalTalk"
    when: windowShown
    function test_click_starts_hands_free_and_stop_saves() {
      root.sent = []
      mouseClick(talk())
      compare(root.sent, ["journal-toggle"], "one click, one hands-free start")
      recording(true)
      wait(20)
      mouseClick(talk())
      compare(root.sent, ["journal-toggle", "journal-toggle"], "Stop saves")
      recording(false)
    }
    function test_hold_records_until_let_go() {
      root.sent = []
      var button = talk()
      mousePress(button)
      compare(root.sent, ["journal-toggle"])
      recording(true)
      wait(450)
      compare(talk().text, "Let go to save")
      mouseRelease(talk())
      compare(root.sent, ["journal-toggle", "journal-toggle"], "letting go saves, and nothing starts again")
      recording(false)
      wait(20)
      mouseClick(talk())
      compare(root.sent.length, 3, "the next click starts a new entry")
    }
  }
}
