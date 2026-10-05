import QtQuick

// A dialog over the window: a scrim, and a panel that takes the keyboard
// until it is closed. Esc or a click outside closes it.
Item {
  id: sheet

  property bool open: false
  property real panelWidth: 480
  default property alias content: body.data
  signal closed()

  anchors.fill: parent
  visible: opacity > 0
  opacity: open ? 1 : 0
  z: 100
  Behavior on opacity { NumberAnimation { duration: 140 } }

  Rectangle {
    anchors.fill: parent
    color: Theme.alpha(Theme.light ? "#000000" : Theme.background, Theme.light ? 0.25 : 0.62)
    MouseArea { anchors.fill: parent; onClicked: sheet.closed() }
  }

  Shadowed {
    id: panel
    width: sheet.panelWidth
    height: body.childrenRect.height + 48
    anchors.centerIn: parent
    radius: Theme.radiusDialog
    color: Theme.fill4
    borderColor: Theme.divider
    shadowOpacity: 0.5
    shadowBlur: 40
    shadowOffset: 16
    scale: sheet.open ? 1 : 0.98
    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    MouseArea { anchors.fill: parent }

    FocusScope {
      id: scope
      anchors.fill: parent
      anchors.margins: 24
      focus: sheet.open
      Keys.onEscapePressed: sheet.closed()
      Item { id: body; width: parent.width }
    }
  }

  onOpenChanged: if (open) scope.forceActiveFocus()
}
