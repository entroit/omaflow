import QtQuick

// A short confirmation at the bottom of the window, with the one action that
// undoes it when there is one.
Shadowed {
  id: toast

  property string message: ""
  property bool error: false
  property string actionText: ""
  // A key that also runs the action, shown in its button: "Ctrl+Z".
  property string actionShortcut: ""
  signal action()
  // True while the pointer rests on it or its action has focus: the page that
  // shows it keeps it up until then, so the action does not vanish mid-reach.
  readonly property bool held: visible && (hover.hovered || actionPill.activeFocus)

  color: Theme.fill8
  shadowOpacity: 0.4
  shadowBlur: 32
  shadowOffset: 12
  width: row.implicitWidth + 28
  // A long error wraps onto more lines instead of losing its end.
  height: Math.max(38, row.implicitHeight + 16)
  opacity: message.length > 0 ? 1 : 0
  visible: opacity > 0
  Behavior on opacity { NumberAnimation { duration: 160 } }

  Accessible.role: toast.error ? Accessible.AlertMessage : Accessible.StatusBar
  Accessible.name: toast.message

  HoverHandler { id: hover }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 16
    UiText {
      id: label
      anchors.verticalCenter: parent.verticalCenter
      text: toast.message
      color: toast.error ? Theme.redText : Theme.text
      width: Math.min(metrics.advanceWidth + 1, 520)
      wrapMode: Text.Wrap
      TextMetrics { id: metrics; font: label.font; text: toast.message }
    }
    Pill {
      id: actionPill
      anchors.verticalCenter: parent.verticalCenter
      visible: toast.actionText.length > 0
      kind: "link"
      text: toast.actionText
      shortcut: toast.actionShortcut
      bold: true
      horizontalPadding: 6
      verticalPadding: 3
      size: 13
      onClicked: toast.action()
    }
  }
}
