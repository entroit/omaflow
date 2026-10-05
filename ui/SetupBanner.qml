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
        text: banner.problem === "daemon" ? "OmaFlow is installed but not built yet"
          : banner.problem === "version" ? "The window and the daemon are different versions"
          : "One step left before you can dictate"
      }
    }

    UiText {
      x: 25
      width: parent.width - 25
      wrapMode: Text.Wrap
      muted: true
      text: banner.problem === "daemon" ? "The bar icon came from the plugin list, which copies files but never builds. Run the installer once in a terminal."
        : banner.problem === "version" ? "Finish the update in Settings, Updates, or run the installer again from the plugin folder."
        : "Choose a speech model. Nothing was downloaded during installation, and each model lists its size and what it needs to run."
    }

    Row {
      x: 25
      spacing: 8
      Pill {
        visible: banner.problem === "model"
        kind: "primary"; text: "Choose a model"; size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: banner.openSettings("models")
      }
      Pill {
        visible: banner.problem === "daemon"
        kind: "primary"; text: "Copy the command"; size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: banner.app.copy("cd " + banner.app.pluginDir + " && ./install")
      }
      Pill {
        visible: banner.problem === "version"
        kind: "primary"; text: "Open Updates"; size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: banner.openSettings("updates")
      }
    }
  }
}
