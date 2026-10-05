import QtQuick
import "Fixtures.js" as Fixtures

// Prints the sample daemon state, so tests feed the host the same data the
// previews show.
QtObject {
  Component.onCompleted: {
    console.warn("STATE " + JSON.stringify(Fixtures.state("history", Date.now())))
    Qt.quit()
  }
}
