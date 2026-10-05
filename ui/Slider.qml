import QtQuick
import QtQuick.Controls as Controls

// A capsule track with a round handle, for numbers you set by feel.
Controls.Slider {
  id: control
  property string label: ""
  implicitHeight: 24
  background: Rectangle {
    x: control.leftPadding
    y: control.topPadding + control.availableHeight / 2 - height / 2
    width: control.availableWidth
    height: 6
    radius: 3
    color: Theme.fill18
    Rectangle { width: control.visualPosition * parent.width; height: parent.height; radius: 3; color: Theme.accent }
  }
  handle: Rectangle {
    x: control.leftPadding + control.visualPosition * (control.availableWidth - width)
    y: control.topPadding + control.availableHeight / 2 - height / 2
    width: 18; height: 18; radius: 9
    color: Theme.text
    border.width: control.activeFocus ? 3 : 0
    border.color: Theme.accent
  }
  Accessible.name: label
}
