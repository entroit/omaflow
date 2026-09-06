# Changing models

Open **Settings → Models → Configure models**. Enter the model names and server
addresses, then choose **Save models**. The Models status card shows the selected speech and cleanup models alongside
their status. These are personal settings, applied to
the next dictation without rebuilding OmaFlow. Finish or discard an active
recording before changing models.

The defaults are Parakeet TDT v3 through NeMo-Speech and Gemma 4 E4B through
Ollama. Changing a model does not guarantee equal accuracy, language support,
latency or memory use. Evaluate a replacement before relying on it.

## Install without models

Run `./install --no-models` to skip model runtimes, GPU dependencies and weights.
The application still builds, links and starts, with `behavior.models_configured`
set to `false` in personal settings. It does not warm models or record audio in
this state. Updates preserve it.

In Settings → Models, save your choices. For an external speech server, install
and start that server yourself. For managed NeMo, install the compatible
NeMo-Speech runtime at `~/.local/lib/nemo-speech` and provide a supported model
repository already in the standard NeMo cache or absolute ASR GGUF path. Cleanup requires an Ollama server with your selected
model; an arbitrary GGUF file must first be imported into Ollama.

Once the runtime and weights are available, choose **Enable dictation with saved
models**. Saving model fields alone keeps setup pending, so it is safe to save
before installing them. OmaFlow has no model download controls. Use your
runtime's own installation tools. Alternatively, run `./install` without the flag to install the
saved selections and enable dictation. Model availability still determines
whether dictation can succeed; enabling setup does not certify model quality.

The same switch is `[behavior] models_configured = true` in the personal
TOML, applied with `omaflow reload-config`. See the
[configuration map](configuration.md).

## Cleanup

Use an installed Ollama model tag and the server's `/api/chat` endpoint.
`ollama list` shows models installed on your default Ollama server. Install or
import the model with Ollama itself, then enter its tag and server address in
OmaFlow. Set `OLLAMA_HOST` when managing a different Ollama server.

For example, replace `YOUR_MODEL_TAG` below with the model you want:

```bash
omaflow configure models '{"cleanup_model":"YOUR_MODEL_TAG"}'
```

The previous cleanup model is asked to unload when its name or server changes,
so it does not hold memory. Model options and the cleanup prompt are under
`[cleanup]` in the personal TOML.

A passing connection check is not a quality evaluation. The cleanup gates in
[CONTRIBUTING](../CONTRIBUTING.md#model-gates) measure the guarded output,
including raw fallbacks, for any model or prompt.

## Speech recognition

| Engine | Model selection | Server lifecycle |
|---|---|---|
| NeMo | Absolute ASR GGUF path or repository already present in the standard NeMo cache | OmaFlow starts/restarts its own service using that model and device |
| Compatible API | Model name understood by an OpenAI-compatible transcription server | You start and manage the server |
| whisper.cpp | Model configured in whisper-server; OmaFlow's model name is descriptive | You start and manage whisper-server |

### Managed NeMo

Use a loopback URL such as `http://127.0.0.1:18103/v1/audio/transcriptions`;
other hosts are rejected. The port comes from the endpoint; the model and device come from your settings.
Choose `cuda`, `cpu`, `auto`,
`vulkan` or `metal` as supported by your installed NeMo build and hardware.
Selecting a device does not install a different runtime build.

List the installed runtime's supported models:

```bash
~/.local/lib/nemo-speech/bin/nemo-speech model list
```

Install the model with NeMo-Speech itself, or supply a supported local ASR GGUF
path. Then save that name or path in OmaFlow. The bundled installer also reads
that selection.
Parakeet TDT's default repository is `nvidia/parakeet-tdt-0.6b-v3`.

### Compatible external server

Use `speech_engine="openai"` and the server's full transcription endpoint,
usually `/v1/audio/transcriptions`. OmaFlow sends a multipart WAV, model name
and `response_format=json`, and expects a JSON `text` field. Automatic language
selection omits the `language` field; an explicit language code is forwarded.
This is a protocol choice and does not connect to OpenAI automatically.

Example for a server you already run locally:

```bash
omaflow configure models '{"speech_engine":"openai","speech_model":"YOUR_SERVER_MODEL","speech_endpoint":"http://127.0.0.1:8000/v1/audio/transcriptions","speech_health_endpoint":"","speech_language":"auto"}'
```

Use `speech_engine="whisper-cpp"` with whisper-server's `/inference` endpoint.
That adapter sends the audio and JSON response format without a model field;
whisper-server loads its model when you start it. Set its model using its own
`--model` option. Changing the descriptive name in OmaFlow does not load weights
inside an external server.

An optional health URL should return HTTP 2xx when ready. Without one, OmaFlow
probes the transcription URL of an external server and accepts 2xx or 405 as
reachable; for managed NeMo it probes `/health` on the endpoint's host. Reachability
is not proof of model readiness or transcription accuracy; request failures
still appear in the recording result. OmaFlow never starts NeMo to repair an
external server.

## Configuration and limits

`omaflow configure models JSON` accepts partial updates with these
keys: `cleanup_model`, `cleanup_endpoint`, `speech_engine`, `speech_model`,
`speech_endpoint`, `speech_health_endpoint`, `speech_language`, `speech_device`.
`speech_engine` accepts `nemo`, `openai` or `whisper-cpp` (`parakeet` is an
alias for `nemo`); `speech_device` accepts `auto`, `cpu`, `cuda`, `vulkan` or
`metal`.
Use `omaflow effective-config` to inspect the effective configuration.

Audio and cleanup context go to the URLs you choose. Defaults are loopback URLs.
Authentication headers, paid cloud APIs and arbitrary speech protocols are not
implemented. An alternate server must implement the selected request format;
installing and managing every possible inference runtime is outside this setup.

The installer, preflight and link-local read the bundled model configuration
plus the complete personal configuration. With an external speech server, the installer skips
NeMo and its weights. With cleanup disabled, it skips Ollama and cleanup weights.
Python 3.11+ is needed to read model configuration before installation planning.
Custom models have no established memory budget; the 6300 MiB preflight
requirement applies only to the default model pair.

An alternative speech engine or a replacement cleanup model needs its own
accuracy and hardware evaluation.

Protocol references: [Ollama chat API](https://docs.ollama.com/api/chat) and
[whisper.cpp server](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/README.md).

Managed speech startup resolves an existing GGUF file before launching NeMo.
It never passes a repository name that could trigger a download. If the standard
cache has multiple revisions or you use another cache location, provide the
absolute file path. A missing or ambiguous file reports a setup error without a
service restart loop. External servers control their own download behavior.

Managed NeMo transcribes with the model its server loaded; compatible API
requests send the configured model name because that server selects the model.
