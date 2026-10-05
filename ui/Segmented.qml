import QtQuick

// A row of mutually exclusive choices in one capsule.
Rectangle {
  id: control

  // [{ value, label }]
  property var options: []
  property string current: ""
  property int size: 13
  property real horizontalPadding: 16
  signal picked(string value)

  implicitWidth: row.implicitWidth + 6
  implicitHeight: row.implicitHeight + 6
  radius: height / 2
  color: "transparent"
  border.width: 1
  border.color: Theme.outline

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 0

    Repeater {
      model: control.options
      Pill {
        required property var modelData
        kind: "ghost"
        text: modelData.label
        size: control.size
        horizontalPadding: control.horizontalPadding
        verticalPadding: 4
        selected: control.current === modelData.value
        Accessible.role: Accessible.RadioButton
        Accessible.checkable: true
        Accessible.checked: selected
        onClicked: control.picked(modelData.value)
      }
    }
  }
}
