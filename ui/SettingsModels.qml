import QtQuick

// The speech model is the one thing OmaFlow cannot work without, so this page
// leads with what runs now and then offers the alternatives.
Column {
  id: page
  required property var app
  signal go(string target)
  spacing: 22

  readonly property var current: app.speechCatalog.find(function(entry) { return entry.selected }) || null

  PageTitle {
    width: parent.width
    title: "Models"
    subtitle: page.app.gpuMemoryMib > 0
      ? "Speech runs on this computer, using " + (page.app.gpuMemoryMib / 1024).toFixed(1) + " GB of GPU memory right now."
      : "Speech runs on this computer. Downloading a model also switches to it."
  }

  Row {
    spacing: 10
    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: page.app.asrRunning ? Theme.green : page.app.speechDownloading ? Theme.accent : Theme.yellow }
    UiText {
      anchors.verticalCenter: parent.verticalCenter
      text: (page.app.modelSettings.speech_model || "No model chosen") + ", "
        + (page.app.speechDownloading ? "downloading"
          : page.app.asrRunning ? "running"
          : page.app.setupUnfinished ? "not set up yet" : "stopped")
    }
  }

  Rectangle {
    width: parent.width
    height: table.implicitHeight
    radius: Theme.radiusCard + 2
    color: "transparent"
    border.width: 1
    border.color: Theme.divider
    clip: true
    Column {
      id: table
      width: parent.width
      Item {
        width: parent.width
        height: 36
        UiText { x: 14; anchors.verticalCenter: parent.verticalCenter; text: "Model"; muted: true; font.pixelSize: 12 }
        UiText { x: parent.width - 264; anchors.verticalCenter: parent.verticalCenter; text: "Size"; muted: true; font.pixelSize: 12 }
        UiText { x: parent.width - 189; anchors.verticalCenter: parent.verticalCenter; text: "Licence"; muted: true; font.pixelSize: 12 }
      }
      Repeater {
        model: page.app.speechCatalog
        ModelRow { required property var modelData; app: page.app; kind: "speech"; entry: modelData }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 18
    SettingRow {
      title: "Keep models loaded"
      caption: "Off frees memory after five idle minutes"
      Toggle { label: "Keep models loaded"; checked: page.app.keepModelsLoaded; onToggled: page.app.preference("keep_models_loaded", !checked) }
    }
    SettingRow {
      title: "Use your own model"
      caption: "A model file or a server you run"
      last: true
      Pill { kind: "outline"; text: "Open"; size: 13; onClicked: page.go("ownmodel") }
    }
  }

  Pill {
    visible: page.app.setupUnfinished && page.app.modelSettings.speech_model
    kind: "primary"; text: "Start dictating with this model"; size: 13
    onClicked: page.app.preference("models_configured", true)
  }
}
