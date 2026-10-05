import QtQuick

// An on/off switch. The whole row it sits in is usually the click target;
// this is only the switch itself.
Item {
  id: toggle

  property bool checked: false
  property string label: ""
  signal toggled()

  implicitWidth: 34
  implicitHeight: 20
  activeFocusOnTab: true

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: toggle.checked ? Theme.accent : Theme.fill22
    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      width: 14
      height: 14
      radius: 7
      y: 3
      x: toggle.checked ? parent.width - width - 3 : 3
      color: toggle.checked ? Theme.onAccent : Theme.secondary
      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: height / 2
    color: "transparent"
    border.width: 2
    border.color: Theme.accent
    visible: toggle.activeFocus
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: toggle.toggled()
  }
  Keys.onSpacePressed: toggle.toggled()
  Keys.onReturnPressed: toggle.toggled()

  Accessible.role: Accessible.CheckBox
  Accessible.name: toggle.label
  Accessible.checkable: true
  Accessible.checked: toggle.checked
  Accessible.onToggleAction: toggle.toggled()
}
