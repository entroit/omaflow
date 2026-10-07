import QtQuick

// Asks an address whether anything is listening, and says so in words.
// A transcription endpoint only answers POST, so a 405 to a GET still proves
// something is there, which is also how the daemon decides it is reachable.
Row {
  id: tester

  required property var app
  property string url: ""
  property bool cleanupTest: false
  // The cleanup fields as typed, so they can be tried before they are saved.
  // The API key, if any, goes on stdin like every other secret.
  property var cleanupSettings: null
  property string status: ""
  property bool failed: false
  property bool busy: false

  spacing: 12

  function check() {
    if (!cleanupTest && url.trim().length === 0) { failed = true; status = "Enter an address first."; return }
    status = ""
    failed = false
    busy = true
    var typed = cleanupTest && cleanupSettings !== null
    var argv = typed ? ["omaflow", "test-cleanup", "-"]
      : cleanupTest ? ["omaflow", "test-cleanup"]
      : ["curl", "--disable", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", url.trim()]
    var address = (url.trim().match(/^https?:\/\/([^\/]+)/) || [])[1] || url.trim()
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
      else if (answer >= 500) { failed = true; status = "The server answered with an error (" + answer + "). Check its log." }
      else if (answer > 0) { failed = true; status = "The server answered " + answer + ". Check the address." }
      else { failed = true; status = "Nothing answered at " + address + ". Start the server, then test again." }
    }, typed ? JSON.stringify(cleanupSettings) + "\n" : "")
  }

  // Outline, so Save stays the one primary action of the form. The label
  // stays put while the test runs; the line beside it says it is running.
  Pill {
    kind: "outline"
    text: "Test connection"
    size: 13
    enabled: !tester.busy
    onClicked: tester.check()
  }
  UiText {
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, tester.parent ? tester.parent.width - 200 : 400)
    visible: tester.busy || tester.status.length > 0
    text: tester.busy ? "Testing…" : tester.status
    color: tester.busy ? Theme.secondary : tester.failed ? Theme.redText : Theme.greenText
    wrapMode: Text.Wrap
  }
}
