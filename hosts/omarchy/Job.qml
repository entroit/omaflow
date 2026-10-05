import QtQuick
import Quickshell.Io

// One process run for the shared UI. Calls back once with everything it
// printed and its exit code, then destroys itself.
Process {
  id: job

  property var callback: null
  // Written to stdin once the command starts, then forgotten. This is how a
  // secret reaches it without showing up in its arguments.
  property string input: ""
  property int exitCode: -1
  property int pending: 3
  property bool done: false

  function settle() {
    pending--
    if (pending > 0) finish(false)
    else finish(true)
  }
  function finish(force) {
    if (done || !force) return
    done = true
    if (callback) callback(out.text, err.text, exitCode)
    job.destroy()
  }

  // A command that never starts sends no exit; do not leave its caller waiting.
  property Timer giveUp: Timer { interval: 400; onTriggered: job.finish(true) }
  onRunningChanged: if (!running) giveUp.restart()

  stdinEnabled: input.length > 0
  onStarted: if (input.length > 0) { write(input); input = "" }

  stdout: StdioCollector { id: out; onStreamFinished: job.settle() }
  stderr: StdioCollector { id: err; onStreamFinished: job.settle() }
  onExited: function(code) { job.exitCode = code; job.settle() }
}
