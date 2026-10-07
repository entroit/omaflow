import QtQuick

// A place in the settings sidebar.
Rectangle {
  id: item
  property string text: ""
  property bool selected: false
  property bool nested: false
  property bool expander: false
  property bool expanded: false
  signal clicked()

  width: parent ? parent.width - (parent.leftPadding || 0) - (parent.rightPadding || 0) : 164
  height: nested ? 28 : 32
  radius: height / 2
  color: selected ? Theme.fill18 : mouse.containsMouse ? Theme.hover : "transparent"
  activeFocusOnTab: true

  // The focus ring sits outside, as on every button.
  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: height / 2
    color: "transparent"
    border.width: 2
    border.color: Theme.accent
    visible: item.activeFocus
  }

  UiText {
    x: item.nested ? 24 : 12
    anchors.verticalCenter: parent.verticalCenter
    text: item.text
    font.pixelSize: item.nested ? 13 : 14
    weight: item.selected || (item.expander && item.expanded) ? Font.DemiBold : Font.Normal
    color: item.nested && !item.selected ? Theme.secondary : Theme.text
  }
  Icon {
    visible: item.expander
    anchors.right: parent.right
    anchors.rightMargin: 12
    anchors.verticalCenter: parent.verticalCenter
    name: item.expanded ? "down" : "right"
    size: 8
    color: Theme.secondary
  }
  MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: item.clicked() }
  Keys.onReturnPressed: item.clicked()
  Keys.onSpacePressed: item.clicked()
  // Advanced opens and closes a group; the rest are pages.
  Accessible.role: item.expander ? Accessible.Button : Accessible.PageTab
  Accessible.name: item.text + (item.expander ? (item.expanded ? ", expanded" : ", collapsed") : "")
  Accessible.selected: item.selected
  Accessible.onPressAction: item.clicked()
}
