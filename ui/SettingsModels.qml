import QtQuick

// The speech model is the one thing OmaFlow cannot work without, so this page
// leads with what runs now and then offers the alternatives.
Column {
  id: page
  required property var app
  signal go(string target)
  spacing: 22

  readonly property var current: app.speechCatalog.find(function(entry) { return entry.selected }) || null
  readonly property string memory: app.gpuMemoryMib > 0 ? (app.gpuMemoryMib / 1024).toFixed(1) + " GB" : ""
  // Which runtime build runs speech here. On the CPU the model rows show
  // times instead of GPU memory, and those times come from one computer.
  readonly property bool onCpu: app.modelCatalog.speech_runtime === "cpu"
  // The model by name, a file of your own by its file name.
  readonly property string currentName: current ? String(current.label || current.id)
    : String(app.modelSettings.speech_model || "").split("/").pop()

  PageTitle {
    width: parent.width
    title: "Models"
    subtitle: page.onCpu ? (page.app.modelCatalog.nvidia_gpu ? "Speech runs on the CPU." : "This computer has no NVIDIA GPU, so speech runs on the CPU.")
        + " Times below are from a 6-core desktop CPU."
      : page.memory.length === 0 ? "Speech runs on this computer."
      : (page.app.cleanupLevel === "medium" ? "Speech and cleanup use " : "Speech uses ") + page.memory + " of GPU memory right now."
  }

  // The model in use says so in its row. This line is for what a row cannot
  // say: a chosen model that is not here yet, your own model, or none at all.
  Row {
    visible: status.text.length > 0
    spacing: 10
    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: page.app.asrRunning ? Theme.green : page.app.asrFailed === true ? Theme.red : page.app.speechDownloading ? Theme.accent : Theme.yellow }
    UiText {
      id: status
      anchors.verticalCenter: parent.verticalCenter
      // A file name of your own can be long; it wraps rather than running off.
      width: Math.min(implicitWidth, page.width - 18)
      wrapMode: Text.Wrap
      text: page.current ? (page.current.installed ? "" : page.currentName
          + (page.app.speechDownloading ? " is downloading." : " is not downloaded yet."))
        : page.currentName ? page.currentName + " is in use, " + (page.app.asrRunning ? "loaded." : page.app.asrFailed === true ? "stopped." : "not loaded right now.")
        : "No speech model is chosen yet. Download one below."
    }
  }

  // Finishing setup sits under the status, not below the fold. A catalog
  // model has to be downloaded first; your own model is taken as set up.
  Pill {
    visible: page.app.setupUnfinished && (page.current ? page.current.installed === true : Boolean(page.app.modelSettings.speech_model))
    kind: "primary"; text: "Start dictating with " + page.currentName; size: 13
    onClicked: page.app.preference("models_configured", true)
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
        UiText { x: parent.width - 250; anchors.verticalCenter: parent.verticalCenter; text: "Size"; muted: true; font.pixelSize: 12 }
      }
      Repeater {
        model: page.app.speechCatalog
        ModelRow { required property var modelData; required property int index; last: index === page.app.speechCatalog.length - 1; app: page.app; kind: "speech"; entry: modelData }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 18
    SettingRow {
      title: "Keep models loaded"
      caption: (page.memory ? "On: answers at once and holds " + page.memory + ". Off: frees it" : "On: answers at once. Off: frees " + (page.onCpu ? "memory" : "GPU memory"))
        + " after five idle minutes, and the next dictation waits to load."
      toggle: keepLoaded
      Toggle { id: keepLoaded; label: "Keep models loaded"; checked: page.app.keepModelsLoaded; onToggled: page.app.preference("keep_models_loaded", !checked) }
    }
    SettingRow {
      title: "Use your own model"
      caption: "A model file or a server you run"
      last: true
      Pill { kind: "outline"; text: "Set up"; size: 13; Accessible.name: "Set up your own model"; onClicked: page.go("ownmodel") }
    }
  }
}
