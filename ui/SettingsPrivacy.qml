import QtQuick

// Where your voice and your words go, and what is kept. Settled in one place
// rather than inferred from switches spread across the app.
Column {
  id: page
  required property var app
  spacing: 22
  property bool confirmErase: false
  // A history limit below what is saved deletes the rest, so it asks first,
  // like deleting saved dictations does. -1 while nothing is asked.
  property int confirmLimit: -1
  readonly property int limitDeletes: confirmLimit < 0 ? 0 : app.history.length - confirmLimit
  function setHistoryLimit(limit) {
    if (limit < app.history.length) confirmLimit = limit
    else app.preference("history_limit", limit)
  }
  // Turning dictation audio off deletes what is kept, so it asks first too,
  // unless nothing is kept yet.
  property bool confirmAudio: false
  readonly property int keptAudio: app.history.filter(function(entry) { return entry.audio === true }).length
  function toggleAudio() {
    if (app.keepDictationAudio && keptAudio > 0) confirmAudio = true
    else app.preference("keep_dictation_audio", !app.keepDictationAudio)
  }
  readonly property bool keepJournalAudio: app.journalSettings.keep_recordings !== false

  // No address yet sends nothing anywhere.
  function local(value) {
    return String(value).trim().length === 0 || /^https?:\/\/(localhost|127(?:\.[0-9]{1,3}){3}|\[::1\])(?::[0-9]+)?(?:\/|$)/i.test(String(value).trim())
  }
  readonly property bool localSpeech: local(app.modelSettings.speech_endpoint || "")
  readonly property bool localCleanup: app.cleanupLevel !== "medium" || local(app.modelSettings.cleanup_endpoint || "")
  readonly property bool allLocal: localSpeech && localCleanup
  function hostOf(value) {
    var url = String(value).trim()
    return (url.match(/^https?:\/\/([^\/]+)/) || [])[1] || url
  }
  // What leaves, and to which machine, one model at a time.
  readonly property string whereText: allLocal ? "Speech and cleanup run on this computer, with no account and no network."
    : (localSpeech ? "Speech runs on this computer."
        : "Your audio goes to " + hostOf(app.modelSettings.speech_endpoint || "") + " for speech.")
      + (localCleanup ? " Cleanup stays on this computer."
        : " Your raw text and the focused window's title go to " + hostOf(app.modelSettings.cleanup_endpoint || "") + " for cleanup.")

  PageTitle { width: parent.width; title: "Privacy"; subtitle: page.allLocal ? "What OmaFlow keeps, and where."
    : "Some dictation goes to another machine. Here is what goes where, and what is kept." }

  Rectangle {
    width: parent.width
    height: where.implicitHeight + 34
    radius: Theme.radiusPanel
    color: Theme.fill4
    border.width: 1
    border.color: page.allLocal ? Theme.green : Theme.yellow
    Column {
      id: where
      x: 17; y: 17
      width: parent.width - 34
      spacing: 5
      UiText { text: page.allLocal ? "Nothing leaves this computer" : "Some of your dictation leaves this computer"; font.pixelSize: 15; weight: Font.Bold }
      UiText {
        width: parent.width
        wrapMode: Text.Wrap
        muted: true
        lineHeight: 18
        text: page.whereText + " " + (page.app.keepDictationAudio && page.app.historyLimit !== 0
            ? (page.keepJournalAudio ? "Dictation audio is kept with your history, and journal recordings in your journal folder."
              : "Dictation audio is kept with your history. Journal entries keep only their words.")
            : (page.keepJournalAudio ? "Dictation audio is dropped after transcription. Journal recordings are kept in your journal folder."
              : "No audio is kept. Each recording is dropped once its words are written down."))
      }
    }
  }

  Column {
    width: parent.width
    spacing: 18
    UiText { text: "What is kept"; font.pixelSize: 14; weight: Font.DemiBold }

    SettingRow {
      title: "Dictation history"
      caption: page.confirmLimit === 0 ? "Turning history off deletes your " + page.app.history.length + (page.app.history.length === 1 ? " saved dictation" : " saved dictations") + ". This can't be undone."
        : page.confirmLimit > 0 ? "Keeping " + page.confirmLimit + " deletes the " + page.limitDeletes + " oldest. This can't be undone."
        : page.app.historyLimit === 0 ? "Nothing is saved." : "Keeps the last " + page.app.historyLimit + ". Only your user can read them."
      Segmented {
        visible: page.confirmLimit < 0
        name: "Dictation history"
        size: 12
        horizontalPadding: 12
        options: [{ value: "0", label: "Off" }, { value: "30", label: "30" }, { value: "100", label: "100" }, { value: "1000", label: "1000" }]
        current: String(page.app.historyLimit)
        onPicked: function(value) { page.setHistoryLimit(Number(value)) }
      }
      Row {
        visible: page.confirmLimit >= 0
        spacing: 8
        // Where the choice was, so a second click keeps rather than deletes.
        Pill { kind: "fill"; text: "Keep them"; size: 13; onClicked: page.confirmLimit = -1; onVisibleChanged: if (visible) forceActiveFocus() }
        Pill {
          kind: "danger"
          text: page.confirmLimit === 0 ? "Delete " + page.limitDeletes + (page.limitDeletes === 1 ? " dictation" : " dictations")
            : "Delete the " + page.limitDeletes + " oldest"
          size: 13
          onClicked: {
            page.app.preference("history_limit", page.confirmLimit)
            page.confirmLimit = -1
          }
        }
      }
    }

    SettingRow {
      title: "Dictation audio"
      // With history off there is no saved dictation to keep audio with.
      caption: page.confirmAudio ? "Turning this off deletes the audio of " + page.keptAudio + (page.keptAudio === 1 ? " dictation" : " dictations") + ". This can't be undone."
        : page.app.historyLimit === 0 ? "History is off, so no audio is kept."
        : page.app.keepDictationAudio ? "Kept with each saved dictation. Off deletes it." : "Dropped after transcription."
      toggle: audioToggle
      Toggle { id: audioToggle; visible: !page.confirmAudio && page.app.historyLimit !== 0; label: "Keep dictation audio"; checked: page.app.keepDictationAudio; onToggled: page.toggleAudio() }
      Row {
        visible: page.confirmAudio
        spacing: 8
        Pill { kind: "fill"; text: "Keep it"; size: 13; onClicked: page.confirmAudio = false; onVisibleChanged: if (visible) forceActiveFocus() }
        Pill {
          kind: "danger"
          text: "Delete audio"
          size: 13
          onClicked: {
            page.app.preference("keep_dictation_audio", false)
            page.confirmAudio = false
          }
        }
      }
    }

    SettingRow {
      title: "Training log"
      // Off only stops adding to the file; erasing below is what deletes it.
      caption: "Every dictation, raw and cleaned, without limit. Off stops adding to it."
      toggle: logToggle
      Row {
        spacing: 12
        Toggle { id: logToggle; anchors.verticalCenter: parent.verticalCenter; label: "Training log"; checked: page.app.trainingLogEnabled; onToggled: page.app.preference("training_log_enabled", !checked) }
        // The daemon keeps it beside History, under XDG_STATE_HOME.
        Pill {
          anchors.verticalCenter: parent.verticalCenter
          kind: "link"; text: "Open"; size: 13
          Accessible.name: "Open the training log folder"
          onClicked: page.app.spawn(["sh", "-c", "exec xdg-open \"${XDG_STATE_HOME:-$HOME/.local/state}/omaflow\""])
        }
      }
    }

    SettingRow {
      title: "Journal"
      caption: "Your own Markdown files"
      Row {
        spacing: 12
        UiText { anchors.verticalCenter: parent.verticalCenter; text: String(page.app.journalSettings.folder || ""); font.family: Theme.mono; font.pixelSize: 12 }
        Pill { anchors.verticalCenter: parent.verticalCenter; kind: "link"; text: "Open"; size: 13; Accessible.name: "Open journal folder"; onClicked: page.app.openExternally(page.app.journalSettings.folder_path || page.app.journalSettings.folder) }
      }
    }

    SettingRow {
      title: "To-dos"
      caption: "One Markdown file, To-dos.md"
      last: true
      Row {
        spacing: 12
        UiText { anchors.verticalCenter: parent.verticalCenter; text: String(page.app.todoSettings.folder || ""); font.family: Theme.mono; font.pixelSize: 12 }
        Pill { anchors.verticalCenter: parent.verticalCenter; kind: "link"; text: "Open"; size: 13; Accessible.name: "Open to-dos folder"; onClicked: page.app.openExternally(page.app.todoSettings.folder_path || page.app.todoSettings.folder) }
      }
    }
  }

  Rectangle { width: parent.width; height: 1; color: Theme.divider }

  // The scope of the one delete that can't be undone wraps beside its
  // buttons rather than running under them.
  Item {
    width: parent.width
    height: Math.max(36, eraseText.implicitHeight)
    UiText {
      id: eraseText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - eraseActions.width - 16
      wrapMode: Text.Wrap
      text: page.confirmErase ? "History, its audio and any training log will be deleted. The journal and to-dos stay. This can't be undone." : "No screenshots, no keystroke logging, no account."
      muted: !page.confirmErase
    }
    Row {
      id: eraseActions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8
      Pill { visible: !page.confirmErase; kind: "danger"; text: "Delete saved dictations…"; size: 13; onClicked: page.confirmErase = true }
      // Delete comes first, so Keep it takes the slot the first click was
      // in and a second Enter keeps everything. The second click of a
      // double-click can still land here, so Delete waits a moment.
      Pill {
        visible: page.confirmErase
        kind: "danger"
        text: page.app.history.length === 0 ? "Delete now"
          : "Delete " + page.app.history.length + (page.app.history.length === 1 ? " dictation" : " dictations")
        size: 13
        Timer { id: eraseSettle; interval: 500 }
        onVisibleChanged: if (visible) eraseSettle.restart()
        onClicked: {
          if (eraseSettle.running) return
          page.app.eraseData()
          page.confirmErase = false
        }
      }
      Pill { visible: page.confirmErase; kind: "fill"; text: "Keep it"; size: 13; onClicked: page.confirmErase = false; onVisibleChanged: if (visible) forceActiveFocus() }
    }
  }
}
