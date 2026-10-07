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
  // What a screen reader calls the field when it has no visible label.
  property string name: label
  // A problem waits until you leave the field or press Enter, so an address
  // isn't wrong from its first letter. After that it follows what you type.
  property bool deferProblem: false
  property bool visited: false
  readonly property string shownProblem: problem.length > 0 && (!deferProblem || visited || !input.activeFocus) ? problem : ""
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
      border.color: field.shownProblem.length > 0 ? Theme.redText
        : input.activeFocus ? Theme.accent : Theme.outline
    }
    onAccepted: field.accepted()
    onEditingFinished: field.visited = true
    Accessible.name: field.name
    // The line under the field, read out too.
    Accessible.description: field.shownProblem || field.hint
  }

  UiText {
    width: parent.width
    visible: text.length > 0
    text: field.shownProblem.length > 0 ? field.shownProblem : field.hint
    color: field.shownProblem.length > 0 ? Theme.redText : Theme.secondary
    font.pixelSize: 12
    wrapMode: Text.Wrap
    lineHeightMode: Text.ProportionalHeight
    lineHeight: 1.1
  }
}
