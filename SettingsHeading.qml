import QtQuick
import QtQuick.Layouts
import qs.Commons

// A tab's title and its one-line explanation. Every settings page opens with
// one, so a page you land on cold says what it is for before it asks anything.
ColumnLayout {
  id: heading

  property string title: ""
  property string note: ""

  Layout.fillWidth: true
  spacing: Style.space(2)

  Text {
    Layout.fillWidth: true
    textFormat: Text.PlainText
    text: heading.title
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.bold: true
  }

  Text {
    Layout.fillWidth: true
    visible: heading.note.length > 0
    textFormat: Text.PlainText
    text: heading.note
    wrapMode: Text.Wrap
    color: Util.alpha(Color.popups.text, 0.58)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
