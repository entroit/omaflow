import QtQuick

// The keys that start, stop and deliver a take, in one table. Change or Add
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
    app.savePasteShortcut(parts.map(function(part) { return part.toLowerCase() }), key)
    status = "Paste shortcut: " + app.bindingLabel(binding)
    failed = false
    editing = ""
  }

  readonly property var modifierKeys: ["Shift_L", "Shift_R", "Control_L", "Control_R", "Alt_L", "Alt_R", "Super_L", "Super_R", "ISO_Level3_Shift"]
  readonly property string pasteLabel: {
    var shortcut = app.pasteShortcut || {}
    var names = { ctrl: "Ctrl", shift: "Shift", alt: "Alt", super: "Super" }
    return (shortcut.modifiers || []).map(function(m) { return names[m] || m }).concat([String(shortcut.key || "")]).join(" ")
  }

  PageTitle { width: parent.width; title: "Hotkeys"; subtitle: "How a take starts, stops and reaches the app you are in." }

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
          { id: "dictate", kind: "chord", name: "Dictate, hold", note: "Double-tap to lock", optional: false },
          { id: "window", kind: "binding", name: "Open OmaFlow", note: "Press again to close", optional: true },
          { id: "journal", kind: "binding", name: "Journal entry, hold", note: "Double-tap to lock", optional: true },
          { id: "open_journal", kind: "binding", name: "Open the journal", note: "Press again to close", optional: true },
          { id: "todo", kind: "binding", name: "To-do, hold", note: "Double-tap to lock", optional: true },
          { id: "open_todos", kind: "binding", name: "Open to-dos", note: "Press again to close", optional: true },
          { id: "paste", kind: "paste", name: "Custom paste", note: "", optional: false },
          { id: "", kind: "", name: "Close a finished card", note: "Never ends a take", optional: false }
        ]
        Item {
          id: row
          required property var modelData
          required property int index
          readonly property bool open: page.editing.length > 0 && page.editing === modelData.id
          readonly property string keys: modelData.id === "dictate" ? page.app.hotkeyDisplay
            : modelData.id === "window" ? page.app.windowShortcut
            : modelData.id === "journal" ? page.app.journalShortcut
            : modelData.id === "open_journal" ? page.app.openJournalShortcut
            : modelData.id === "todo" ? page.app.todoShortcut
            : modelData.id === "open_todos" ? page.app.openTodosShortcut
            : modelData.id === "paste" ? page.pasteLabel
            : "Esc"
          readonly property string note: modelData.id === "paste"
            ? (page.app.pasteMode === "custom" ? "In use for pasting" : "When Paste is Custom")
            : modelData.note
          width: rows.width
          height: 50 + (open ? detail.implicitHeight + 12 : 0)

          Rectangle { visible: row.index > 0; width: parent.width; height: 1; color: Theme.divider }
          UiText { x: 16; y: 25 - height / 2; text: row.modelData.name; font.pixelSize: 14 }

          // The keys, or the recorder in their place.
          Keycap { x: 200; y: 25 - height / 2; visible: !row.open && row.keys.length > 0; text: row.keys }
          UiText { x: 200; y: 25 - height / 2; visible: !row.open && row.keys.length === 0; text: "No shortcut"; muted: true }
          UiText { x: 380; y: 25 - height / 2; width: actions.x - x - 8; elide: Text.ElideRight; visible: !row.open && row.keys.length > 0; text: row.note; muted: true; font.pixelSize: 12 }
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
              visible: row.modelData.id.length > 0 && !row.open
              kind: "link"
              text: row.keys.length > 0 ? "Change" : "Add"
              size: 13
              onClicked: { page.status = ""; page.editing = row.modelData.id }
            }
          }

          // Under an open row: what to press, or why a key was refused, and
          // for the dictation keys which of them other apps never see.
          Column {
            id: detail
            visible: row.open
            x: 200
            y: 50
            width: parent.width - x - 16
            spacing: 10
            UiText {
              width: parent.width
              wrapMode: Text.Wrap
              font.pixelSize: 12
              color: recorder.problem ? Theme.redText : Theme.secondary
              text: recorder.problem
                || (row.modelData.kind === "chord" ? "Hold the keys together, then let go. Your current keys start dictation instead of showing here."
                  : row.modelData.kind === "paste" ? "The keys your apps paste with, such as Ctrl Shift V."
                  : "Any modifiers and one key, like Omarchy's own shortcuts, or one key that types nothing, such as F13. Hold Super and tap AltGr to use AltGr. Keys Omarchy already uses, or that dictation keeps from other apps, don't show here.")
            }
            Row {
              id: reserve
              readonly property var keys: page.app.shortcutSettings.keys || []
              readonly property var consumed: page.app.shortcutSettings.consumed || []
              readonly property var candidates: keys.filter(function(key) { return page.modifierKeys.indexOf(key) < 0 })
              visible: row.modelData.kind === "chord" && candidates.length > 0
              spacing: 6
              UiText { anchors.verticalCenter: parent.verticalCenter; text: "Keep from other apps"; font.pixelSize: 12; muted: true; rightPadding: 4 }
              Repeater {
                model: reserve.candidates
                Pill {
                  required property string modelData
                  anchors.verticalCenter: parent.verticalCenter
                  kind: "ghost"; size: 12; verticalPadding: 4
                  border.width: 1; border.color: Theme.outline
                  text: modelData
                  selected: reserve.consumed.indexOf(modelData) >= 0
                  enabled: !page.saving
                  hint: "Swallow " + modelData + " everywhere, even pressed alone. Only for a dedicated key such as Menu or F13."
                  onClicked: {
                    var next = reserve.consumed.slice()
                    var at = next.indexOf(modelData)
                    if (at >= 0) next.splice(at, 1); else next.push(modelData)
                    page.saveChord(reserve.keys, next, true)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  UiText {
    visible: page.status.length > 0
    width: parent.width
    wrapMode: Text.Wrap
    text: page.status
    color: page.failed ? Theme.redText : Theme.greenText
  }
}
