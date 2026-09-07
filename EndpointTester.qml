import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui

// "Save and hope" is not good enough for a field pointing at a server you run
// yourself. This asks the address whether it is there, and says so in words.
//
// A transcription endpoint only answers POST, so a GET returning 405 still
// proves something is listening and speaking HTTP. That matches how the daemon
// itself decides an external server is reachable.
RowLayout {
  id: tester

  property string url: ""
  property string status: ""
  property bool failed: false
  property bool busy: probe.running

  spacing: Style.space(8)

  function check() {
    if (tester.url.trim().length === 0) {
      tester.failed = true
      tester.status = "Enter an address first."
      return
    }
    tester.status = ""
    tester.failed = false
    probe.command = ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
      "--max-time", "5", tester.url.trim()]
    probe.running = true
  }

  ActionButton {
    text: tester.busy ? "Testing…" : "Test connection"
    enabled: !tester.busy
    foreground: Color.popups.text
    bordered: true
    onClicked: tester.check()
  }

  Text {
    Layout.fillWidth: true
    visible: tester.status.length > 0
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    text: tester.status
    color: tester.failed ? Color.urgent : Color.accent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Process {
    id: probe
    stdout: StdioCollector {
      onStreamFinished: {
        var code = parseInt(text.trim(), 10)
        if (code >= 200 && code < 300) {
          tester.failed = false
          tester.status = "Answered. Something is listening there."
        } else if (code === 405) {
          tester.failed = false
          tester.status = "Answered 405, which is what a POST-only endpoint should say. Good."
        } else if (code === 404) {
          // A transcription path that only accepts POST often answers 404 to a
          // GET. The daemon treats 404 as unreachable, so this really is a
          // problem to fix, and a health address is the way to fix it.
          tester.failed = true
          tester.status = "The server is up but answered 404 here. Either the path is wrong, or it only accepts POST — in which case fill in a health address, because OmaFlow reads a 404 as offline."
        } else if (code > 0) {
          tester.failed = true
          tester.status = "The server answered " + code + "."
        }
      }
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) {
        tester.failed = true
        tester.status = "Could not reach it. " + text.trim().split(/\r?\n/)[0]
      }
    }
  }
}
