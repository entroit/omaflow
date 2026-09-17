import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Cleanup is off until you ask for it. It is the one part of OmaFlow that
// rewrites your words, and it costs a second model and several gigabytes, so
// a fresh install transcribes and pastes and nothing more. Turning it on is
// what reveals the model choice, because that is the only moment it matters.
ColumnLayout {
  id: page

  required property var flow
  readonly property bool on: page.flow.cleanupEnabled && page.flow.writingStyle !== "verbatim"
  property string engine: page.flow.modelSettings.cleanup_engine || "ollama"
  readonly property string ollamaCommand:
    page.flow.cleanupRuntime === "missing"
      ? "sudo pacman -S --needed ollama-vulkan && sudo systemctl enable --now ollama"
      : "sudo systemctl start ollama"
  readonly property bool cleanupReady: cleanupModel.problem === "" && cleanupEndpoint.problem === ""

  // Same rules the daemon applies, said in the field rather than after a save.
  function endpointProblem(value) {
    var url = String(value).trim()
    if (url.length === 0) return "An address is required."
    if (url.length > 2048) return "At most 2048 characters."
    if (/\s/.test(url)) return "No spaces."
    if (url.indexOf("http://") !== 0 && url.indexOf("https://") !== 0) return "Must start with http:// or https://."
    if (page.engine === "openai") {
      if (!/\/v1\/chat\/completions$/.test(url)) return "The address has to end in /v1/chat/completions."
    } else if (!/\/api\/chat$/.test(url)) {
      return "The address has to end in /api/chat."
    }
    return ""
  }

  spacing: Style.space(12)

  SettingsHeading {
    title: "Cleanup"
    note: "What happens to your words between the microphone and the paste."
  }

  Toggle {
    Layout.fillWidth: true
    label: "Natural cleanup"
    description: "Removes fillers and repeated words, applies the corrections you speak out loud, and adds punctuation and paragraphs — without changing what you said. The title of the focused window tells the model whether it is writing a chat message, an email or code. Off pastes the exact recognized wording. Custom vocabulary applies either way."
    foreground: Color.popups.text
    checked: page.on
    onClicked: page.flow.preference("enabled", !checked)
  }

  // Ollama is not installed by ./install any more, so the first time anyone
  // turns cleanup on they may not have it. Say so here with the command,
  // rather than letting every dictation quietly fall back to raw text.
  Rectangle {
    visible: page.on && page.flow.cleanupRuntime !== "ready"
    Layout.fillWidth: true
    Layout.preferredHeight: runtimeNotice.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: Util.alpha(Color.urgent, 0.13)

    RowLayout {
      id: runtimeNotice
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(10)
      spacing: Style.space(10)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: page.engine === "ollama"
            ? (page.flow.cleanupRuntime === "missing"
              ? "Cleanup runs on Ollama, which is not installed."
              : "Ollama is installed but not answering.")
            : "The cleanup server is not answering."
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          visible: page.engine === "ollama"
          Layout.fillWidth: true
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: page.ollamaCommand
          color: Util.alpha(Color.popups.text, 0.68)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ActionButton {
        visible: page.engine === "ollama"
        text: "Copy command"
        foreground: Color.popups.text
        bordered: true
        onClicked: Quickshell.execDetached(["wl-copy", page.ollamaCommand])
      }
    }
  }

  SettingsHeading {
    visible: page.on
    title: "Cleanup model"
    note: page.engine === "ollama"
      ? "Bigger models follow spoken corrections and formatting commands more reliably. Downloads run in the background; you can keep dictating without cleanup while one finishes."
      : "Choose the model name and full chat-completions address used by your server."
  }

  Text {
    visible: page.on
    Layout.fillWidth: true
    text: "Cleanup server protocol"
    color: Util.alpha(Color.popups.text, 0.72)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  RowLayout {
    visible: page.on
    spacing: Style.space(6)

    ActionButton {
      text: "Ollama"
      foreground: Color.popups.text
      selected: page.engine === "ollama"
      onClicked: page.engine = "ollama"
    }

    ActionButton {
      text: "OpenAI-compatible"
      foreground: Color.popups.text
      selected: page.engine === "openai"
      onClicked: page.engine = "openai"
    }

    Item { Layout.fillWidth: true }
  }

  Repeater {
    model: page.on && page.engine === "ollama" ? page.flow.cleanupCatalog : []

    ModelCard {
      required property var modelData
      flow: page.flow
      kind: "cleanup"
      entry: modelData
    }
  }

  ActionButton {
    id: customDisclosure
    visible: page.on
    text: page.flow.editCleanupModel
      ? "Hide server settings"
      : (page.engine === "openai" ? "Configure server…" : "Use another Ollama model…")
    foreground: Util.alpha(Color.popups.text, 0.8)
    onClicked: {
      page.flow.editCleanupModel = !page.flow.editCleanupModel
      if (page.flow.editCleanupModel) revealTimer.restart()
    }
  }

  // One frame's delay: the layout has to grow before the target has a place to
  // scroll to.
  Timer {
    id: revealTimer
    interval: 16
    onTriggered: page.flow.revealInSettings(customDisclosure)
  }

  ColumnLayout {
    visible: page.on && page.flow.editCleanupModel
    Layout.fillWidth: true
    spacing: Style.space(7)

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: page.engine === "openai"
        ? "The transcript and focused window title go to this server. Optional clipboard context goes too when enabled. Use a server you trust."
        : "Any tag you have pulled yourself works. Point the endpoint at another machine's Ollama if you run one. The transcript and window title go to that server, so use one you trust."
      color: Util.alpha(Color.popups.text, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    LabeledField {
      id: cleanupModel
      label: page.engine === "openai" ? "Model" : "Ollama model tag"
      text: page.flow.modelSettings.cleanup_model || ""
      placeholderText: page.engine === "openai" ? "model-name" : "qwen3:8b"
      maximumLength: 512
      hint: page.engine === "openai"
        ? "The model name understood by your server."
        : "Any tag your server already has. Run `ollama list` to see them, `ollama pull` to add one."
      problem: text.trim().length === 0 ? "A model tag is required."
        : text.length > 512 ? "At most 512 characters."
        : text.trim().indexOf("-") === 0 ? "It cannot start with a dash."
        : ""
    }

    LabeledField {
      id: cleanupEndpoint
      label: page.engine === "openai" ? "Server address" : "Ollama address"
      text: page.flow.modelSettings.cleanup_endpoint || ""
      placeholderText: page.engine === "openai"
        ? "http://127.0.0.1:4000/v1/chat/completions"
        : "http://127.0.0.1:11434/api/chat"
      hint: page.engine === "openai"
        ? "Use the full /v1/chat/completions address."
        : "Include the port and keep the /api/chat path."
      problem: page.endpointProblem(text)
    }

    LabeledField {
      id: cleanupKey
      label: "API key (optional)"
      password: true
      placeholderText: page.flow.modelSettings.cleanup_api_key_set
        ? "A key is stored. Type to replace it." : "Leave empty if your server needs no key"
      maximumLength: 512
      hint: "Sent as an Authorization: Bearer header. Stored in your config file, which only your user can read."
    }

    ActionButton {
      visible: page.flow.modelSettings.cleanup_api_key_set === true
      text: "Remove the stored key"
      foreground: Color.urgent
      onClicked: page.flow.preference("models", { cleanup_api_key: "" })
    }

    EndpointTester {
      Layout.fillWidth: true
      cleanupTest: true
    }

    Text {
      Layout.fillWidth: true
      wrapMode: Text.Wrap
      text: "Save changes before testing. The test uses the saved endpoint, model and key, not unsaved fields. It sends one short synthetic prompt and may incur a provider charge. No dictation or clipboard text is sent."
      color: Util.alpha(Color.popups.text, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    ActionButton {
      text: "Save cleanup model"
      foreground: Color.popups.text
      background: Util.alpha(Color.accent, 0.22)
      bordered: true
      enabled: page.cleanupReady
      tooltipText: page.cleanupReady ? "" : "Fix the fields marked in red first"
      onClicked: {
        var update = {
          cleanup_engine: page.engine,
          cleanup_model: cleanupModel.text,
          cleanup_endpoint: cleanupEndpoint.text
        }
        // Empty means "keep the stored key", not "delete it"; Remove does that.
        if (cleanupKey.text.length > 0) update.cleanup_api_key = cleanupKey.text
        page.flow.preference("models", update)
        cleanupKey.text = ""
      }
    }
  }

  Text {
    visible: !page.on
    Layout.fillWidth: true
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    text: "With cleanup off, OmaFlow pastes exactly what the speech model recognized. Nothing is downloaded and no second model is loaded."
    color: Util.alpha(Color.popups.text, 0.55)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
