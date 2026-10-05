import QtQuick
import QtQuick.Window
import "../../ui"

// Runs the saved-model connection test against a stubbed reply and prints
// what the tester concluded.
Window {
  visible: true
  width: 560; height: 120
  readonly property string reply: Qt.application.arguments[Qt.application.arguments.length - 1]
  App {
    id: appState
    host: QtObject {
      function spawn(argv, callback) { Qt.callLater(function() { callback(reply, "", 0) }) }
    }
  }
  EndpointTester {
    id: tester
    app: appState
    cleanupTest: true
    Component.onCompleted: Qt.callLater(check)
    onStatusChanged: if (status.length > 0) {
      console.warn("PROBE_RESULT " + JSON.stringify({ failed: failed, status: status }))
      Qt.quit()
    }
  }
  Timer { interval: 3000; running: true; onTriggered: { console.warn("Probe timed out"); Qt.quit() } }
}
