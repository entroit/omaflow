// The Hotkeys table, recorded the way it is used: the daemon republishes its
// state every second, and a row's recorder must survive that mid-press.
//   qmltestrunner -input tools/hotkeys_table_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
import "preview/Fixtures.js" as Fixtures

Item {
  id: root
  width: 700; height: 600
  property var spawned: []
  property var inputs: []
  property string reply: '{"ok": true, "message": "Journal entry: Super + Shift + J"}'

  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    pluginDir: "/plugin"
    host: QtObject {
      function spawn(argv, callback, input) {
        root.spawned.push(argv)
        root.inputs.push(input || "")
        if (callback) Qt.callLater(function() { callback(root.reply, "", 0) })
      }
      function copy(text) {}
    }
    Component.onCompleted: applyState(JSON.stringify(Fixtures.state("history", Fixtures.NOW)))
  }
  SettingsHotkeys { id: page; width: 660; app: app }
  // Republish, as the daemon does, faster than a person presses keys.
  Timer { interval: 50; running: true; repeat: true; onTriggered: app.applyState(JSON.stringify(Fixtures.state("history", Fixtures.NOW))) }

  function recorder() {
    function find(item) {
      if (String(item).indexOf("KeyRecorder") === 0 && item.visible) return item
      for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i]); if (f) return f }
      return null
    }
    return find(page)
  }

  TestCase {
    name: "HotkeysTable"
    when: windowShown
    function test_api_keys_go_on_stdin() {
      root.spawned = []; root.inputs = []
      app.preference("models", { cleanup_model: "m", cleanup_api_key: "sk-secret" })
      compare(root.spawned[0], ["omaflow", "configure", "models", "-"])
      compare(root.inputs[0], '{"cleanup_model":"m","cleanup_api_key":"sk-secret"}\n')
      app.preference("models", { cleanup_model: "m" })
      compare(root.spawned[1], ["omaflow", "configure", "models", '{"cleanup_model":"m"}'])
    }
    function test_records_in_the_row_while_state_republishes() {
      root.spawned = []
      page.editing = "journal"
      tryVerify(function() { return recorder() !== null && recorder().listening })
      var first = recorder()
      keyPress(Qt.Key_Meta, Qt.MetaModifier)
      wait(200)
      compare(recorder(), first, "the recorder survives the state being republished")
      keyPress(Qt.Key_Shift, Qt.MetaModifier | Qt.ShiftModifier)
      wait(200)
      keyClick(Qt.Key_J, Qt.MetaModifier | Qt.ShiftModifier)
      keyRelease(Qt.Key_Shift, Qt.MetaModifier)
      keyRelease(Qt.Key_Meta)
      tryVerify(function() { return root.spawned.length > 0 })
      compare(root.spawned[0].slice(1).join(" "), "/plugin/tools/set_hotkey.py --action journal --bind SUPER + SHIFT + J")
      tryCompare(page, "editing", "")
    }
    function test_a_refused_shortcut_keeps_the_row_open() {
      root.reply = '{"ok": false, "message": "Super + Shift + J already controls something"}'
      page.editing = "journal"
      tryVerify(function() { return recorder() !== null && recorder().listening })
      keyClick(Qt.Key_J, Qt.MetaModifier | Qt.ShiftModifier)
      tryVerify(function() { return recorder() !== null && recorder().problem.indexOf("already controls") >= 0 })
      compare(page.editing, "journal")
      verify(recorder().listening, "listening again")
      keyClick(Qt.Key_Escape)
      tryCompare(page, "editing", "")
      root.reply = '{"ok": true, "message": "saved"}'
    }
  }
}
