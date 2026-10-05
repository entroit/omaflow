import QtQuick

// The journal's own settings. They live with the journal, not in Settings,
// because nobody looks for "keep recordings" next to the speech model.
Sheet {
  id: sheet

  required property var app
  property bool editingFolder: false
  signal exportRequested()

  panelWidth: 480
  onOpenChanged: editingFolder = false

  Column {
    width: parent.width
    spacing: 4

    Item {
      width: parent.width
      height: 36
      UiText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Journal settings"; font.pixelSize: 20; weight: Font.Bold }
      UiText { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Only for the journal"; muted: true }
    }

    SheetRow {
      title: "Folder"
      caption: sheet.editingFolder ? "" : String(sheet.app.journalSettings.folder || "") + ", one .md per day"
      monoCaption: true
      visible: !sheet.editingFolder
      Pill { kind: "outline"; text: "Change"; size: 13; onClicked: sheet.editingFolder = true }
    }

    Column {
      visible: sheet.editingFolder
      width: parent.width
      spacing: 10
      topPadding: 12
      bottomPadding: 14
      Field {
        id: folder
        width: parent.width
        label: "Folder"
        mono: true
        text: String(sheet.app.journalSettings.folder || "")
        hint: "Existing days stay where they are. Move the files yourself if you want them in the new folder."
        problem: /^[~\/]/.test(text.trim()) ? "" : "Use a full path, such as ~/Documents/Journal."
        onAccepted: if (problem.length === 0) { sheet.app.journalSetting("folder", text.trim()); sheet.editingFolder = false }
      }
      Row {
        spacing: 8
        Pill { kind: "fill"; text: "Cancel"; size: 13; onClicked: sheet.editingFolder = false }
        Pill {
          kind: "primary"; text: "Use this folder"; size: 13
          enabled: folder.problem.length === 0 && folder.text.trim().length > 0
          onClicked: { sheet.app.journalSetting("folder", folder.text.trim()); sheet.editingFolder = false }
        }
      }
      Rectangle { width: parent.width; height: 1; color: Theme.divider }
    }

    SheetRow {
      title: "Cleanup"
      caption: sheet.app.journalSettings.cleanup === "off" ? "Every word as you said it."
        : sheet.app.journalSettings.cleanup === "medium" ? "The cleanup model tidies sentences, your wording stays."
        : "Fillers go, your wording stays."
      Segmented {
        options: [{ value: "off", label: "Off" }, { value: "light", label: "Light" }, { value: "medium", label: "Medium" }]
        current: String(sheet.app.journalSettings.cleanup || "light")
        onPicked: function(value) { sheet.app.journalSetting("cleanup", value) }
      }
    }

    SheetRow {
      title: "Keep recordings"
      caption: sheet.app.journalSettings.keep_recordings !== false
        ? "So you can hear an entry again. Off deletes the recordings, the words stay."
        : "Off, only the words and the waveform are kept."
      Toggle {
        label: "Keep recordings"
        checked: sheet.app.journalSettings.keep_recordings !== false
        onToggled: sheet.app.journalSetting("keep_recordings", !checked)
      }
    }

    SheetRow {
      title: "A question on empty days"
      caption: "One short prompt, like “What surprised you today?”"
      last: true
      Toggle {
        label: "A question on empty days"
        checked: sheet.app.journalSettings.empty_day_question === true
        onToggled: sheet.app.journalSetting("empty_day_question", !checked)
      }
    }

    Item {
      width: parent.width
      height: 52
      Pill { anchors.left: parent.left; anchors.bottom: parent.bottom; kind: "fill"; text: "Export as Markdown"; size: 13; verticalPadding: 8; horizontalPadding: 14; onClicked: sheet.exportRequested() }
      Pill { anchors.right: parent.right; anchors.bottom: parent.bottom; kind: "primary"; text: "Done"; size: 13; verticalPadding: 8; horizontalPadding: 18; onClicked: sheet.closed() }
    }
  }
}
