import QtQuick

// A calm, left-aligned block for a place with nothing in it yet: the mark,
// what is missing, and the way to fill it.
Column {
  id: empty
  property string title: ""
  property string body: ""
  property string footnote: ""
  default property alias actions: actionRow.data
  spacing: 0

  Mark { width: 36; height: 36; color: Theme.outline }
  Item { width: 1; height: 22 }
  UiText { text: empty.title; font.pixelSize: 17; weight: Font.Bold }
  Item { width: 1; height: 12 }
  UiText {
    width: empty.width
    text: empty.body
    muted: true
    font.pixelSize: 14
    wrapMode: Text.Wrap
    lineHeightMode: Text.FixedHeight
    lineHeight: 20
  }
  Item { width: 1; height: actionRow.children.length > 0 ? 20 : 0 }
  Row { id: actionRow; spacing: 8 }
  Item { width: 1; height: empty.footnote.length > 0 ? 28 : 0 }
  UiText { visible: empty.footnote.length > 0; width: empty.width; text: empty.footnote; muted: true; font.pixelSize: 12; wrapMode: Text.Wrap }
}
