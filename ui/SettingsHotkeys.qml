import QtQuick
import "Keys.js" as KeyNames

// The keys that start, stop and deliver a dictation, in one table. Change or Add
// turns that row's keys into a recorder: press the new keys and they are
// saved. Nothing to type, and no second form below the table.
Column {
  id: page
  required property var app
  spacing: 16

  // The row being recorded: "", "dictate", "window", "journal",
  // "open_journal", "todo", "open_todos" or "paste".
  property string editing: ""
  property string status: ""
  property bool failed: false
  property bool saving: false
  // The paste shortcut goes to the daemon, which answers only by publishing
  // it; it is confirmed once it shows up there.
  property string pendingPaste: ""
  // A save that was refused: the open row shows why and listens again.
  signal rejected(string message)

  function run(args, keepOpen) {
    status = ""
    saving = true
    app.spawn(["python3", app.pluginDir + "/tools/set_hotkey.py"].concat(args), function(stdout, stderr) {
      saving = false
      try {
        var response = JSON.parse(stdout)
        failed = !response.ok
        if (response.ok) { status = response.message; if (!keepOpen) editing = "" }
        else { status = ""; rejected(response.message) }
      } catch (error) {
        failed = true
        status = ""
        rejected(String(stderr || "").trim() || "Could not save the shortcut. Check that Hyprland is running.")
      }
    })
  }
  function saveBinding(action, binding) { run(["--action", action, "--bind", binding]) }
  function saveChord(keys, consumed, keepOpen) {
    run(["--keys", keys.join(","), "--consumed", consumed.filter(function(key) { return keys.indexOf(key) >= 0 }).join(",")], keepOpen)
  }
  // "SUPER + SHIFT + V" becomes the paste shortcut's modifiers and key.
  function savePaste(binding) {
    var parts = binding.split(" + ")
    var key = parts.pop()
    var shortcut = { modifiers: parts.map(function(part) { return part.toLowerCase() }), key: key }
    failed = false
    editing = ""
    // The same keys again change nothing, so there is nothing to wait for.
    if (app.pasteMode === "custom" && app.pasteLabel(app.pasteShortcut || {}) === app.pasteLabel(shortcut)) {
      status = "Paste shortcut: " + app.pasteLabel(shortcut)
      return
    }
    status = ""
    pendingPaste = app.pasteLabel(shortcut)
    app.savePasteShortcut(shortcut.modifiers, key)
  }
  function confirmPaste() {
    if (pendingPaste.length === 0 || app.pasteMode !== "custom" || app.pasteLabel(app.pasteShortcut || {}) !== pendingPaste) return
    status = "Paste shortcut: " + pendingPaste
    pendingPaste = ""
  }
  Connections {
    target: page.app
    function onPasteShortcutChanged() { page.confirmPaste() }
    function onPasteModeChanged() { page.confirmPaste() }
  }

  readonly property string pasteModeName: ({ "auto": "Auto", "ctrl-v": "Ctrl+V", "shift-insert": "Shift+Insert", "clipboard": "Copy only" })[app.pasteMode] || "Auto"

  readonly property var modifierKeys: ["Shift_L", "Shift_R", "Control_L", "Control_R", "Alt_L", "Alt_R", "Super_L", "Super_R", "ISO_Level3_Shift"]
  // Keys are written one way across Settings: "Super+Shift+V", like "Ctrl+V".
  function keysLabel(binding) { return KeyNames.labels(binding).join("+") }

  PageTitle { width: parent.width; title: "Hotkeys"; subtitle: "How dictation starts, stops and reaches the app you are in." }

  Rectangle {
    width: parent.width
    height: rows.implicitHeight
    radius: Theme.radiusCard + 2
    color: "transparent"
    border.width: 1
    border.color: Theme.divider
    Column {
      id: rows
      width: parent.width
      Repeater {
        // The rows never change, so the daemon republishing its state can't
        // rebuild a row, and its recorder, while you press keys. Each row
        // reads its current keys itself.
        model: [
          { id: "dictate", kind: "chord", name: "Hold to dictate", note: "Double-tap to lock", optional: false },
          { id: "window", kind: "binding", name: "Open OmaFlow", note: "Press again to close", optional: true },
          { id: "journal", kind: "binding", name: "Hold for a journal entry", note: "Double-tap to lock", optional: true },
          { id: "open_journal", kind: "binding", name: "Open the journal", note: "Press again to close", optional: true },
          { id: "todo", kind: "binding", name: "Hold to add to-dos", note: "Double-tap to lock", optional: true },
          { id: "open_todos", kind: "binding", name: "Open to-dos", note: "Press again to close", optional: true },
          { id: "paste", kind: "paste", name: "Paste with your own keys", note: "", optional: false }
        ]
        Item {
          id: row
          required property var modelData
          required property int index
          readonly property bool open: page.editing.length > 0 && page.editing === modelData.id
          // Paste always has keys stored, Ctrl+V by default; that default is
          // not your own, so the row offers Add until you set some.
          readonly property string keys: modelData.id === "dictate" ? page.app.hotkeyDisplay.split(/\s*\+\s*/).join("+")
            : modelData.id === "paste" ? (page.app.customPaste ? page.app.pasteLabel(page.app.pasteShortcut || {}) : "")
            : page.keysLabel(page.app.shortcutSettings[modelData.id])
          readonly property string note: modelData.id !== "paste" ? modelData.note
            : page.app.pasteMode === "custom" ? "In use, in every app"
            : keys.length > 0 ? "Not in use. Pick it in Basics, Paste with."
            : "Setting it replaces " + page.pasteModeName + " in every app"
          width: rows.width
          // The note sits on its own line under the name, across the row, so
          // what a key does is never cut short at the narrowest window.
          readonly property bool noted: !open && (keys.length > 0 || modelData.id === "paste") && note.length > 0
          readonly property real detailTop: noted ? noteText.y + noteText.implicitHeight + 10 : 50
          height: detailTop + (detail.visible ? detail.implicitHeight + 12 : 0)

          Rectangle { visible: row.index > 0; width: parent.width; height: 1; color: Theme.divider }
          UiText { x: 16; y: 25 - height / 2; text: row.modelData.name; font.pixelSize: 14 }

          // The keys, or the recorder in their place.
          Keycap { x: 200; y: 25 - height / 2; visible: !row.open && row.keys.length > 0; text: row.keys }
          UiText { x: 200; y: 25 - height / 2; visible: !row.open && row.keys.length === 0; text: "No shortcut"; muted: true }
          UiText { id: noteText; x: 16; y: 42; width: actions.x - x - 8; wrapMode: Text.Wrap; visible: row.noted; text: row.note; muted: true; font.pixelSize: 12 }
          KeyRecorder {
            id: recorder
            x: 192
            y: 8
            width: actions.x - x - 12
            visible: row.open
            mode: row.modelData.kind === "chord" ? "chord" : "binding"
            allowBare: row.modelData.kind === "binding"
            allowClear: row.modelData.optional && row.keys.length > 0
            onVisibleChanged: if (visible) {
              value = mode === "chord" ? [] : ""
              Qt.callLater(start)
            }
            onCancelled: if (page.editing === row.modelData.id) page.editing = ""
            onCleared: page.saveBinding(row.modelData.id, "")
            Connections {
              target: page
              function onRejected(message) {
                if (!row.open) return
                recorder.start()
                recorder.problem = message
              }
            }
            onRecorded: {
              if (row.modelData.kind === "chord") page.saveChord(value, page.app.shortcutSettings.consumed || [], false)
              else if (row.modelData.kind === "paste") page.savePaste(value)
              else page.saveBinding(row.modelData.id, value)
            }
          }

          Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: 10
            y: 25 - height / 2
            spacing: 4
            Pill {
              visible: !row.open
              kind: "link"
              text: row.keys.length > 0 ? "Change" : "Add"
              size: 13
              Accessible.name: text + " " + row.modelData.name + " shortcut"
              onClicked: { page.status = ""; page.editing = row.modelData.id }
              // Back here after Esc or a save from the keyboard, not lost.
              onVisibleChanged: if (visible && recorder.endedByKey) { recorder.endedByKey = false; forceActiveFocus() }
            }
          }

          // Under an open row: what to press, or why a key was refused. Under
          // the dictation keys, open or not, which of them other apps never
          // see, so the choice is reachable with Tab and not only mid-recording.
          Column {
            id: detail
            visible: row.open || reserve.offered
            x: 200
            y: row.detailTop
            width: parent.width - x - 16
            spacing: 10
            // The recorder's Esc hint, when it has no room beside the prompt.
            UiText {
              visible: row.open && recorder.listening && !recorder.keysHintFits
              width: parent.width
              wrapMode: Text.Wrap
              font.pixelSize: 12
              muted: true
              text: recorder.keysHint + "."
            }
            UiText {
              visible: row.open
              width: parent.width
              wrapMode: Text.Wrap
              font.pixelSize: 12
              color: recorder.problem ? Theme.redText : Theme.secondary
              text: recorder.problem
                || (row.modelData.kind === "chord" ? "Your current keys start dictation instead of showing here."
                  : row.modelData.kind === "paste" ? "The keys your apps paste with, such as Ctrl+Shift+V."
                  : "Any modifiers and one key, like Omarchy's own shortcuts, or one key that types nothing, such as F13. Hold Super and tap AltGr to use AltGr. Keys Omarchy already uses, or that dictation keeps from other apps, don't show here.")
            }
            Row {
              id: reserve
              readonly property var keys: page.app.shortcutSettings.keys || []
              readonly property var consumed: page.app.shortcutSettings.consumed || []
              readonly property var candidates: keys.filter(function(key) { return page.modifierKeys.indexOf(key) < 0 })
              readonly property bool offered: row.modelData.kind === "chord" && candidates.length > 0
              visible: offered
              spacing: 6
              UiText { anchors.verticalCenter: parent.verticalCenter; text: "Keep from other apps"; font.pixelSize: 12; muted: true; rightPadding: 4 }
              Repeater {
                model: reserve.candidates
                Pill {
                  required property string modelData
                  anchors.verticalCenter: parent.verticalCenter
                  kind: "ghost"; size: 12; verticalPadding: 4
                  border.width: 1; border.color: Theme.outline
                  text: KeyNames.label(modelData)
                  selected: reserve.consumed.indexOf(modelData) >= 0
                  enabled: !page.saving
                  hint: "Hide " + text + " from every app, even pressed alone"
                  onClicked: {
                    var next = reserve.consumed.slice()
                    var at = next.indexOf(modelData)
                    if (at >= 0) next.splice(at, 1); else next.push(modelData)
                    page.saveChord(reserve.keys, next, true)
                  }
                }
              }
            }
            UiText {
              visible: reserve.offered
              width: parent.width
              wrapMode: Text.Wrap
              font.pixelSize: 12
              muted: true
              text: "A selected key is hidden from every app, even pressed alone. Use it only for a key such as Menu or F13."
            }
          }
        }
      }
    }
  }

  UiText { width: parent.width; wrapMode: Text.Wrap; muted: true; font.pixelSize: 12; text: "Esc closes a finished card. It never stops a recording." }

  UiText {
    visible: page.status.length > 0
    width: parent.width
    wrapMode: Text.Wrap
    text: page.status
    color: page.failed ? Theme.redText : Theme.greenText
  }
}
