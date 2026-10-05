import QtQuick
import QtQuick.Controls as Controls

// A labelled text input that keeps saying what it is after you type. A
// problem replaces the hint in the error colour, so the line under the field
// is always the one thing worth reading.
Column {
  id: field

  property string label: ""
  property string hint: ""
  property string problem: ""
  property alias text: input.text
  property alias placeholderText: input.placeholderText
  property alias maximumLength: input.maximumLength
  property bool password: false
  property bool mono: false
  property alias input: input
  signal accepted()

  spacing: 6

  UiText {
    visible: field.label.length > 0
    text: field.label
    muted: true
  }

  Controls.TextField {
    id: input
    width: parent.width
    height: 38
    leftPadding: 13
    rightPadding: 13
    color: Theme.text
    placeholderTextColor: Theme.secondary
    selectionColor: Theme.alpha(Theme.accent, 0.4)
    selectedTextColor: Theme.text
    font.family: field.mono ? Theme.mono : Theme.sans
    font.pixelSize: 13
    echoMode: field.password ? TextInput.Password : TextInput.Normal
    maximumLength: 2048
    selectByMouse: true
    verticalAlignment: TextInput.AlignVCenter
    background: Rectangle {
      radius: Theme.radiusInput
      color: Theme.fill4
      border.width: input.activeFocus ? 2 : 1
      border.color: field.problem.length > 0 ? Theme.redText
        : input.activeFocus ? Theme.accent : Theme.outline
    }
    onAccepted: field.accepted()
    Accessible.name: field.label
  }

  UiText {
    width: parent.width
    visible: text.length > 0
    text: field.problem.length > 0 ? field.problem : field.hint
    color: field.problem.length > 0 ? Theme.redText : Theme.secondary
    font.pixelSize: 12
    wrapMode: Text.Wrap
    lineHeightMode: Text.ProportionalHeight
    lineHeight: 1.1
  }
}
