import QtQuick

// A deleted entry, still in its place for the ten seconds it can come back:
// the whole entry greyed out, and under it Undo at full strength beside a
// thin bar that fills across as the time runs out. Then it folds shut and
// the entry is gone.
Item {
  id: gone

  required property var entry        // the entry as it was
  required property string date
  property int seconds: 10
  signal undoRequested()

  property real elapsed: 0
  readonly property bool closing: elapsed >= 1
  NumberAnimation on elapsed { from: 0; to: 1; duration: gone.seconds * 1000; running: true }

  implicitHeight: closing ? 0 : ghost.implicitHeight + 30
  height: implicitHeight
  opacity: closing ? 0 : 1
  clip: true
  Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
  Behavior on opacity { NumberAnimation { duration: 160 } }

  Accessible.role: Accessible.ListItem
  Accessible.name: "Entry at " + entry.time + " deleted. Undo with Control Z."

  JournalEntry {
    id: ghost
    width: gone.width
    entry: gone.entry
    date: gone.date
    enabled: false
    opacity: 0.38
  }

  // Under the entry, in its text column: Undo, and the time until it is
  // gone, filling from one side to the other.
  Row {
    id: undoRow
    x: 16 + 40 + 16
    y: ghost.implicitHeight - 6
    spacing: 8
    Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Undo"; verticalPadding: 4; horizontalPadding: 12; onClicked: gone.undoRequested() }
    Keycap { anchors.verticalCenter: parent.verticalCenter; compact: true; text: "Ctrl Z" }
  }
  Rectangle {
    id: track
    x: undoRow.x + undoRow.width + 14
    width: parent.width - x - 16
    anchors.verticalCenter: undoRow.verticalCenter
    height: 3
    radius: 1.5
    color: Theme.fill8
    Rectangle {
      width: parent.width * gone.elapsed
      height: parent.height
      radius: parent.radius
      color: Theme.alpha(Theme.text, 0.4)
    }
  }
}
