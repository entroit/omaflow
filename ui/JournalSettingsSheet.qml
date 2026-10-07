import QtQuick

// The journal's own settings. They live with the journal, not in Settings,
// because nobody looks for "keep recordings" next to the speech model.
Sheet {
  id: sheet

  required property var app
  property bool editingFolder: false
  // Days in the journal and entries with a recording, or -1 when unknown.
  property int days: -1
  property int recordings: -1
  // Turning recordings off deletes them, so it asks first.
  property bool confirmRecordings: false
  // A new folder for a journal that has days: whether to move them there is
  // asked first. The folder asked about, or "".
  property string movingTo: ""
  property bool moving: false
  // What the last folder change did, or why it could not.
  property string folderMessage: ""
  property bool folderError: false
  // What the last export saved, or why it could not.
  property string exportMessage: ""
  property bool exportError: false
  signal exportRequested()

  panelWidth: 480
  onOpenChanged: { editingFolder = false; confirmRecordings = false; exportMessage = ""; movingTo = ""; folderMessage = ""; folderError = false }
  readonly property string folderName: String(app.journalSettings.folder || "")
  readonly property string daysText: days === 1 ? "your 1 day" : days > 1 ? "your " + days + " days" : "your days"
  // A spoken entry would land in the folder being emptied, so the move waits
  // for it, and says what for.
  readonly property string moveWait: !app.journalTake ? ""
    : app.phase === "recording" ? "Finish the entry you are recording first."
    : app.phase === "processing" ? "Wait until the entry is written down." : ""

  function useFolder(value) {
    folderMessage = ""
    folderError = false
    if (value === folderName) editingFolder = false
    else if (days === 0) { app.journalSetting("folder", value); editingFolder = false }
    else movingTo = value
  }
  // The window moves the files: it can write both folders, and the daemon
  // only the one it was given. The move saves the folder with it; telling
  // the daemon then opens the new folder to it, as for any new folder.
  function moveDays() {
    var to = movingTo
    moving = true
    folderError = false
    folderMessage = ""
    app.query(["journal", "move-folder", to], function(value, error) {
      moving = false
      if (!value) { folderError = true; folderMessage = error; return }
      var moved = Number(value.days)
      var from = folderName
      app.journalSetting("folder", to)
      // The days are in the new folder, but some copies stayed behind in the
      // old one: say which, so they can be cleared by hand.
      var left = Array.isArray(value.left_behind) ? value.left_behind : []
      folderMessage = (moved > 0 ? "Moved " + moved + (moved === 1 ? " day" : " days") + " to " + to + "." : "")
        + (left.length > 0 ? (moved > 0 ? " " : "") + (left.length === 1 ? "This" : "These") + " could not be removed from " + from + ": " + left.join(", ") + "."
          + " Delete " + (left.length === 1 ? "it" : "them") + " there yourself once you've checked the new folder." : "")
      movingTo = ""
      editingFolder = false
    })
  }
  function leaveThem() {
    var from = folderName
    app.journalSetting("folder", movingTo)
    folderError = false
    folderMessage = days !== 0 ? (days === 1 ? "Your 1 day stays" : days > 1 ? "Your " + days + " days stay" : "Your days stay") + " in " + from + "." : ""
    movingTo = ""
    editingFolder = false
  }

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
      Pill { kind: "outline"; text: "Change"; size: 13; onClicked: { sheet.folderMessage = ""; sheet.editingFolder = true } }
    }
    // What the folder change did, under the folder it is about.
    UiText {
      visible: !sheet.editingFolder && sheet.folderMessage.length > 0
      width: parent.width
      bottomPadding: 12
      text: sheet.folderMessage
      color: Theme.secondary
      wrapMode: Text.Wrap
    }

    Column {
      visible: sheet.editingFolder
      width: parent.width
      spacing: 10
      topPadding: 12
      bottomPadding: 14
      Field {
        id: folder
        visible: sheet.movingTo.length === 0
        width: parent.width
        label: "Folder"
        mono: true
        text: String(sheet.app.journalSettings.folder || "")
        hint: sheet.days === 0 ? "Your journal starts in the new folder." : ""
        problem: /^[~\/]/.test(text.trim()) ? "" : "Use a full path, such as ~/Documents/Journal."
        onAccepted: if (problem.length === 0 && text.trim().length > 0) sheet.useFolder(text.trim())
      }
      Row {
        visible: sheet.movingTo.length === 0
        spacing: 8
        Pill { kind: "fill"; text: "Cancel"; size: 13; onClicked: sheet.editingFolder = false }
        Pill {
          kind: "primary"; text: "Use this folder"; size: 13
          enabled: folder.problem.length === 0 && folder.text.trim().length > 0
          onClicked: sheet.useFolder(folder.text.trim())
        }
      }

      // The consequence first: the days move with the journal, or stay.
      Column {
        visible: sheet.movingTo.length > 0
        width: parent.width
        spacing: 10
        UiText {
          width: parent.width
          text: "Move " + sheet.daysText + " to " + sheet.movingTo + "?"
          font.pixelSize: 15
          weight: Font.DemiBold
          wrapMode: Text.Wrap
        }
        UiText {
          width: parent.width
          text: sheet.moveWait || (sheet.moving ? "Moving " + sheet.daysText + "…"
            : "If you don't move them, they stay in " + sheet.folderName + ".")
          muted: true
          wrapMode: Text.Wrap
        }
        UiText {
          visible: sheet.folderError && sheet.folderMessage.length > 0
          width: parent.width
          text: sheet.folderMessage
          color: Theme.redText
          wrapMode: Text.Wrap
        }
        Row {
          spacing: 8
          // The new folder may hold days of its own, so not moving is not
          // "starting empty". Moving stays the main way, even after a clash
          // whose message says what to fix first.
          Pill {
            kind: "primary"; text: "Move them"; size: 13
            enabled: !sheet.moving && !sheet.moveWait
            onClicked: sheet.moveDays()
          }
          Pill { kind: "fill"; text: "Don't move them"; size: 13; enabled: !sheet.moving && !sheet.moveWait; onClicked: sheet.leaveThem() }
          Pill { kind: "link"; text: "Cancel"; size: 13; enabled: !sheet.moving; onClicked: { sheet.movingTo = ""; sheet.folderError = false; sheet.folderMessage = "" } }
        }
      }
      Rectangle { width: parent.width; height: 1; color: Theme.divider }
    }

    SheetRow {
      title: "Cleanup"
      readonly property bool modelOff: sheet.app.journalSettings.cleanup === "medium" && !sheet.app.cleanupEnabled
      caption: sheet.app.journalSettings.cleanup === "off" ? "Every word as you said it."
        : modelOff ? "Medium needs the cleanup model, which runs only when dictation cleanup is Medium. Until then this works like Light."
        : sheet.app.journalSettings.cleanup === "medium" ? "The cleanup model tidies sentences, your wording stays."
        : "Fillers go, your wording stays."
      // Named for what it changes: cleanup of every dictation, not only here.
      link: modelOff ? "Set dictation cleanup to Medium" : ""
      onLinkClicked: { sheet.closed(); sheet.app.showWindow("settings/cleanup") }
      Segmented {
        name: "Journal cleanup"
        options: [{ value: "off", label: "Off" }, { value: "light", label: "Light" }, { value: "medium", label: "Medium" }]
        current: String(sheet.app.journalSettings.cleanup || "light")
        onPicked: function(value) { sheet.app.journalSetting("cleanup", value) }
      }
    }

    SheetRow {
      title: "Keep recordings"
      caption: sheet.confirmRecordings
        ? "Turning this off deletes " + (sheet.recordings > 0 ? "the recordings of " + sheet.recordings + (sheet.recordings === 1 ? " entry" : " entries") : "every journal recording")
          + ". The words and waveforms stay. This can't be undone."
        : sheet.app.journalSettings.keep_recordings !== false
        ? "So you can hear an entry again. Off deletes the recordings, the words stay."
        : "Off, only the words and the waveform are kept."
      Toggle {
        visible: !sheet.confirmRecordings
        label: "Keep recordings"
        checked: sheet.app.journalSettings.keep_recordings !== false
        onToggled: {
          if (!checked) sheet.app.journalSetting("keep_recordings", true)
          else if (sheet.recordings === 0) sheet.app.journalSetting("keep_recordings", false)
          else sheet.confirmRecordings = true
        }
      }
      // Hidden, it takes no room, so the toggle sits where the others do.
      Column {
        visible: sheet.confirmRecordings
        width: visible ? implicitWidth : 0
        height: visible ? implicitHeight : 0
        spacing: 8
        Pill { width: deleteRecordings.width; kind: "fill"; text: "Keep them"; size: 13; onClicked: sheet.confirmRecordings = false }
        Pill {
          id: deleteRecordings
          kind: "danger"
          text: "Delete recordings"
          size: 13
          onClicked: {
            sheet.app.journalSetting("keep_recordings", false)
            sheet.confirmRecordings = false
          }
        }
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

    // Grows with a long result, such as a failed export's reason.
    Item {
      width: parent.width
      height: Math.max(52, exportText.implicitHeight + 16)
      Pill {
        id: exportButton
        // Still here after a failed export, to try again.
        visible: sheet.exportMessage.length === 0 || sheet.exportError
        anchors.left: parent.left; anchors.bottom: parent.bottom
        kind: "fill"; text: "Export as one file"; size: 13; verticalPadding: 8; horizontalPadding: 14
        hint: "Every day in one Markdown file, saved to Downloads"
        onClicked: sheet.exportRequested()
      }
      // The result stays here, where the export was asked for.
      UiText {
        id: exportText
        visible: sheet.exportMessage.length > 0
        anchors.left: exportButton.visible ? exportButton.right : parent.left
        anchors.leftMargin: exportButton.visible ? 12 : 0
        anchors.right: done.left
        anchors.rightMargin: 16
        anchors.verticalCenter: done.verticalCenter
        text: sheet.exportMessage
        color: sheet.exportError ? Theme.redText : Theme.secondary
        wrapMode: Text.Wrap
      }
      // Hidden while a folder change is open: that step ends with its own
      // buttons, not with a Done that would quietly drop it.
      Pill { id: done; visible: !sheet.editingFolder; anchors.right: parent.right; anchors.bottom: parent.bottom; kind: "primary"; text: "Done"; size: 13; verticalPadding: 8; horizontalPadding: 18; onClicked: sheet.closed() }
    }
  }
}
