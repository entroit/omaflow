import QtQuick

// Asks an address whether anything is listening, and says so in words.
// A transcription endpoint only answers POST, so a 405 to a GET still proves
// something is there, which is also how the daemon decides it is reachable.
Row {
  id: tester

  required property var app
  property string url: ""
  property bool cleanupTest: false
  property string status: ""
  property bool failed: false
  property bool busy: false

  spacing: 12

  function check() {
    if (!cleanupTest && url.trim().length === 0) { failed = true; status = "Enter an address first."; return }
    status = ""
    failed = false
    busy = true
    var argv = cleanupTest ? ["omaflow", "test-cleanup"]
      : ["curl", "--disable", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", url.trim()]
    app.spawn(argv, function(stdout, stderr, code) {
      busy = false
      if (cleanupTest) {
        try {
          var report = JSON.parse(stdout)
          failed = report.ok !== true
          status = report.message || "The test returned no result."
        } catch (error) {
          failed = true
          status = "Could not run the test. Check that OmaFlow is installed and up to date."
        }
        return
      }
      var answer = parseInt(String(stdout).trim(), 10)
      if (answer >= 200 && answer < 300) { failed = false; status = "Answered. Something is listening there." }
      else if (answer === 405) { failed = false; status = "Answered 405, which is what a POST-only address should say." }
      else if (answer === 401 || answer === 403) { failed = true; status = "Reached, but access was denied. This check does not send your API key." }
      else if (answer === 404) { failed = true; status = "It answered 404. Check the path, or fill in a health address if it only accepts POST." }
      else if (answer > 0) { failed = true; status = "It answered " + answer + "." }
      else { failed = true; status = "Could not reach it. " + String(stderr || "").trim().split(/\r?\n/)[0] }
    })
  }

  Pill {
    kind: "primary"
    text: tester.busy ? "Testing…" : tester.cleanupTest ? "Test the saved model" : "Test connection"
    size: 13
    enabled: !tester.busy
    onClicked: tester.check()
  }
  UiText {
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, tester.parent ? tester.parent.width - 200 : 400)
    visible: tester.status.length > 0
    text: tester.status
    color: tester.failed ? Theme.redText : Theme.greenText
    wrapMode: Text.Wrap
  }
}
