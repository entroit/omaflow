// The Hotkeys table, recorded the way it is used: the daemon republishes its
// state every second, and a row's recorder must survive that mid-press. Also
// the other settings that record keys, send what you typed, or switch the voice
// threshold, and what the window says when Start or Restart fails.
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
  property string replyError: ""
  property int replyCode: 0

  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    pluginDir: "/plugin"
    host: QtObject {
      function spawn(argv, callback, input) {
        root.spawned.push(argv)
        root.inputs.push(input || "")
        if (callback) Qt.callLater(function() { callback(root.reply, root.replyError, root.replyCode) })
      }
      function copy(text) {}
    }
    Component.onCompleted: applyState(JSON.stringify(Fixtures.state("history", Fixtures.NOW)))
  }
  SettingsHotkeys { id: page; width: 660; app: app }
  SettingsBasics { id: basics; y: 600; width: 660; app: app }
  SettingsWords { id: words; y: 1200; width: 660; app: app }
  EndpointTester { id: tester; y: 1800; app: app; cleanupTest: true }
  // Its own state, which nothing republishes, so a switched setting stays.
  App {
    id: audioApp
    host: QtObject { function spawn(argv, callback, input) { root.spawned.push(argv) } }
  }
  SettingsAudio { id: audio; y: 2400; width: 660; app: audioApp }
  SettingsOwnModel { id: own; y: 3000; width: 660; app: app }
  SettingsPrivacy { id: privacy; y: 3600; width: 660; app: audioApp }
  // A daemon one state version behind this window, which nothing republishes.
  App {
    id: olderApp
    Component.onCompleted: {
      var state = Fixtures.state("history", Fixtures.NOW)
      state.state_version = 3
      applyState(JSON.stringify(state))
    }
  }
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

  function first(item, type) {
    if (String(item).indexOf(type) === 0) return item
    for (var i = 0; i < item.children.length; i++) { var found = first(item.children[i], type); if (found) return found }
    return null
  }

  TestCase {
    name: "HotkeysTable"
    when: windowShown
    function test_basics_records_the_dictation_keys_in_place() {
      root.spawned = []
      root.reply = '{"ok": true, "message": "saved"}'
      basics.recordingHold = true
      var recorder = first(basics, "KeyRecorder")
      tryVerify(function() { return recorder.listening })
      // Test key events carry no keysym, so the chord is handed over as recorded.
      recorder.value = ["F8"]
      recorder.recorded()
      tryVerify(function() { return root.spawned.length > 0 })
      compare(root.spawned[0].slice(1).join(" "), "/plugin/tools/set_hotkey.py --keys F8 --consumed ")
      tryCompare(basics, "recordingHold", false)
    }
    function test_a_word_already_there_keeps_what_was_typed() {
      root.spawned = []
      var field = first(words, "Field")
      field.text = "hyprland"
      field.accepted()
      compare(field.text, "hyprland")
      compare(field.problem, "Hyprland is already in your words. To change how it is written, remove it first.")
      compare(root.spawned.length, 0)
      field.text = "Quickshell"
      compare(field.problem, "")
      field.accepted()
      compare(field.text, "")
      compare(root.spawned[0], ["omaflow", "vocabulary-add", "Quickshell"])
    }
    function test_cleanup_test_sends_the_fields_as_typed() {
      root.spawned = []; root.inputs = []
      root.reply = '{"ok": true, "message": "Cleanup answered."}'
      tester.cleanupSettings = { cleanup_engine: "openai", cleanup_model: "m", cleanup_endpoint: "http://127.0.0.1:4000/v1/chat/completions", cleanup_api_key: "sk-secret" }
      tester.check()
      compare(root.spawned[0], ["omaflow", "test-cleanup", "-"])
      verify(root.inputs[0].indexOf("sk-secret") > 0, "the key goes on stdin")
      tryCompare(tester, "status", "Cleanup answered.")
    }
    function test_api_keys_go_on_stdin() {
      root.spawned = []; root.inputs = []
      app.preference("models", { cleanup_model: "m", cleanup_api_key: "sk-secret" })
      compare(root.spawned[0], ["omaflow", "configure", "models", "-"])
      compare(root.inputs[0], '{"cleanup_model":"m","cleanup_api_key":"sk-secret"}\n')
      app.preference("models", { cleanup_model: "m" })
      compare(root.spawned[1], ["omaflow", "configure", "models", '{"cleanup_model":"m"}'])
    }
    function test_voice_threshold_is_automatic_until_switched_off() {
      root.spawned = []
      var meter = first(audio, "Meter")
      var slider = first(meter, "Slider")
      audioApp.meterPreview = true
      var bars = " 0.400".repeat(13)
      audioApp.applyLevel("0.550 -40.0 1" + bars + " -52")
      compare(audioApp.meterGateEffectiveDb, -52)
      compare(meter.thresholdDb, -52, "the marker shows the threshold in use")
      verify(!slider.visible, "the automatic marker can't be dragged")
      // A level line without the threshold keeps the last one.
      audioApp.applyLevel("0.550 -40.0 1" + bars)
      compare(audioApp.meterGateEffectiveDb, -52)

      first(audio, "Toggle").toggled()
      // Setting a threshold turns automatic off in the daemon: one command.
      compare(root.spawned, [["omaflow", "meter-gate", "-52"]], "manual starts from the threshold in use")
      verify(!audioApp.meterGateAuto)
      compare(audioApp.meterGateDb, -52)
      compare(meter.thresholdDb, -52, "the marker stays where it was")
      verify(slider.visible, "the manual marker can be dragged")
      // Switching back on keeps the manual value for next time.
      first(audio, "Toggle").toggled()
      compare(root.spawned[1], ["omaflow", "configure", "meter_gate_auto", "true"])
      compare(audioApp.meterGateDb, -52)
      audioApp.meterPreview = false
    }
    function test_failed_start_and_restart_say_why() {
      var said = []
      function listen(message, error) { said.push([message, error]) }
      app.toast.connect(listen)
      root.reply = ""; root.replyCode = 1
      root.replyError = "The speech model could not be restarted. See: journalctl --user -u omaflow-asr.service"
      app.restartSpeech()
      tryCompare(said, "length", 1)
      compare(said[0][0], "The speech model could not be restarted. See: journalctl --user -u omaflow-asr.service.")
      verify(said[0][1], "shown as an error")
      root.replyError = "omaflow: could not start OmaFlow: systemctl exited with exit status: 5\n"
      app.start()
      tryCompare(said, "length", 2)
      compare(said[1][0], "Could not start OmaFlow: systemctl exited with exit status: 5.")
      root.replyError = ""; root.replyCode = 0
      app.restartSpeech()
      wait(50)
      compare(said.length, 2, "success says nothing")
      app.toast.disconnect(listen)
      root.reply = '{"ok": true, "message": "saved"}'
    }
    function test_partly_updated_links_to_updates() {
      compare(olderApp.statusText, "Partly updated")
      compare(olderApp.statusTone, "red")
      compare(olderApp.statusAction, "updates")
    }
    function test_the_header_says_what_the_card_says_while_processing() {
      olderApp.phase = "processing"
      olderApp.cleanupLevel = "medium"
      compare(olderApp.statusText, "Transcribing and cleaning up")
      olderApp.cleanupLevel = "light"
      compare(olderApp.statusText, "Transcribing")
      olderApp.journalTake = true
      compare(olderApp.statusText, "Writing it down")
      olderApp.journalTake = false
      olderApp.phase = "idle"
    }
    function test_paste_row_offers_add_until_your_own_keys_are_set() {
      // The default Ctrl+V, stored but not chosen, is not your own shortcut.
      compare(app.pasteMode, "auto")
      verify(!app.customPaste)
      var stored = Fixtures.state("history", Fixtures.NOW)
      stored.paste_shortcut = { modifiers: ["ctrl", "shift"], key: "V" }
      olderApp.applyState(JSON.stringify(stored))
      verify(olderApp.customPaste, "a kept shortcut of your own still shows")
    }
    function test_paste_shortcut_is_confirmed_once_saved() {
      root.spawned = []
      page.status = ""
      page.savePaste("CTRL + SHIFT + V")
      compare(root.spawned[0], ["omaflow", "configure", "paste_delivery", '{"mode":"custom","shortcut":{"modifiers":["ctrl","shift"],"key":"V"}}'])
      compare(page.status, "", "nothing is confirmed before the daemon has it")
      var saved = Fixtures.state("history", Fixtures.NOW)
      saved.paste_mode = "custom"
      saved.paste_shortcut = { modifiers: ["ctrl", "shift"], key: "V" }
      app.applyState(JSON.stringify(saved))
      compare(page.status, "Paste shortcut: Ctrl+Shift+V")
      compare(page.pendingPaste, "")
      page.status = ""
    }
    function test_focus_returns_to_change_after_esc() {
      basics.recordingHold = true
      var recorder = first(basics, "KeyRecorder")
      tryVerify(function() { return recorder.listening })
      // The recorder starts on the next turn of the event loop.
      wait(20)
      keyClick(Qt.Key_Escape)
      tryCompare(basics, "recordingHold", false)
      var change = null
      function find(item) {
        if (String(item).indexOf("Pill") === 0 && item.text === "Change" && item.visible) change = change || item
        for (var i = 0; i < item.children.length; i++) find(item.children[i])
      }
      find(basics)
      tryVerify(function() { return change.activeFocus }, 1000, "focus is back on Change")
    }
    function test_own_server_starts_from_an_empty_address() {
      // The saved model is a file, so its address is OmaFlow's own port.
      own.engine = "openai"
      var address = null
      function find(item) {
        if (String(item).indexOf("Field") === 0 && item.label === "Address") address = item
        for (var i = 0; i < item.children.length; i++) find(item.children[i])
      }
      find(own)
      compare(address.text, "")
      compare(address.problem, "", "empty is not wrong before you type")
      compare(own.blocker, "Enter a model name first.")
      verify(!own.ready)
      own.engine = "nemo"
    }
    function test_a_problem_waits_until_you_leave_the_field() {
      var field = null
      function find(item) {
        if (String(item).indexOf("Field") === 0 && item.label === "Language") field = item
        for (var i = 0; i < item.children.length; i++) find(item.children[i])
      }
      find(own)
      var model = null
      function findModel(item) {
        if (String(item).indexOf("Field") === 0 && item.label === "Model file") model = item
        for (var i = 0; i < item.children.length; i++) findModel(item.children[i])
      }
      findModel(own)
      model.text = "/models/my.gguf"
      field.input.forceActiveFocus()
      field.text = "english!"
      verify(field.problem.length > 0)
      compare(field.shownProblem, "", "not while typing")
      compare(own.blocker, "Fix the language first.", "Save says which field")
      field.input.editingFinished()
      compare(field.shownProblem, field.problem, "shown once you leave it")
      field.text = "auto"
      compare(field.shownProblem, "")
      verify(own.ready)
      model.text = ""
    }
    function test_privacy_names_where_dictation_goes() {
      compare(privacy.whereText, "Speech and cleanup run on this computer, with no account and no network.")
      audioApp.modelSettings = { speech_engine: "openai", speech_endpoint: "http://10.0.0.5:8000/v1/audio/transcriptions" }
      compare(privacy.whereText, "Your audio goes to 10.0.0.5:8000 for speech. Cleanup stays on this computer.")
      audioApp.cleanupLevel = "medium"
      audioApp.modelSettings = { speech_endpoint: "http://127.0.0.1:18103/v1/audio/transcriptions", cleanup_endpoint: "https://llm.example.com/v1/chat/completions" }
      compare(privacy.whereText, "Speech runs on this computer. Your raw text and the focused window's title go to llm.example.com for cleanup.")
      audioApp.cleanupLevel = "off"
      audioApp.modelSettings = {}
    }
    function test_a_setting_title_flips_its_switch() {
      root.spawned = []
      var row = null
      function find(item) {
        if (String(item).indexOf("SettingRow") === 0 && item.title === "Training log") row = item
        for (var i = 0; i < item.children.length; i++) find(item.children[i])
      }
      find(privacy)
      privacy.y = 0
      mouseClick(row, 20, 10)
      compare(root.spawned[0], ["omaflow", "configure", "training_log_enabled", "true"])
      privacy.y = 3600
    }
    function test_keep_from_other_apps_is_offered_with_the_row_closed() {
      root.spawned = []
      root.reply = '{"ok": true, "message": "saved"}'
      page.editing = ""
      var chip = null
      function find(item) {
        if (String(item).indexOf("Pill") === 0 && item.text === "F9" && item.hint.indexOf("Hide") === 0 && item.visible) chip = item
        for (var i = 0; i < item.children.length; i++) find(item.children[i])
      }
      find(page)
      verify(chip !== null && chip.visible, "shown under the closed Hold to dictate row")
      verify(chip.activeFocusOnTab, "a tab stop")
      mouseClick(chip)
      tryVerify(function() { return root.spawned.length > 0 })
      compare(root.spawned[0].slice(1).join(" "), "/plugin/tools/set_hotkey.py --keys F9 --consumed F9")
      compare(page.editing, "")
    }
    function test_a_double_click_does_not_erase() {
      root.spawned = []
      var trigger = null
      function find(item) {
        if (String(item).indexOf("Pill") === 0 && item.text === "Delete saved dictations…") trigger = item
        for (var i = 0; i < item.children.length; i++) find(item.children[i])
      }
      find(privacy)
      privacy.y = -privacy.height + 200
      mouseClick(trigger, 4, trigger.height / 2)
      mouseClick(trigger, 4, trigger.height / 2)
      verify(privacy.confirmErase, "still asking")
      compare(root.spawned.length, 0, "nothing erased")
      verify(root.Window.activeFocusItem.text === "Keep it", "focus on Keep it")
      keyClick(Qt.Key_Return)
      verify(!privacy.confirmErase, "Enter keeps")
      compare(root.spawned.length, 0)
      privacy.y = 3600
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
      tryVerify(function() { var item = root.Window.activeFocusItem; return item && item.Accessible.name === "Add Hold for a journal entry shortcut" }, 1000, "focus is back on Add")
      root.reply = '{"ok": true, "message": "saved"}'
    }
  }
}
