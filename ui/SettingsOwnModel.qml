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
  // An empty model field is not an error before you type, but it can't be saved.
  readonly property bool modelMissing: model.text.trim().length === 0 && engine !== "whisper-cpp"
  readonly property bool ready: blocker === ""
  // Why Save can't run yet, naming the field, shown beside the button.
  readonly property string blocker: modelMissing ? (managed ? "Enter a model file first." : "Enter a model name first.")
    : model.problem !== "" ? (managed ? "Fix the model file first." : "Fix the model name first.")
    : !managed && endpoint.text.trim().length === 0 ? "Enter an address first."
    : !managed && endpoint.problem !== "" ? "Fix the address first."
    : !managed && health.problem !== "" ? "Fix the health address first."
    : language.problem !== "" ? "Fix the language first."
    : ""
  // Removing a stored key asks once, like the other deletes in Settings.
  property bool confirmRemoveKey: false
  // The saved engine runs a model file, so the saved address is OmaFlow's own
  // port; a server starts from an empty address instead.
  readonly property bool savedManaged: ["nemo", "parakeet"].indexOf(app.modelSettings.speech_engine || "nemo") >= 0
  // Where OmaFlow runs a model file. It picks the port, so there is no address to fill in.
  readonly property string managedEndpoint: endpointProblem(app.modelSettings.speech_endpoint || "", true) === ""
    ? app.modelSettings.speech_endpoint : "http://127.0.0.1:18103/v1/audio/transcriptions"
  // A catalog model is chosen on Models; this page only shows a model you brought.
  readonly property string ownModel: {
    var name = String(app.modelSettings.speech_model || "")
    return app.speechCatalog.some(function(entry) { return entry.id === name }) ? "" : name
  }
  // Vulkan from an older config still counts as the GPU.
  property string device: ["auto", "cpu", "cuda", "vulkan"].indexOf(app.modelSettings.speech_device) >= 0
    ? app.modelSettings.speech_device : "auto"

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
    subtitle: "A model file OmaFlow runs for you, or a server you run."
      + (page.managed ? "" : " Your audio goes to the address below, so point it at a machine you trust.")
  }

  // Above the choice, like the field labels below, so the three choices keep
  // the full width at the narrowest window.
  Column {
    width: parent.width
    spacing: 6
    UiText { text: "What you bring"; muted: true }
    Segmented {
      name: "What you bring"
      size: 13
      horizontalPadding: 12
      options: [{ value: "nemo", label: "A model file" }, { value: "openai", label: "OpenAI-compatible server" }, { value: "whisper-cpp", label: "whisper.cpp server" }]
      current: page.managed ? "nemo" : page.engine
      onPicked: function(value) { page.engine = value }
    }
  }

  Field {
    id: model
    deferProblem: true
    width: parent.width
    mono: true
    label: page.managed ? "Model file" : "Model name"
    text: page.ownModel
    placeholderText: page.managed ? "/path/to/model.gguf" : "The name your server knows"
    maximumLength: 512
    hint: page.managed ? "An absolute path to a GGUF file, or a model already in the NeMo cache. Nothing is downloaded here."
      : page.engine === "whisper-cpp" ? "Optional. whisper-server loads its own model; this is only shown in OmaFlow."
      : ""
    problem: text.trim().indexOf("-") === 0 ? "It cannot start with a dash." : ""
  }

  Field {
    id: endpoint
    deferProblem: true
    visible: !page.managed
    width: parent.width
    mono: true
    label: "Address"
    text: page.savedManaged ? "" : page.app.modelSettings.speech_endpoint || ""
    placeholderText: page.engine === "whisper-cpp" ? "http://127.0.0.1:8080/inference" : "http://127.0.0.1:8000/v1/audio/transcriptions"
    hint: "The full path, including the port."
    // Empty is not wrong before you type, like the model name; Save says what is missing.
    problem: text.trim().length > 0 ? page.endpointProblem(text, false) : ""
  }

  Field {
    id: health
    deferProblem: true
    visible: !page.managed
    width: parent.width
    mono: true
    label: "Health address, optional"
    text: page.app.modelSettings.speech_health_endpoint || ""
    placeholderText: page.engine === "whisper-cpp" ? "http://127.0.0.1:8080/health" : "http://127.0.0.1:8000/health"
    hint: "Answers with a success code once the server is ready. Left empty, OmaFlow asks the address above."
    problem: text.trim().length > 0 ? page.endpointProblem(text, false) : ""
  }

  Row {
    width: parent.width
    spacing: 12
    Field {
      id: language
      deferProblem: true
      width: page.managed ? (parent.width - 12) / 2 : parent.width
      label: "Language"
      text: page.app.modelSettings.speech_language || "auto"
      maximumLength: 32
      hint: "auto, or a code such as de"
      problem: /^[A-Za-z-]{1,32}$/.test(text.trim()) ? "" : "Use auto or a language code, such as de."
    }
    Column {
      visible: page.managed
      width: (parent.width - 12) / 2
      spacing: 6
      UiText { text: "Device"; muted: true }
      Segmented {
        name: "Device"
        size: 13
        options: [{ value: "auto", label: "Auto" }, { value: "cpu", label: "CPU" }, { value: "cuda", label: "GPU" }]
        current: page.device === "vulkan" ? "cuda" : page.device
        onPicked: function(value) { page.device = value }
      }
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
    id: saveRow
    spacing: 8
    readonly property bool keyStored: !page.managed && page.app.modelSettings.speech_api_key_set === true
    Pill {
      kind: "primary"
      text: "Save speech model"
      size: 13
      verticalPadding: 8
      enabled: page.ready
      hint: page.blocker
      onClicked: {
        var update = {
          speech_engine: page.managed ? "nemo" : page.engine,
          speech_model: model.text,
          speech_endpoint: page.managed ? page.managedEndpoint : endpoint.text,
          speech_health_endpoint: page.managed ? "" : health.text,
          speech_language: language.text,
          speech_device: page.device
        }
        if (key.text.length > 0) update.speech_api_key = key.text
        page.app.preference("models", update)
        key.text = ""
      }
    }
    UiText { visible: !page.ready; anchors.verticalCenter: parent.verticalCenter; text: page.blocker; muted: true; font.pixelSize: 12 }
    Pill { visible: saveRow.keyStored && !page.confirmRemoveKey; kind: "danger"; text: "Remove the stored key"; size: 13; verticalPadding: 8; onClicked: page.confirmRemoveKey = true }
    Pill { visible: saveRow.keyStored && page.confirmRemoveKey; kind: "fill"; text: "Keep it"; size: 13; verticalPadding: 8; onClicked: page.confirmRemoveKey = false }
    Pill {
      visible: saveRow.keyStored && page.confirmRemoveKey
      kind: "danger"; text: "Remove key"; size: 13; verticalPadding: 8
      Accessible.name: "Remove the stored speech API key"
      onClicked: { page.app.preference("models", { speech_api_key: "" }); page.confirmRemoveKey = false }
    }
    Pill { kind: "link"; text: "Read the guide"; size: 13; verticalPadding: 8; onClicked: page.app.openGuide("custom-models.md") }
  }
}
