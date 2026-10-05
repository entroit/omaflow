import QtQuick

// A short confirmation at the bottom of the window, with the one action that
// undoes it when there is one.
Shadowed {
  id: toast

  property string message: ""
  property bool error: false
  property string actionText: ""
  signal action()

  color: Theme.fill8
  shadowOpacity: 0.4
  shadowBlur: 32
  shadowOffset: 12
  width: row.implicitWidth + 28
  height: 38
  opacity: message.length > 0 ? 1 : 0
  visible: opacity > 0
  Behavior on opacity { NumberAnimation { duration: 160 } }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 16
    UiText {
      anchors.verticalCenter: parent.verticalCenter
      text: toast.message
      color: toast.error ? Theme.redText : Theme.text
      width: Math.min(implicitWidth, 520)
      elide: Text.ElideRight
    }
    UiText {
      anchors.verticalCenter: parent.verticalCenter
      visible: toast.actionText.length > 0
      text: toast.actionText
      color: Theme.accentText
      weight: Font.DemiBold
      MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: toast.action() }
    }
  }
}
