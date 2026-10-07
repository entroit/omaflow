import QtQuick

// A labelled setting: what it is and a word on how it behaves on the left,
// the control beside it. Rows are separated by a hairline, except the last.
Item {
  id: row

  property string title: ""
  property string caption: ""
  property bool last: false
  property bool alignTop: false
  // A switch in the slot: its title and caption flip it too, so the words
  // are a click target and not only the small switch.
  property Item toggle: null
  default property alias control: slot.data

  width: parent ? parent.width : 600
  implicitHeight: Math.max(labels.implicitHeight, slot.childrenRect.height) + (last ? 0 : 18) + 1

  Column {
    id: labels
    width: 180
    y: row.alignTop ? 6 : (row.implicitHeight - (row.last ? 0 : 19) - implicitHeight) / 2
    spacing: 3
    UiText { width: parent.width; text: row.title; font.pixelSize: 14; weight: Font.DemiBold; wrapMode: Text.Wrap }
    UiText { width: parent.width; visible: row.caption.length > 0; text: row.caption; muted: true; font.pixelSize: 12; wrapMode: Text.Wrap }
  }
  MouseArea {
    anchors.fill: labels
    enabled: row.toggle !== null && row.toggle.visible
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: row.toggle.toggled()
  }

  Item {
    id: slot
    x: 196
    width: row.width - 196
    height: childrenRect.height
    y: row.alignTop ? 0 : (row.implicitHeight - (row.last ? 0 : 19) - height) / 2
  }

  Rectangle {
    visible: !row.last
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: 1
    color: Theme.divider
  }
}
