import QtQuick

// Your own speech model: a file OmaFlow runs, or a server you run. Every
// field says what is wrong with it before a save bounces off the daemon.
Column {
  id: page
  required property var app
  signal go(string target)
  spacing: 22

  property string engine: app.modelSettings.speech_engine || "nemo"
  readonly property bool managed: engine === "nemo" || engine === "parakeet"
  readonly property bool ready: model.problem === "" && endpoint.problem === "" && health.problem === ""
    && language.problem === "" && (!managed || device.problem === "")

  function originOf(value) {
    var match = String(value).trim().match(/^https?:\/\/[^\/]+/)
    return match ? match[0] : String(value).trim()
  }
  function endpointProblem(value, loopback) {
    var url = String(value).trim()
    if (url.length === 0) return "An address is required."
    if (url.length > 2048) return "At most 2048 characters."
    if (/\s/.test(url)) return "No spaces."
    if (url.indexOf("http://") !== 0 && url.indexOf("https://") !== 0) return "Start with http:// or https://."
    if (loopback) {
      if (!/^http:\/\/(127\.0\.0\.1|localhost):[0-9]+\//.test(url)) return "A model file runs on http://127.0.0.1:PORT/ on this computer."
      if (url.indexOf("/v1/") < 0) return "The path has to contain /v1/, as in /v1/audio/transcriptions."
    }
    return ""
  }

  PageTitle {
    width: parent.width
    backText: "Models"
    onBack: page.go("models")
    title: "Use your own model"
    subtitle: "A model file OmaFlow runs for you, or a server you run. Your audio goes to the address below, so point it at a machine you trust."
  }

  SettingRow {
    title: "What you bring"
    Segmented {
      size: 13
      horizontalPadding: 12
      options: [{ value: "nemo", label: "A model file" }, { value: "openai", label: "OpenAI-compatible server" }, { value: "whisper-cpp", label: "whisper.cpp server" }]
      current: page.managed ? "nemo" : page.engine
      onPicked: function(value) { page.engine = value }
    }
  }

  Field {
    id: model
    width: parent.width
    mono: true
    label: page.managed ? "Model file" : "Model name"
    text: page.app.modelSettings.speech_model || ""
    placeholderText: page.managed ? "/path/to/model.gguf" : "The name your server knows"
    maximumLength: 512
    hint: page.managed ? "An absolute path to a GGUF file, or a model already in the NeMo cache. Nothing is downloaded here."
      : page.engine === "whisper-cpp" ? "Optional. whisper-server loads its own model; this is only shown in OmaFlow."
      : "The model name your server understands."
    problem: text.trim().length === 0 ? (page.engine === "whisper-cpp" ? "" : "A model name or path is required.")
      : text.trim().indexOf("-") === 0 ? "It cannot start with a dash." : ""
  }

  Field {
    id: endpoint
    width: parent.width
    mono: true
    label: "Address"
    text: page.app.modelSettings.speech_endpoint || ""
    placeholderText: page.managed ? "http://127.0.0.1:18103/v1/audio/transcriptions"
      : page.engine === "whisper-cpp" ? "http://127.0.0.1:8080/inference" : "http://127.0.0.1:8000/v1/audio/transcriptions"
    hint: page.managed ? "OmaFlow starts the server on this port." : "The full path, including the port."
    problem: page.endpointProblem(text, page.managed)
  }

  Field {
    id: health
    visible: !page.managed
    width: parent.width
    mono: true
    label: "Health address, optional"
    text: page.app.modelSettings.speech_health_endpoint || ""
    placeholderText: "http://127.0.0.1:8000/health"
    hint: "Answers 2xx once the server is ready. Left empty, OmaFlow asks the address above."
    problem: text.trim().length > 0 ? page.endpointProblem(text, false) : ""
  }

  Row {
    width: parent.width
    spacing: 12
    Field {
      id: language
      width: page.managed ? (parent.width - 12) / 2 : parent.width
      label: "Language"
      text: page.app.modelSettings.speech_language || "auto"
      maximumLength: 32
      hint: "auto, or a code such as de"
      problem: /^[A-Za-z-]{1,32}$/.test(text.trim()) ? "" : "Use auto or a language code."
    }
    Field {
      id: device
      visible: page.managed
      width: (parent.width - 12) / 2
      label: "Device"
      text: page.app.modelSettings.speech_device || "cuda"
      maximumLength: 16
      hint: "auto, cpu, cuda, vulkan or metal"
      problem: ["auto", "cpu", "cuda", "vulkan", "metal"].indexOf(text.trim()) >= 0 ? "" : "Not one of auto, cpu, cuda, vulkan, metal."
    }
  }

  Field {
    id: key
    visible: !page.managed
    width: parent.width
    label: "API key, optional"
    password: true
    placeholderText: page.app.modelSettings.speech_api_key_set ? "A key is stored. Type to replace it." : "Leave empty if your server needs none"
    maximumLength: 512
    hint: "Sent as a bearer token. Stored in your config file, which only your user can read."
  }

  EndpointTester {
    visible: !page.managed
    app: page.app
    url: health.text.trim().length > 0 ? health.text
      : page.engine === "whisper-cpp" ? page.originOf(endpoint.text) + "/health" : endpoint.text
  }

  Row {
    spacing: 8
    Pill {
      kind: "primary"
      text: "Save speech model"
      size: 13
      verticalPadding: 8
      enabled: page.ready
      hint: page.ready ? "" : "Fix the fields marked in red first"
      onClicked: {
        var update = {
          speech_engine: page.managed ? "nemo" : page.engine,
          speech_model: model.text,
          speech_endpoint: endpoint.text,
          speech_health_endpoint: page.managed ? "" : health.text,
          speech_language: language.text,
          speech_device: device.text
        }
        if (key.text.length > 0) update.speech_api_key = key.text
        page.app.preference("models", update)
        key.text = ""
      }
    }
    Pill { visible: !page.managed && page.app.modelSettings.speech_api_key_set === true; kind: "danger"; text: "Remove the stored key"; size: 13; verticalPadding: 8; onClicked: page.app.preference("models", { speech_api_key: "" }) }
    Pill { kind: "link"; text: "Read the guide"; size: 13; verticalPadding: 8; onClicked: page.app.openGuide("custom-models.md") }
  }
}
