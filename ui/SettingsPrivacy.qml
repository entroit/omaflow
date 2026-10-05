import QtQuick

// Where your voice and your words go, and what is kept. Settled in one place
// rather than inferred from switches spread across the app.
Column {
  id: page
  required property var app
  spacing: 22
  property bool confirmErase: false

  function local(value) {
    return /^https?:\/\/(localhost|127(?:\.[0-9]{1,3}){3}|\[::1\])(?::[0-9]+)?(?:\/|$)/i.test(String(value).trim())
  }
  readonly property bool localSpeech: local(app.modelSettings.speech_endpoint || "")
  readonly property bool localCleanup: app.cleanupLevel !== "medium" || local(app.modelSettings.cleanup_endpoint || "")
  readonly property bool allLocal: localSpeech && localCleanup

  PageTitle { width: parent.width; title: "Privacy"; subtitle: "Everything runs on this computer. Here is what OmaFlow keeps, and where." }

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
        text: page.allLocal
          ? "Speech and cleanup run on this computer, with no account and no network. " + (page.app.keepDictationAudio
              ? "Dictation audio is kept with your history, and journal recordings in your journal folder."
              : "Dictation audio is dropped after transcription; journal recordings are the only audio kept, in your journal folder.")
          : "A model points at another machine. Audio goes to the speech address, and your transcript with the focused window's title goes to the cleanup address."
      }
    }
  }

  Column {
    width: parent.width
    spacing: 18
    UiText { text: "What is kept"; font.pixelSize: 14; weight: Font.DemiBold }

    SettingRow {
      title: "Dictation history"
      caption: page.app.historyLimit === 0 ? "Nothing is saved" : "The last " + page.app.historyLimit + ", only your user can read them"
      Segmented {
        size: 12
        horizontalPadding: 12
        options: [{ value: "0", label: "Off" }, { value: "30", label: "30" }, { value: "100", label: "100" }, { value: "1000", label: "1000" }]
        current: String(page.app.historyLimit)
        onPicked: function(value) { page.app.preference("history_limit", Number(value)) }
      }
    }

    SettingRow {
      title: "Dictation audio"
      caption: page.app.keepDictationAudio ? "Kept with each saved dictation. Off deletes it" : "Off, audio is dropped after transcription"
      Toggle { label: "Keep dictation audio"; checked: page.app.keepDictationAudio; onToggled: page.app.preference("keep_dictation_audio", !checked) }
    }

    SettingRow {
      title: "Training log"
      caption: "Raw and cleaned text, for evaluating cleanup"
      Toggle { label: "Training log"; checked: page.app.trainingLogEnabled; onToggled: page.app.preference("training_log_enabled", !checked) }
    }

    SettingRow {
      title: "Journal"
      caption: "Your own Markdown files"
      Row {
        spacing: 12
        UiText { anchors.verticalCenter: parent.verticalCenter; text: String(page.app.journalSettings.folder || ""); font.family: Theme.mono; font.pixelSize: 12 }
        Pill { anchors.verticalCenter: parent.verticalCenter; kind: "link"; text: "Open"; size: 13; onClicked: page.app.openExternally(page.app.journalSettings.folder_path || page.app.journalSettings.folder) }
      }
    }

    SettingRow {
      title: "To-dos"
      caption: "One Markdown file, To-dos.md"
      last: true
      Row {
        spacing: 12
        UiText { anchors.verticalCenter: parent.verticalCenter; text: String(page.app.todoSettings.folder || ""); font.family: Theme.mono; font.pixelSize: 12 }
        Pill { anchors.verticalCenter: parent.verticalCenter; kind: "link"; text: "Open"; size: 13; onClicked: page.app.openExternally(page.app.todoSettings.folder_path || page.app.todoSettings.folder) }
      }
    }
  }

  Rectangle { width: parent.width; height: 1; color: Theme.divider }

  Item {
    width: parent.width
    height: 36
    UiText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: page.confirmErase ? "History, its audio" + (page.app.trainingLogEnabled ? " and the training log" : "") + " will be deleted. The journal and to-dos stay." : "No screenshots, no keystroke logging, no account."; muted: !page.confirmErase }
    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8
      Pill { visible: page.confirmErase; kind: "fill"; text: "Keep it"; size: 13; onClicked: page.confirmErase = false }
      Pill {
        kind: "danger"
        text: page.confirmErase ? "Delete now" : "Delete saved dictations…"
        size: 13
        onClicked: {
          if (!page.confirmErase) { page.confirmErase = true; return }
          page.app.eraseData()
          page.confirmErase = false
        }
      }
    }
  }
}
