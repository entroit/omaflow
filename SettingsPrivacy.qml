import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Everything that answers "where do my words end up" lives here and nowhere
// else, so the question can be settled in one place instead of inferred from
// four scattered switches.
ColumnLayout {
  id: page

  required property var flow
  readonly property bool localSpeech: (page.flow.modelSettings.speech_endpoint || "").indexOf("127.0.0.1") >= 0
    || (page.flow.modelSettings.speech_endpoint || "").indexOf("localhost") >= 0
  readonly property bool localCleanup: !page.flow.cleanupEnabled
    || (page.flow.modelSettings.cleanup_endpoint || "").indexOf("127.0.0.1") >= 0
    || (page.flow.modelSettings.cleanup_endpoint || "").indexOf("localhost") >= 0

  spacing: Style.space(12)

  SettingsHeading {
    title: "Privacy"
    note: "Where your voice and your words go."
  }

  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: whereContent.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: page.localSpeech && page.localCleanup
      ? Util.alpha(Color.accent, 0.12) : Util.alpha(Color.urgent, 0.12)

    ColumnLayout {
      id: whereContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(10)
      spacing: Style.space(4)

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: page.localSpeech && page.localCleanup
          ? "Everything runs on this computer."
          : "Some of your dictation leaves this computer."
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: page.localSpeech && page.localCleanup
          ? "Microphone audio is held in memory, transcribed locally and discarded. It is never written to disk and never sent anywhere."
          : "You have pointed a model at an address that is not this machine. Audio goes to the speech endpoint and your transcript, plus the focused window's title, goes to the cleanup endpoint."
        color: Util.alpha(Color.popups.text, 0.68)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  SettingsHeading {
    title: "History"
    note: "Saved dictations let you reopen, edit and paste something again. They live in a file only your user can read."
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(7)

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: page.flow.historyLimit === 0
        ? "Nothing is saved. Each dictation is gone once it has been pasted."
        : "Keeping the last " + page.flow.historyLimit + " dictations."
      color: Util.alpha(Color.popups.text, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: [0, 30, 100, 1000]

      ActionButton {
        required property int modelData
        text: modelData === 0 ? "Off" : String(modelData)
        foreground: Color.popups.text
        fontSize: Style.font.bodySmall
        selected: page.flow.historyLimit === modelData
        tooltipText: modelData === 0
          ? "Do not save dictations"
          : "Keep the last " + modelData + " dictations"
        Accessible.name: tooltipText
        Accessible.checkable: true
        Accessible.checked: selected
        onClicked: page.flow.preference("history_limit", modelData)
      }
    }
  }

  Toggle {
    Layout.fillWidth: true
    label: "Keep a training log"
    description: "Appends the raw recognition and the cleaned result to a file only you can read, so the cleanup prompt and model can be evaluated later. Off by default, and separate from history: entries stay after history is trimmed."
    foreground: Color.popups.text
    checked: page.flow.trainingLogEnabled
    onClicked: page.flow.preference("training_log_enabled", !checked)
  }

  ActionButton {
    text: page.flow.eraseConfirm ? "Confirm: erase all saved dictations" : "Erase saved dictations…"
    tooltipText: "Deletes the history file" + (page.flow.trainingLogEnabled ? " and the training log" : "") + ". The clipboard is not touched."
    foreground: Color.urgent
    onClicked: {
      if (!page.flow.eraseConfirm) page.flow.eraseConfirm = true
      else { Quickshell.execDetached(["omaflow", "erase-data"]); page.flow.eraseConfirm = false }
    }
  }

  ActionButton {
    visible: page.flow.eraseConfirm
    text: "Keep my data"
    foreground: Color.popups.text
    onClicked: page.flow.eraseConfirm = false
  }
}
