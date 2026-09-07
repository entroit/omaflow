import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// A text field that still says what it is once you have typed in it. A
// placeholder disappears on the first keystroke, which is fine for a lone
// search box and useless for six stacked fields holding URLs that look alike.
ColumnLayout {
  id: field

  property string label: ""
  property string hint: ""
  property string problem: ""
  property alias text: input.text
  property alias placeholderText: input.placeholderText
  property alias maximumLength: input.maximumLength
  property alias password: input.password

  Layout.fillWidth: true
  spacing: Style.space(2)

  Text {
    textFormat: Text.PlainText
    text: field.label
    color: Util.alpha(Color.popups.text, 0.72)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  TextField {
    id: input
    Layout.fillWidth: true
    foreground: Color.popups.text
    accent: field.problem.length > 0 ? Color.urgent : Color.accent
    maximumLength: 2048
    Accessible.name: field.label
  }

  Text {
    Layout.fillWidth: true
    visible: text.length > 0
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    // A problem outranks the hint: once something is wrong, the explanation of
    // what the field is for is no longer the thing you need to read.
    text: field.problem.length > 0 ? field.problem : field.hint
    color: field.problem.length > 0 ? Color.urgent : Util.alpha(Color.popups.text, 0.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
