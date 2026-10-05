// The shortcut recorder turns pressed keys into what set_hotkey.py saves:
// modifiers and a key, or one key that types nothing.
//   qmltestrunner -input tools/key_recorder_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
Item {
  width: 400; height: 100
  KeyRecorder { id: rec; width: 400; mode: "binding" }
  TestCase {
    name: "KeyRecorder"; when: windowShown
    function test_binding() {
      rec.start()
      verify(rec.listening, "listening after start")
      keyPress(Qt.Key_Meta, Qt.MetaModifier)
      compare(rec.pending, "SUPER + ")
      keyPress(Qt.Key_Shift, Qt.MetaModifier | Qt.ShiftModifier)
      keyClick(Qt.Key_J, Qt.MetaModifier | Qt.ShiftModifier)
      compare(rec.value, "SUPER + SHIFT + J")
      verify(!rec.listening, "done after the key")
      compare(rec.labels.join(" "), "Super Shift J")
    }
    function test_a_key_that_types_nothing_can_stand_alone() {
      rec.value = ""; rec.allowBare = true; rec.start()
      keyClick(Qt.Key_F13)
      compare(rec.value, "F13")
      rec.value = ""; rec.allowBare = false; rec.start()
      keyClick(Qt.Key_F13)
      compare(rec.value, "", "a paste shortcut needs a modifier")
      verify(rec.problem.length > 0)
      keyClick(Qt.Key_Escape)
      rec.allowBare = true
    }
    function test_punctuation_and_altgr() {
      rec.value = ""; rec.start()
      keyClick(Qt.Key_Minus, Qt.MetaModifier)
      compare(rec.value, "SUPER + minus")
      compare(rec.labels.join(" "), "Super -")
      rec.value = ""; rec.start()
      keyPress(Qt.Key_Meta, Qt.MetaModifier)
      keyPress(Qt.Key_AltGr, Qt.MetaModifier)
      keyRelease(Qt.Key_AltGr, Qt.MetaModifier)
      compare(rec.value, "SUPER + ISO_Level3_Shift", "hold Super, tap AltGr")
      compare(rec.labels.join(" "), "Super AltGr")
      keyRelease(Qt.Key_Meta)
    }
    function test_altgr_is_a_modifier() {
      rec.value = ""; rec.start()
      keyPress(Qt.Key_AltGr)
      keyClick(Qt.Key_Period, Qt.GroupSwitchModifier)
      compare(rec.value, "MOD5 + period", "AltGr and a key")
      compare(rec.labels.join(" "), "AltGr .")
      keyRelease(Qt.Key_AltGr)
      verify(!rec.altGr)
    }
    function test_letting_go_of_shift_is_not_a_key() {
      rec.value = ""; rec.start()
      keyPress(Qt.Key_Meta, Qt.MetaModifier)
      keyPress(Qt.Key_Shift, Qt.MetaModifier | Qt.ShiftModifier)
      keyRelease(Qt.Key_Shift, Qt.MetaModifier)
      compare(rec.value, "")
      verify(rec.listening)
      keyClick(Qt.Key_J, Qt.MetaModifier)
      compare(rec.value, "SUPER + J")
      keyRelease(Qt.Key_Meta)
    }
    function test_needs_a_modifier() {
      rec.value = ""; rec.start()
      keyClick(Qt.Key_J)
      compare(rec.value, "")
      verify(rec.problem.length > 0)
      keyClick(Qt.Key_Escape)
      verify(!rec.listening)
    }
  }
}
