import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The speech model is the one thing OmaFlow cannot work without, so this page
// leads with what is running right now and only then offers the alternatives.
ColumnLayout {
  id: page

  required property var flow
  property string engine: page.flow.modelSettings.speech_engine || "nemo"
  readonly property bool managed: page.engine === "nemo" || page.engine === "parakeet"
  readonly property bool speechReady: speechModel.problem === "" && speechEndpoint.problem === ""
    && speechHealth.problem === "" && speechLanguage.problem === ""
    && (!page.managed || speechDevice.problem === "")

  function originOf(value) {
    var match = String(value).trim().match(/^https?:\/\/[^\/]+/)
    return match ? match[0] : String(value).trim()
  }

  // Mirrors config.rs: the daemon rejects these too, but a save that bounces
  // teaches nothing about which of six fields was wrong.
  function endpointProblem(value, mustBeLoopback) {
    var url = String(value).trim()
    if (url.length === 0) return "A server address is required."
    if (url.length > 2048) return "At most 2048 characters."
    if (/\s/.test(url)) return "No spaces."
    if (url.indexOf("http://") !== 0 && url.indexOf("https://") !== 0) return "Must start with http:// or https://."
    if (mustBeLoopback) {
      if (!/^http:\/\/(127\.0\.0\.1|localhost):[0-9]+\//.test(url))
        return "Managed NeMo needs http://127.0.0.1:PORT/… or localhost with a port."
      // The health check is derived by splitting here, so without it the
      // server would start and then never be seen as ready.
      if (url.indexOf("/v1/") < 0)
        return "The path has to contain /v1/, as in /v1/audio/transcriptions."
    }
    return ""
  }

  spacing: Style.space(12)

  SettingsHeading {
    title: "Speech recognition"
    note: "The model that turns your voice into words. It runs on this computer; audio stays in memory and is never written to disk."
  }

  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: statusRow.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: Util.alpha(Color.popups.text, 0.055)

    RowLayout {
      id: statusRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(10)
      spacing: Style.space(9)

      Rectangle {
        Layout.preferredWidth: Style.space(8)
        Layout.preferredHeight: Style.space(8)
        radius: width / 2
        color: page.flow.asrRunning ? Color.accent : Util.alpha(Color.popups.text, 0.3)
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          wrapMode: Text.WrapAnywhere
          text: page.flow.modelSettings.speech_model || "No model selected"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: page.flow.speechDownloading ? "Downloading"
            : page.flow.asrRunning ? (page.managed ? "Running locally" : "Server is reachable")
            : page.flow.modelSettings.configured === false ? "Not set up yet"
            : "Stopped"
          color: Util.alpha(Color.popups.text, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        visible: page.flow.gpuMemoryMib > 0
        textFormat: Text.PlainText
        text: (page.flow.gpuMemoryMib / 1024).toFixed(1) + " GB GPU"
        color: Util.alpha(Color.popups.text, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  SettingsHeading {
    title: "Available models"
    note: "Downloading a model also switches to it. The download runs in the background and survives closing this panel."
  }

  Repeater {
    model: page.flow.speechCatalog

    ModelCard {
      required property var modelData
      flow: page.flow
      kind: "speech"
      entry: modelData
    }
  }

  ActionButton {
    id: customDisclosure
    text: page.flow.editModels ? "Hide your own model" : "Use your own model or server…"
    foreground: Util.alpha(Color.popups.text, 0.8)
    onClicked: {
      page.flow.editModels = !page.flow.editModels
      // The form opens below the fold. Scroll to it, or the click reads as a
      // button that did nothing.
      if (page.flow.editModels) revealTimer.restart()
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
    visible: page.flow.editModels
    Layout.fillWidth: true
    spacing: Style.space(7)

    // Two plain questions instead of one choice between three product names.
    // "NeMo" and "Compatible API" were the same protocol — the difference is
    // only who starts the server — and nobody choosing a dictation model
    // should have to know an NVIDIA toolkit's name to answer that.
    //
    // The first question echoes the disclosure that opened this form, "your
    // own model or server", because a model file is still your own model:
    // OmaFlow just hosts it. Naming that button after OmaFlow hid it.
    Text {
      textFormat: Text.PlainText
      text: "What are you bringing?"
      color: Util.alpha(Color.popups.text, 0.72)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    RowLayout {
      spacing: Style.space(6)

      ActionButton {
        text: "A model file"
        foreground: Color.popups.text
        selected: page.managed
        tooltipText: "You have weights on disk. OmaFlow runs the server for them."
        onClicked: page.engine = "nemo"
      }

      ActionButton {
        text: "A server I run"
        foreground: Color.popups.text
        selected: !page.managed
        tooltipText: "You already have a transcription server running. OmaFlow talks to it."
        // Coming from a model file there is no previous answer to keep, and the
        // OpenAI shape is what nearly every self-hosted server speaks.
        onClicked: if (page.managed) page.engine = "openai"
      }

      Item { Layout.fillWidth: true }
    }

    Text {
      visible: !page.managed
      textFormat: Text.PlainText
      text: "What does your server speak?"
      color: Util.alpha(Color.popups.text, 0.72)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    RowLayout {
      visible: !page.managed
      spacing: Style.space(6)

      ActionButton {
        text: "OpenAI-compatible"
        foreground: Color.popups.text
        selected: page.engine === "openai"
        tooltipText: "The /v1/audio/transcriptions shape that most self-hosted speech servers implement"
        onClicked: page.engine = "openai"
      }

      ActionButton {
        text: "whisper.cpp"
        foreground: Color.popups.text
        selected: page.engine === "whisper-cpp"
        tooltipText: "whisper-server's own /inference endpoint"
        onClicked: page.engine = "whisper-cpp"
      }

      Item { Layout.fillWidth: true }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: page.managed
        ? "Give OmaFlow an absolute path to a GGUF file, or a repository already unpacked in the NeMo cache, and it starts and stops the server for you. Nothing is downloaded here; the weights have to be on disk already."
        : page.engine === "whisper-cpp"
          ? "You start whisper-server; OmaFlow talks to its /inference endpoint. Pick the model when you start it, and keep language detection by leaving Language on auto."
          : "You start the server; OmaFlow posts to its /v1/audio/transcriptions endpoint. vLLM, Speaches, LocalAI and most other self-hosted speech servers speak this. It names a protocol, not a company: nothing is sent to OpenAI."
      color: Util.alpha(Color.popups.text, 0.62)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    LabeledField {
      id: speechModel
      label: "Model"
      text: page.flow.modelSettings.speech_model || ""
      placeholderText: page.managed ? "/path/to/model.gguf" : "Model name your server understands"
      maximumLength: 512
      hint: page.managed
        ? "An absolute path to a GGUF file is the safest answer when the cache holds several revisions."
        : page.engine === "whisper-cpp"
          ? "Optional, and never sent. whisper-server loads its own model; this is only what the panel displays."
          : "Required. The name your server knows the model by."
      problem: text.trim().length === 0
          ? (page.engine === "whisper-cpp" ? "" : "A model name or path is required.")
        : text.length > 512 ? "At most 512 characters."
        : text.trim().indexOf("-") === 0 ? "It cannot start with a dash."
        : ""
    }

    LabeledField {
      id: speechEndpoint
      label: "Server address"
      text: page.flow.modelSettings.speech_endpoint || ""
      placeholderText: page.managed
        ? "http://127.0.0.1:18103/v1/audio/transcriptions"
        : page.engine === "whisper-cpp"
          ? "http://127.0.0.1:8080/inference"
          : "http://127.0.0.1:8000/v1/audio/transcriptions"
      hint: page.managed
        ? "The port in this address is the port OmaFlow starts the server on. It must be 127.0.0.1 or localhost."
        : "The full path, not just the host. Include the port your server listens on."
      problem: page.endpointProblem(text, page.managed)
    }

    LabeledField {
      id: speechHealth
      label: "Health address (optional)"
      visible: !page.managed
      text: page.flow.modelSettings.speech_health_endpoint || ""
      placeholderText: "http://127.0.0.1:8000/health"
      hint: page.engine === "whisper-cpp"
        ? "Optional. Left empty, OmaFlow checks whisper-server's own /health."
        : "Optional. A URL that returns 2xx once the server is ready. Left empty, OmaFlow probes the address above."
      problem: text.trim().length > 0 ? page.endpointProblem(text, false) : ""
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      LabeledField {
        id: speechLanguage
        label: "Language"
        text: page.flow.modelSettings.speech_language || "auto"
        placeholderText: "auto"
        maximumLength: 32
        hint: "auto, or a code such as de."
        problem: /^[A-Za-z-]{1,32}$/.test(text.trim()) ? "" : "Use auto or a language code."
      }

      LabeledField {
        id: speechDevice
        label: "Device"
        visible: page.managed
        text: page.flow.modelSettings.speech_device || "cuda"
        placeholderText: "cuda"
        maximumLength: 16
        hint: "auto, cpu, cuda, vulkan or metal."
        problem: ["auto", "cpu", "cuda", "vulkan", "metal"].indexOf(text.trim()) >= 0
          ? "" : "Not one of auto, cpu, cuda, vulkan, metal."
      }
    }

    LabeledField {
      id: speechKey
      label: "API key (optional)"
      visible: !page.managed
      password: true
      placeholderText: page.flow.modelSettings.speech_api_key_set
        ? "A key is stored. Type to replace it." : "Leave empty if your server needs no key"
      maximumLength: 512
      hint: "Sent as an Authorization: Bearer header. Stored in your config file, which only your user can read."
    }

    ActionButton {
      visible: !page.managed && page.flow.modelSettings.speech_api_key_set === true
      text: "Remove the stored key"
      foreground: Color.urgent
      onClicked: page.flow.preference("models", { speech_api_key: "" })
    }

    // Managed NeMo is not running yet when you are filling this in, so testing
    // its own address would always fail. There is nothing to ask.
    EndpointTester {
      Layout.fillWidth: true
      visible: !page.managed
      // Ask the same URL the daemon asks. whisper-server's /inference answers
      // 404 to a GET, so probing it would report a failure for a setup the
      // daemon is perfectly happy with.
      url: speechHealth.text.trim().length > 0
        ? speechHealth.text
        : page.engine === "whisper-cpp"
          ? page.originOf(speechEndpoint.text) + "/health"
          : speechEndpoint.text
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "Your audio goes to whatever address you enter here. Keep it on this computer to keep dictation local."
      color: Util.alpha(Color.popups.text, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    ActionButton {
      text: "Read the custom model guide"
      foreground: Color.accent
      tooltipText: "What each engine needs, and how to point OmaFlow at your own model or server"
      onClicked: page.flow.openGuide("custom-models.md")
    }

    ActionButton {
      text: "Save speech model"
      foreground: Color.popups.text
      background: Util.alpha(Color.accent, 0.22)
      bordered: true
      enabled: page.speechReady
      tooltipText: page.speechReady ? "" : "Fix the fields marked in red first"
      onClicked: {
        var update = {
          speech_engine: page.engine,
          speech_model: speechModel.text,
          speech_endpoint: speechEndpoint.text,
          // A managed engine derives its own health URL; carrying a stale one
          // over from an external server would decide readiness for NeMo.
          speech_health_endpoint: page.managed ? "" : speechHealth.text,
          speech_language: speechLanguage.text,
          speech_device: speechDevice.text
        }
        if (speechKey.text.length > 0) update.speech_api_key = speechKey.text
        page.flow.preference("models", update)
        speechKey.text = ""
      }
    }

    ActionButton {
      visible: page.flow.modelSettings.configured === false
      text: "Enable dictation with this model"
      foreground: Color.popups.text
      bordered: true
      onClicked: page.flow.preference("models_configured", true)
    }
  }
}
