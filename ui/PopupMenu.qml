import QtQuick

// A short list of commands that opens under the button that asked for it.
Item {
  id: menu

  property var items: []           // [{ label, action, detail?, danger?, dot?, checked? }]
  // "right" lines the menu up with the button's right edge, "left" with its left.
  property string align: "right"
  property real panelWidth: 220
  property bool open: false
  property Item anchorItem: null
  signal picked(string action)

  anchors.fill: parent
  visible: open
  z: 90

  MouseArea { anchors.fill: parent; onClicked: menu.open = false }

  Shadowed {
    id: panel
    readonly property point origin: menu.anchorItem && menu.open
      ? menu.anchorItem.mapToItem(menu, menu.anchorItem.width, menu.anchorItem.height + 6) : Qt.point(0, 0)
    x: menu.align === "left" && menu.anchorItem
      ? Math.min(menu.width - width - 8, origin.x - menu.anchorItem.width)
      : Math.max(8, origin.x - width)
    y: Math.min(origin.y, menu.height - height - 8)
    width: menu.panelWidth
    height: list.implicitHeight + 12
    radius: Theme.radiusCard + 2
    color: Theme.fill8
    shadowOpacity: 0.45

    Column {
      id: list
      anchors.fill: parent
      anchors.margins: 6
      Repeater {
        model: menu.items
        Rectangle {
          required property var modelData
          width: list.width
          height: modelData.detail && modelData.danger ? 46 : 32
          radius: 16
          color: itemMouse.containsMouse || activeFocus ? Theme.fill18 : "transparent"
          activeFocusOnTab: true
          Rectangle {
            visible: modelData.dot !== undefined
            x: 12; anchors.verticalCenter: parent.verticalCenter
            width: 7; height: 7; radius: 3.5
            color: modelData.dot || "transparent"
            border.width: modelData.dot ? 0 : 1.2
            border.color: Theme.outline
          }
          Column {
            anchors.left: parent.left
            anchors.leftMargin: modelData.dot !== undefined ? 28 : 12
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Row {
              width: parent.width
              spacing: 8
              UiText { text: modelData.label; color: modelData.danger ? Theme.redText : Theme.text }
              UiText { visible: Boolean(modelData.detail) && !modelData.danger; text: modelData.detail || ""; muted: true }
            }
            UiText { visible: Boolean(modelData.detail) && Boolean(modelData.danger); text: modelData.detail || ""; muted: true; font.pixelSize: 12 }
          }
          Icon { visible: Boolean(modelData.checked); anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 11; color: Theme.text }
          MouseArea { id: itemMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { menu.open = false; menu.picked(modelData.action) } }
          Keys.onReturnPressed: { menu.open = false; menu.picked(modelData.action) }
          Keys.onEscapePressed: menu.open = false
          Accessible.role: Accessible.MenuItem
          Accessible.name: modelData.label
        }
      }
    }
  }
}
