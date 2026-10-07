import QtQuick
import QtQuick.Controls as Controls

// A quiet filled capsule; the outline only appears while you type in it.
// Press / to get here.
Rectangle {
  id: search

  property alias text: input.text
  property string placeholder: "Search"
  property alias input: input
  signal escaped()
  signal down()
  signal up()
  signal accepted()
  // Ctrl+Z with nothing typed to undo: the page's Undo.
  signal undoPressed()

  implicitHeight: 36
  radius: height / 2
  color: input.activeFocus ? Theme.fill4 : hover.hovered ? Theme.fill18 : Theme.fill8
  border.width: input.activeFocus ? 1 : 0
  border.color: Theme.accent

  HoverHandler { id: hover; cursorShape: Qt.IBeamCursor }

  Icon {
    id: key
    name: "search"
    size: 13
    color: Theme.secondary
    anchors.left: parent.left
    anchors.leftMargin: 13
    anchors.verticalCenter: parent.verticalCenter
  }

  Controls.TextField {
    id: input
    anchors.left: key.right
    anchors.leftMargin: 3
    anchors.right: parent.right
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    background: null
    color: Theme.text
    placeholderText: search.placeholder
    placeholderTextColor: Theme.secondary
    selectionColor: Theme.alpha(Theme.accent, 0.4)
    selectedTextColor: Theme.text
    font.family: Theme.sans
    font.pixelSize: 13
    leftPadding: 4
    selectByMouse: true
    Keys.onEscapePressed: {
      if (text.length > 0) text = ""
      else { focus = false; search.escaped() }
    }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Z && event.modifiers === Qt.ControlModifier && !canUndo) {
        search.undoPressed()
        event.accepted = true
      }
    }
    Keys.onDownPressed: search.down()
    Keys.onUpPressed: search.up()
    onAccepted: search.accepted()
    Accessible.name: search.placeholder
  }
}
