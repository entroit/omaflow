import QtQuick

// A setting in a sheet: what it is, one line on what it does, and the control
// on the right. Rows are separated by a hairline, except the last.
Item {
  id: row

  property string title: ""
  property string caption: ""
  property bool monoCaption: false
  property bool last: false
  // A next step under the caption, such as where to turn something on.
  property string link: ""
  signal linkClicked()
  default property alias control: slot.data

  width: parent ? parent.width : 400
  implicitHeight: Math.max(text.implicitHeight, slot.childrenRect.height) + 28

  Column {
    id: text
    anchors.left: parent.left
    anchors.right: slot.left
    anchors.rightMargin: 16
    anchors.verticalCenter: parent.verticalCenter
    spacing: 3
    UiText { text: row.title; font.pixelSize: 14; weight: Font.DemiBold }
    UiText {
      width: parent.width
      visible: row.caption.length > 0
      text: row.caption
      muted: true
      font.pixelSize: row.monoCaption ? 12 : 13
      font.family: row.monoCaption ? Theme.mono : Theme.sans
      // A path keeps both ends; a sentence wraps.
      elide: row.monoCaption ? Text.ElideMiddle : Text.ElideNone
      wrapMode: row.monoCaption ? Text.NoWrap : Text.Wrap
    }
    Pill {
      visible: row.link.length > 0
      kind: "link"
      text: row.link
      size: 13
      // The text lines up with the caption; the hover shape reaches past it.
      x: -6
      horizontalPadding: 6
      verticalPadding: 2
      onClicked: row.linkClicked()
    }
  }

  Item {
    id: slot
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: childrenRect.width
    height: childrenRect.height
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
