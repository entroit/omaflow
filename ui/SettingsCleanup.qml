import QtQuick

// Medium cleanup's model. The level itself is chosen in Basics; this page is
// for which model does the work and where it runs.
Column {
  id: page
  required property var app
  signal go(string target)
  spacing: 22

  property string engine: app.modelSettings.cleanup_engine || "ollama"
  property bool showServer: engine === "openai"
  readonly property string ollamaCommand: app.cleanupRuntime === "missing"
    ? "sudo pacman -S --needed ollama-vulkan && sudo systemctl enable --now ollama"
    : "sudo systemctl start ollama"
  readonly property bool ready: model.problem === "" && endpoint.problem === ""
  // Why Save can't run yet, naming the field, shown beside the button.
  readonly property string blocker: model.problem !== "" ? (model.text.trim().length === 0 ? "Enter a model first." : "Fix the model first.")
    : endpoint.problem !== "" ? (endpoint.text.trim().length === 0 ? "Enter an address first." : "Fix the address first.")
    : ""
  // Removing a stored key asks once, like the other deletes in Settings.
  property bool confirmRemoveKey: false
  // The saved server, by host, for the card that says it is not answering.
  readonly property string serverHost: {
    if (app.modelSettings.cleanup_engine !== "openai") return ""
    var url = String(app.modelSettings.cleanup_endpoint || "").trim()
    return (url.match(/^https?:\/\/([^\/]+)/) || [])[1] || url
  }

  function endpointProblem(value) {
    var url = String(value).trim()
    if (url.length === 0) return "An address is required."
    if (/\s/.test(url)) return "No spaces."
    if (url.indexOf("http://") !== 0 && url.indexOf("https://") !== 0) return "Start with http:// or https://."
    if (page.engine === "openai" && !/\/v1\/chat\/completions$/.test(url)) return "The address has to end in /v1/chat/completions."
    if (page.engine !== "openai" && !/\/api\/chat$/.test(url)) return "The address has to end in /api/chat."
    return ""
  }

  PageTitle { width: parent.width; title: "Cleanup"; subtitle: "The level is set in Basics. This is the model Medium uses, and where it runs." }

  Rectangle {
    visible: page.app.cleanupLevel !== "medium"
    width: parent.width
    height: 56
    radius: Theme.radiusCard
    color: Theme.fill4
    UiText { x: 16; anchors.verticalCenter: parent.verticalCenter; text: "Cleanup is " + (page.app.cleanupLevel === "light" ? "Light, which needs no model." : "off.") }
    Pill { anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; kind: "outline"; text: "Use Medium"; size: 13; onClicked: page.app.setCleanupLevel("medium") }
  }

  Rectangle {
    visible: page.app.cleanupLevel === "medium" && page.app.cleanupRuntime !== "ready"
    width: parent.width
    height: runtime.implicitHeight + 32
    radius: Theme.radiusCard
    color: Theme.fill4
    border.width: 1
    border.color: Theme.yellow
    Column {
      id: runtime
      x: 16; y: 16
      width: parent.width - 32
      spacing: 8
      UiText {
        text: page.engine === "ollama" ? (page.app.cleanupRuntime === "missing" ? "Cleanup runs on Ollama, which is not installed." : "Ollama is installed but not answering.")
          : (page.serverHost ? page.serverHost : "The cleanup server") + " is not answering."
        width: parent.width
        wrapMode: Text.Wrap
        weight: Font.DemiBold
      }
      UiText {
        visible: page.engine !== "ollama"
        width: parent.width
        wrapMode: Text.Wrap
        text: "Start it or check the address below, then test the connection."
      }
      // The command wraps at its spaces, and Copy under it, at the narrowest
      // window; Copy still takes it whole.
      Flow {
        visible: page.engine === "ollama"
        width: parent.width
        spacing: 10
        UiText { width: Math.min(implicitWidth, parent.width); wrapMode: Text.Wrap; text: page.ollamaCommand; font.family: Theme.mono; font.pixelSize: 12; muted: true; height: Math.max(implicitHeight, copyOllama.height) }
        Pill {
          id: copyOllama
          // The clipboard says nothing back, so the button does for a moment.
          property bool copied: false
          Timer { id: copiedTimer; interval: 2000; onTriggered: copyOllama.copied = false }
          kind: "fill"; text: copied ? "Copied" : "Copy"
          Accessible.name: "Copy the command"
          onClicked: { page.app.copy(page.ollamaCommand); copied = true; copiedTimer.restart() }
        }
      }
      UiText { width: parent.width; wrapMode: Text.Wrap; muted: true; text: "Until it answers, dictations are pasted as raw text, and the card says so." }
    }
  }

  Rectangle {
    visible: page.engine === "ollama"
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
      // The same columns as the speech models on Models.
      Item {
        width: parent.width
        height: 36
        UiText { x: 14; anchors.verticalCenter: parent.verticalCenter; text: "Model"; muted: true; font.pixelSize: 12 }
        UiText { x: parent.width - 250; anchors.verticalCenter: parent.verticalCenter; text: "Size"; muted: true; font.pixelSize: 12 }
      }
      Repeater {
        model: page.app.cleanupCatalog
        ModelRow { required property var modelData; required property int index; last: index === page.app.cleanupCatalog.length - 1; app: page.app; kind: "cleanup"; entry: modelData }
      }
    }
  }

  // Most people pick from the table; a server of your own is one step away.
  Pill {
    kind: "link"
    text: page.showServer ? "Hide server settings" : "Use another model or machine"
    size: 13
    horizontalPadding: 0
    onClicked: page.showServer = !page.showServer
  }

  Column {
    visible: page.showServer
    width: parent.width
    spacing: 18

    SettingRow {
      title: "Runs on"
      Segmented {
        name: "Runs on"
        options: [{ value: "ollama", label: "Ollama" }, { value: "openai", label: "OpenAI-compatible" }]
        current: page.engine
        onPicked: function(value) { page.engine = value }
      }
    }

    Field {
      id: model
      deferProblem: true
      width: parent.width
      mono: true
      label: page.engine === "openai" ? "Model" : "Ollama model tag"
      text: page.app.modelSettings.cleanup_model || ""
      placeholderText: page.engine === "openai" ? "model-name" : "qwen3:8b"
      maximumLength: 512
      hint: page.engine === "openai" ? "The model name your server understands." : "Any tag your Ollama already has. ollama list shows them."
      problem: text.trim().length === 0 ? "A model is required." : text.trim().indexOf("-") === 0 ? "It cannot start with a dash." : ""
    }
    Field {
      id: endpoint
      deferProblem: true
      width: parent.width
      mono: true
      label: "Address"
      text: page.app.modelSettings.cleanup_endpoint || ""
      placeholderText: page.engine === "openai" ? "http://127.0.0.1:4000/v1/chat/completions" : "http://127.0.0.1:11434/api/chat"
      hint: "Your raw text and the focused window's title go here."
      problem: page.endpointProblem(text)
    }
    Field {
      id: key
      width: parent.width
      label: "API key, optional"
      password: true
      placeholderText: page.app.modelSettings.cleanup_api_key_set ? "A key is stored. Type to replace it." : "Leave empty if your server needs none"
      maximumLength: 512
      hint: "Sent as a bearer token. Stored in your config file, which only your user can read."
    }
    // Tried before it is saved, as on Your own model.
    EndpointTester {
      app: page.app
      cleanupTest: true
      enabled: page.ready
      cleanupSettings: {
        var settings = { cleanup_engine: page.engine, cleanup_model: model.text, cleanup_endpoint: endpoint.text }
        if (key.text.length > 0) settings.cleanup_api_key = key.text
        return settings
      }
    }
    UiText { width: parent.width; wrapMode: Text.Wrap; muted: true; font.pixelSize: 12; text: "The test sends one short made-up sentence to the model and address above, before you save. It never sends a dictation." }
    Row {
      spacing: 8
      Pill {
        kind: "primary"; text: "Save cleanup model"; size: 13; verticalPadding: 8
        enabled: page.ready
        hint: page.blocker
        onClicked: {
          var update = { cleanup_engine: page.engine, cleanup_model: model.text, cleanup_endpoint: endpoint.text }
          if (key.text.length > 0) update.cleanup_api_key = key.text
          page.app.preference("models", update)
          key.text = ""
        }
      }
      UiText { visible: !page.ready; anchors.verticalCenter: parent.verticalCenter; text: page.blocker; muted: true; font.pixelSize: 12 }
      Pill { visible: page.app.modelSettings.cleanup_api_key_set === true && !page.confirmRemoveKey; kind: "danger"; text: "Remove the stored key"; size: 13; verticalPadding: 8; onClicked: page.confirmRemoveKey = true }
      Pill { visible: page.confirmRemoveKey && page.app.modelSettings.cleanup_api_key_set === true; kind: "fill"; text: "Keep it"; size: 13; verticalPadding: 8; onClicked: page.confirmRemoveKey = false }
      Pill {
        visible: page.confirmRemoveKey && page.app.modelSettings.cleanup_api_key_set === true
        kind: "danger"; text: "Remove key"; size: 13; verticalPadding: 8
        Accessible.name: "Remove the stored cleanup API key"
        onClicked: { page.app.preference("models", { cleanup_api_key: "" }); page.confirmRemoveKey = false }
      }
    }
  }
}
