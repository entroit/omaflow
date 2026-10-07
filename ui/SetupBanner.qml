import QtQuick

// What stands between this computer and the first dictation, with the one
// button that fixes it. Hidden when nothing does.
Rectangle {
  id: banner

  required property var app
  signal openSettings(string target)

  readonly property string problem: !app.binaryFound ? "daemon"
    : app.connected && app.setupUnfinished && !app.speechDownloading ? "model"
    : app.connected && !app.supportedState ? "version"
    : ""

  readonly property string installCommand: "cd " + app.pluginDir + " && ./install"
  // The clipboard says nothing back, so the button does for a moment.
  property bool copied: false
  Timer { id: copiedTimer; interval: 2000; onTriggered: banner.copied = false }

  visible: problem.length > 0
  height: visible ? content.implicitHeight + 40 : 0
  radius: Theme.radiusPanel
  color: Theme.fill4
  border.width: 1
  border.color: problem === "version" || problem === "daemon" ? Theme.red : Theme.yellow

  Column {
    id: content
    x: 20; y: 20
    width: parent.width - 40
    spacing: 14

    Row {
      spacing: 10
      Icon { anchors.verticalCenter: parent.verticalCenter; name: "warning"; size: 15; color: banner.problem === "model" ? Theme.yellow : Theme.red }
      UiText {
        anchors.verticalCenter: parent.verticalCenter
        font.pixelSize: 16
        weight: Font.Bold
        text: banner.problem === "daemon" ? "One command finishes installing OmaFlow"
          : banner.problem === "version" ? "OmaFlow is only partly updated"
          : "One step left before you can dictate"
      }
    }

    UiText {
      x: 25
      width: parent.width - 25
      wrapMode: Text.Wrap
      muted: true
      text: banner.problem === "daemon" ? "Adding the plugin copied its files. Paste this in a terminal:"
        : banner.problem === "version" ? "Part of OmaFlow is still on the old version. Paste this in a terminal:"
        : banner.app.missingSpeechModel ? String(banner.app.missingSpeechModel.label || banner.app.missingSpeechModel.id)
          + " is chosen but not downloaded yet. Nothing was downloaded during installation."
        : "Choose a speech model. Nothing was downloaded during installation, and each model lists its size and what it needs to run."
    }

    // The installer finishes a first install and a half-done update alike.
    Rectangle {
      visible: banner.problem === "daemon" || banner.problem === "version"
      x: 25
      width: Math.min(parent.width - 25, command.implicitWidth + 24)
      height: command.implicitHeight + 16
      radius: Theme.radiusInput
      color: Theme.fill8
      UiText {
        id: command
        x: 12
        width: parent.width - 24
        anchors.verticalCenter: parent.verticalCenter
        // A word joiner keeps "./install" whole when the line wraps.
        text: banner.installCommand.replace("./install", "./\u2060install")
        font.family: Theme.mono
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }

    Row {
      x: 25
      spacing: 8
      Pill {
        visible: banner.problem === "model"
        kind: "primary"; text: banner.app.missingSpeechModel ? "Download the speech model" : "Choose a speech model"
        size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: banner.openSettings("models")
      }
      Pill {
        visible: banner.problem === "daemon" || banner.problem === "version"
        kind: "primary"; text: banner.copied ? "Copied" : "Copy command"; size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: { banner.app.copy(banner.installCommand); banner.copied = true; copiedTimer.restart() }
      }
    }
  }
}
