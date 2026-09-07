import QtQuick
import qs.Commons

// The OmaFlow mark: four bars of a waveform, matching assets/icon.svg. Used
// both in the bar slot and at the top of the panel, so the thing you click in
// the bar and the thing you see in the panel are visibly the same app.
Item {
  id: mark

  property color barColor: Color.foreground
  // The bar slot uses this for the quiet update dot; the panel header has its
  // own update banner and leaves it off.
  property bool badge: false
  property color badgeColor: Color.accent

  implicitWidth: Style.font.display
  implicitHeight: Style.font.display

  Repeater {
    model: [
      { "x": 1, "y": 6, "width": 2.5, "height": 4 },
      { "x": 4.75, "y": 3, "width": 2.5, "height": 10 },
      { "x": 8.5, "y": 1, "width": 2.5, "height": 14 },
      { "x": 12.25, "y": 5, "width": 2.5, "height": 6 }
    ]

    Rectangle {
      required property var modelData
      x: mark.width * modelData.x / 16
      y: mark.height * modelData.y / 16
      width: mark.width * modelData.width / 16
      height: mark.height * modelData.height / 16
      radius: width / 2
      color: mark.barColor
    }
  }

  Rectangle {
    visible: mark.badge
    width: mark.width * 0.3
    height: width
    radius: width / 2
    x: mark.width - width
    y: 0
    color: mark.badgeColor
  }
}
