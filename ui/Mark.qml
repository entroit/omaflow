import QtQuick

// The OmaFlow mark: four bars of a waveform, the same as assets/icon.svg.
Item {
  id: mark

  property color color: Theme.accent
  property bool badge: false
  property color badgeColor: Theme.accent

  implicitWidth: 18
  implicitHeight: 18

  readonly property var bars: [
    { x: 1, y: 6, h: 4 }, { x: 4.75, y: 3, h: 10 }, { x: 8.5, y: 1, h: 14 }, { x: 12.25, y: 5, h: 6 }
  ]

  Repeater {
    model: mark.bars
    Rectangle {
      required property var modelData
      x: mark.width * modelData.x / 16
      y: mark.height * modelData.y / 16
      width: mark.width * 2.5 / 16
      height: mark.height * modelData.h / 16
      radius: width / 2
      color: mark.color
    }
  }

  Rectangle {
    visible: mark.badge
    width: mark.width * 0.36
    height: width
    radius: width / 2
    x: mark.width - width * 0.7
    y: -width * 0.25
    color: mark.badgeColor
    border.width: 1.5
    border.color: Theme.background
  }
}
