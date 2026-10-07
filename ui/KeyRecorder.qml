import QtQuick
import "Keys.js" as KeyNames

// Listens for a shortcut instead of asking for its name. Click it, press the
// keys, and they show as keycaps.
//   binding: modifiers and one key, saved as Hyprland writes it
//            ("SUPER + SHIFT + J")
//   chord:   up to four keys held together, saved as XKB names
//            (["ISO_Level3_Shift", "Menu"]); finished when you let go
// A combination Omarchy already uses never reaches the window, so nothing
// shows for it; the caption says so.
Rectangle {
  id: recorder

  property string mode: "binding"
  // What is recorded: a binding string, or a list of XKB names for a chord.
  property var value: mode === "chord" ? [] : ""
  readonly property bool listening: activeFocus
  property var held: []          // chord keys down right now
  property string problem: ""
  // A binding may be one key alone if that key types nothing, such as F13;
  // a paste shortcut always needs a modifier.
  property bool allowBare: true
  // Backspace turns the shortcut off, where it may be off.
  property bool allowClear: false
  signal recorded()
  // Esc, or clicking elsewhere, before anything was recorded.
  signal cancelled()
  signal cleared()
  property bool finished: false
  // Set when Esc, Backspace or the keys themselves ended it, so the caller
  // can put focus back on the button that opened it.
  property bool endedByKey: false

  function start() { problem = ""; finished = false; endedByKey = false; forceActiveFocus() }
  function stop() { endedByKey = true; focus = false }

  implicitHeight: 34
  radius: height / 2
  color: listening ? Theme.fill8 : Theme.fill4
  border.width: 1
  border.color: listening ? Theme.accent : Theme.outline
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: listening ? "Listening for a shortcut. Press the keys." : "Record a shortcut"

  // ------------------------------------------------------------- key names
  // XKB names for the keys a chord is likely to use, by keysym.
  readonly property var keysyms: ({
    0xfe03: "ISO_Level3_Shift", 0xff67: "Menu", 0xffe1: "Shift_L", 0xffe2: "Shift_R",
    0xffe3: "Control_L", 0xffe4: "Control_R", 0xffe9: "Alt_L", 0xffea: "Alt_R",
    0xffeb: "Super_L", 0xffec: "Super_R", 0xffe5: "Caps_Lock", 0xff13: "Pause",
    0xff14: "Scroll_Lock", 0xff61: "Print", 0xff63: "Insert", 0xff50: "Home", 0xff57: "End",
    0xff55: "Prior", 0xff56: "Next", 0xff1b: "Escape", 0x20: "space"
  })
  function xkbName(event) {
    var sym = event.nativeVirtualKey
    if (keysyms[sym]) return keysyms[sym]
    if (sym >= 0xffbe && sym <= 0xffd5) return "F" + (sym - 0xffbe + 1)
    if (sym >= 0x61 && sym <= 0x7a) return String.fromCharCode(sym)
    if (sym >= 0x41 && sym <= 0x5a) return String.fromCharCode(sym + 32)
    if (sym >= 0x30 && sym <= 0x39) return String.fromCharCode(sym)
    return ""
  }
  // The key of a binding, the way Hyprland names it.
  function bindingKey(event) {
    var k = event.key
    if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)
    if (k >= Qt.Key_F1 && k <= Qt.Key_F24) return "F" + (k - Qt.Key_F1 + 1)
    // The number row, whatever Shift turns it into.
    var code = event.nativeScanCode
    if (code >= 10 && code <= 19) return String((code - 9) % 10)
    var named = {}
    named[Qt.Key_Space] = "space"; named[Qt.Key_Return] = "Return"; named[Qt.Key_Tab] = "Tab"
    named[Qt.Key_Left] = "Left"; named[Qt.Key_Right] = "Right"; named[Qt.Key_Up] = "Up"; named[Qt.Key_Down] = "Down"
    named[Qt.Key_Home] = "Home"; named[Qt.Key_End] = "End"; named[Qt.Key_Insert] = "Insert"
    named[Qt.Key_PageUp] = "Prior"; named[Qt.Key_PageDown] = "Next"; named[Qt.Key_Print] = "Print"
    named[Qt.Key_Menu] = "Menu"; named[Qt.Key_Pause] = "Pause"; named[Qt.Key_ScrollLock] = "Scroll_Lock"
    // Punctuation, by the character it types, then by keysym for anything
    // else a keyboard has (German ß, ä, ö, ü and so on).
    named[Qt.Key_Minus] = "minus"; named[Qt.Key_Equal] = "equal"; named[Qt.Key_Comma] = "comma"
    named[Qt.Key_Period] = "period"; named[Qt.Key_Slash] = "slash"; named[Qt.Key_Semicolon] = "semicolon"
    named[Qt.Key_Apostrophe] = "apostrophe"; named[Qt.Key_BracketLeft] = "bracketleft"
    named[Qt.Key_BracketRight] = "bracketright"; named[Qt.Key_Backslash] = "backslash"
    named[Qt.Key_QuoteLeft] = "grave"; named[Qt.Key_Plus] = "plus"; named[Qt.Key_NumberSign] = "numbersign"
    named[Qt.Key_Less] = "less"; named[Qt.Key_ssharp] = "ssharp"; named[Qt.Key_Adiaeresis] = "adiaeresis"
    named[Qt.Key_Odiaeresis] = "odiaeresis"; named[Qt.Key_Udiaeresis] = "udiaeresis"
    return named[k] || KeyNames.BY_KEYSYM[event.nativeVirtualKey] || ""
  }
  // A modifier key's own name, for a shortcut that ends with one: Super + AltGr.
  function modifierKeyName(event) {
    var name = KeyNames.MODIFIER_BY_KEYSYM[event.nativeVirtualKey]
    if (name) return name
    var byKey = {}
    byKey[Qt.Key_AltGr] = "ISO_Level3_Shift"; byKey[Qt.Key_Shift] = "Shift_L"; byKey[Qt.Key_Control] = "Control_L"
    byKey[Qt.Key_Alt] = "Alt_L"; byKey[Qt.Key_Meta] = "Super_L"; byKey[Qt.Key_Super_L] = "Super_L"; byKey[Qt.Key_Super_R] = "Super_R"
    return byKey[event.key] || ""
  }
  // Set while a modifier is pressed on top of another and nothing else yet:
  // letting it go makes it the shortcut's last key.
  property string lone: ""
  property var loneModifiers: []
  // Keys that type nothing, so binding one alone takes nothing away.
  function typesNothing(key) {
    return /^F[0-9]+$/.test(key) || ["Menu", "Pause", "Print", "Insert", "Scroll_Lock"].indexOf(key) >= 0
  }
  function isModifier(key) {
    return [Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_AltGr].indexOf(key) >= 0
  }
  // The modifier a modifier key stands for. Whether a key's own press already
  // counts in `modifiers` differs between platforms, so it is added by hand.
  function modifierOf(key) {
    if (key === Qt.Key_Shift) return Qt.ShiftModifier
    if (key === Qt.Key_Control) return Qt.ControlModifier
    if (key === Qt.Key_Alt) return Qt.AltModifier
    if (key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R) return Qt.MetaModifier
    if (key === Qt.Key_AltGr) return Qt.GroupSwitchModifier
    return 0
  }
  function pendingFor(modifiers) {
    var names = modifierNames(modifiers)
    return names.length > 0 ? names.join(" + ") + " + " : ""
  }
  // AltGr, which Hyprland calls MOD5, while it is held.
  property bool altGr: false
  function isAltGr(event) { return event.key === Qt.Key_AltGr || event.nativeVirtualKey === 0xfe03 }
  function modifierNames(modifiers) {
    var names = []
    if (modifiers & Qt.MetaModifier) names.push("SUPER")
    if (modifiers & Qt.ControlModifier) names.push("CTRL")
    if (modifiers & Qt.AltModifier) names.push("ALT")
    if (altGr || (modifiers & Qt.GroupSwitchModifier)) names.push("MOD5")
    if (modifiers & Qt.ShiftModifier) names.push("SHIFT")
    return names
  }
  // Keycap labels for what is shown.
  readonly property var labels: {
    if (mode === "chord") {
      var keys = held.length > 0 ? held : value
      return keys.map(KeyNames.label)
    }
    return KeyNames.labels(pending.length > 0 ? pending : String(value || ""))
  }
  property string pending: ""    // modifiers held so far, "SUPER + SHIFT + "

  // ------------------------------------------------------------- listening
  Keys.onPressed: function(event) {
    // Tab and Shift+Tab, with nothing else held, leave the recorder as they
    // leave any control; leaving cancels, like Esc.
    var shiftOnly = held.every(function(key) { return key.indexOf("Shift") === 0 })
    if ((event.key === Qt.Key_Tab && event.modifiers === Qt.NoModifier && held.length === 0)
        || (event.key === Qt.Key_Backtab && (event.modifiers & ~Qt.ShiftModifier) === 0 && shiftOnly)) {
      event.accepted = false
      return
    }
    event.accepted = true
    if (event.isAutoRepeat) return
    problem = ""
    if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier && held.length === 0) { finished = true; stop(); cancelled(); return }
    if (event.key === Qt.Key_Backspace && event.modifiers === Qt.NoModifier && held.length === 0 && allowClear) { finished = true; stop(); cleared(); return }
    if (mode === "chord") {
      var name = xkbName(event)
      if (!name) { problem = "That key can't be part of the dictation keys. Try F9, F13, Menu or AltGr."; return }
      if (held.indexOf(name) < 0 && held.length < 4) held = held.concat([name])
      return
    }
    if (isModifier(event.key) || isAltGr(event)) {
      var others = modifierNames(event.modifiers & ~modifierOf(event.key))
      if (isAltGr(event)) altGr = true
      // Only keys people use as keys: AltGr and the right-hand modifiers. A
      // left Shift let go before the letter is a change of mind, not a key.
      var name = modifierKeyName(event)
      lone = others.length > 0 && ["ISO_Level3_Shift", "Alt_R", "Control_R", "Super_R", "Shift_R"].indexOf(name) >= 0 ? name : ""
      loneModifiers = others
      pending = pendingFor(event.modifiers | modifierOf(event.key))
      return
    }
    lone = ""
    var modifiers = modifierNames(event.modifiers)
    // With AltGr, or Shift on a key that isn't a letter or digit, the key
    // types another character. Record the physical key; set_hotkey.py names
    // it in your layout, the way Hyprland matches it.
    var letterOrDigit = (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) || (event.nativeScanCode >= 10 && event.nativeScanCode <= 19)
    var changed = modifiers.indexOf("MOD5") >= 0 || ((event.modifiers & Qt.ShiftModifier) && !letterOrDigit && event.text.length > 0)
    var key = changed && event.nativeScanCode > 0 ? "code:" + event.nativeScanCode : bindingKey(event)
    if (!key) {
      problem = (event.modifiers & Qt.ShiftModifier) && event.text.length > 0
        ? "Shift changes what that key types, so it can't be matched. Use Super, Ctrl or Alt with it instead."
        : "That key can't be used in a shortcut. Try a letter, a number, punctuation or F1 to F24."
      return
    }
    if (modifiers.length === 0 && !(allowBare && typesNothing(key))) {
      problem = allowBare
        ? "On its own, the " + KeyNames.label(key) + " key would stop typing in every app. Hold Super, Shift, Ctrl or Alt with it, or use a key that types nothing, such as F13."
        : "Hold Super, Shift, Ctrl or Alt with the key."
      return
    }
    pending = ""
    value = modifiers.concat([key]).join(" + ")
    finished = true
    recorded()
    stop()
  }
  Keys.onReleased: function(event) {
    event.accepted = true
    if (event.isAutoRepeat) return
    if (mode === "chord") {
      // The chord is every key that was down together; it is done when the
      // first key comes up.
      if (held.length > 0) {
        value = held
        held = []
        finished = true
        recorded()
        stop()
      }
      return
    }
    if (isModifier(event.key) || isAltGr(event)) {
      if (isAltGr(event)) altGr = false
      // Hold Super, tap AltGr: AltGr is the key.
      if (lone.length > 0 && modifierKeyName(event) === lone) {
        value = loneModifiers.concat([lone]).join(" + ")
        lone = ""
        pending = ""
        finished = true
        recorded()
        stop()
        return
      }
      pending = pendingFor(event.modifiers & ~modifierOf(event.key))
    }
  }
  onActiveFocusChanged: if (!activeFocus) {
    altGr = false
    pending = ""
    held = []
    // Clicking elsewhere cancels, like Esc.
    if (!finished) { finished = true; cancelled() }
  }

  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (!recorder.listening) recorder.start() }

  Row {
    id: caps
    x: 10
    anchors.verticalCenter: parent.verticalCenter
    spacing: 6
    Repeater {
      model: recorder.labels
      Keycap { required property string modelData; anchors.verticalCenter: parent.verticalCenter; compact: true; text: modelData }
    }
  }
  UiText {
    id: prompt
    anchors.left: caps.right
    anchors.leftMargin: recorder.labels.length > 0 ? 10 : 0
    anchors.verticalCenter: parent.verticalCenter
    width: Math.max(0, Math.min(implicitWidth, (keysHintText.visible ? keysHintText.x - 12 : recorder.width - 14) - x))
    elide: Text.ElideRight
    visible: recorder.labels.length === 0 || recorder.listening
    font.pixelSize: 13
    text: !recorder.listening ? "Click, then press the keys"
      : recorder.mode === "chord" ? (recorder.held.length > 0 ? "Let go to finish" : "Hold the keys together, then let go")
      : recorder.pending.length > 0 ? "…and one more key" : "Press the shortcut"
    muted: true
  }
  // Where the first prompt and this hint don't both fit, the hint is left to
  // the caller to show under the recorder, rather than covering the prompt.
  readonly property string keysHint: allowClear ? "Esc to cancel, Backspace to turn off" : "Esc to cancel"
  readonly property bool keysHintFits: firstPrompt.advanceWidth + keysHintText.implicitWidth + 36 <= width
  TextMetrics { id: firstPrompt; font: prompt.font; text: recorder.mode === "chord" ? "Hold the keys together, then let go" : "Press the shortcut" }
  UiText {
    id: keysHintText
    anchors.right: parent.right
    anchors.rightMargin: 14
    anchors.verticalCenter: parent.verticalCenter
    visible: recorder.listening && recorder.keysHintFits
    text: recorder.keysHint
    muted: true
    font.pixelSize: 12
  }
}
