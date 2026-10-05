import QtQuick

// What most people change. Everything else is one level down, in Advanced.
Column {
  id: page
  required property var app
  signal go(string target)
  spacing: 22

  readonly property var cleanupNotes: ({
    "off": "Pastes exactly what the speech model heard. Your words list still applies.",
    "light": "Drops fillers such as um and uh, and repeated words. Never adds a word. Runs instantly, no model needed.",
    "medium": "The cleanup model fixes punctuation, applies the corrections you say out loud and writes numbers as digits."
  })

  PageTitle { width: parent.width; title: "Basics"; subtitle: "What most people change. Everything else is under Advanced." }

  Column {
    width: parent.width
    spacing: 18

    SettingRow {
      title: "Hold to talk"
      caption: "Double-tap to lock"
      Item {
        width: parent.width
        height: 32
        Keycap { anchors.verticalCenter: parent.verticalCenter; text: page.app.hotkeyDisplay || "Not set" }
        Pill { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; kind: "outline"; text: "Change"; size: 13; onClicked: page.go("hotkeys") }
      }
    }

    SettingRow {
      title: "Microphone"
      caption: "Speak to test"
      Column {
        width: parent.width
        spacing: 8
        UiText {
          text: page.app.micDetected ? "Your voice is coming through." : "Uses the default input from your sound settings."
          muted: !page.app.micDetected
          color: page.app.micDetected ? Theme.greenText : Theme.secondary
        }
        Meter { width: parent.width; app: page.app }
      }
    }

    SettingRow {
      title: "Cleanup"
      caption: "Raw text is always kept"
      alignTop: true
      Column {
        width: parent.width
        spacing: 10
        Segmented {
          options: [{ value: "off", label: "Off" }, { value: "light", label: "Light" }, { value: "medium", label: "Medium" }]
          current: page.app.cleanupLevel
          onPicked: function(value) { page.app.setCleanupLevel(value) }
        }
        UiText {
          width: parent.width
          text: page.cleanupNotes[page.app.cleanupLevel] || ""
          muted: true
          wrapMode: Text.Wrap
          lineHeight: 18
        }
        Row {
          visible: page.app.cleanupLevel === "medium" && page.app.cleanupRuntime !== "ready"
          spacing: 8
          UiText { anchors.verticalCenter: parent.verticalCenter; text: page.app.cleanupRuntime === "missing" ? "The cleanup model is not installed yet." : "The cleanup model is not answering."; color: Theme.yellowText }
          Pill { kind: "link"; text: "Set it up"; size: 13; onClicked: page.go("cleanup") }
        }
      }
    }

    SettingRow {
      title: "Paste with"
      caption: "Text also stays on the clipboard"
      alignTop: true
      last: true
      Column {
        width: parent.width
        spacing: 10
        Segmented {
          horizontalPadding: 12
          options: [{ value: "auto", label: "Auto" }, { value: "ctrl-v", label: "Ctrl+V" }, { value: "shift-insert", label: "Shift+Insert" }, { value: "clipboard", label: "Copy only" }]
          current: page.app.pasteMode === "custom" ? "" : page.app.pasteMode
          onPicked: function(value) { page.app.setPasteMode(value) }
        }
        UiText {
          width: parent.width
          wrapMode: Text.Wrap
          muted: true
          text: page.app.pasteMode === "custom" ? "A custom shortcut is set in Advanced, Hotkeys."
            : page.app.pasteMode === "clipboard" ? "OmaFlow copies and you paste."
            : page.app.pasteMode === "auto" ? "Ctrl+V, or Shift+Insert in terminals."
            : ""
        }
      }
    }
  }
}
