import QtQuick

// A short list of commands that opens under the button that asked for it.
// Choices can sit under a heading, between lines, or side by side as chips.
Item {
  id: menu

  // An aside is said at the right edge, such as the time a choice means.
  //   { label, action, detail?, aside?, danger?, dot?, checked? }
  //   { header }                        a quiet heading over the choices under it
  //   { divider: true }                 a line between groups
  //   { name, chips: [{ label, name?, action, checked?, quiet? }] }   one row of short choices
  property var items: []
  // "right" lines the menu up with the button's right edge, "left" with its left.
  property string align: "right"
  property real panelWidth: 220
  property bool open: false
  property Item anchorItem: null
  // What the menu is for, said to assistive tech before its choices, such
  // as "Move “Buy oat milk” to".
  property string name: ""
  signal picked(string action)

  anchors.fill: parent
  visible: open
  z: 90

  function pickable(item) { return item && item.header === undefined && !item.divider }

  // Opened, the first choice has the keyboard, so arrows, Enter and Esc work
  // at once; closed, the keyboard goes back where it was.
  property Item returnFocus: null
  onOpenChanged: {
    if (open) {
      returnFocus = Window.activeFocusItem
      Qt.callLater(function() { if (menu.open) menu.focusChoice(-1, 1) })
    } else if (returnFocus) {
      var item = returnFocus
      returnFocus = null
      if (item.visible) item.forceActiveFocus()
    }
  }
  // The next choice from AT in the direction STEP, past headings and lines.
  function focusChoice(at, step) {
    for (var tries = 0; tries < choices.count; tries++) {
      at = (at + step + choices.count) % choices.count
      if (pickable(items[at])) { choices.itemAt(at).forceActiveFocus(); return }
    }
  }
  function choose(action) {
    open = false
    picked(action)
  }

  MouseArea { anchors.fill: parent; onClicked: menu.open = false }

  Shadowed {
    id: panel
    readonly property point origin: menu.anchorItem && menu.open
      ? menu.anchorItem.mapToItem(menu, menu.anchorItem.width, menu.anchorItem.height + 6) : Qt.point(0, 0)
    x: menu.align === "left" && menu.anchorItem
      ? Math.min(menu.width - width - 8, origin.x - menu.anchorItem.width)
      : Math.max(8, origin.x - width)
    y: Math.max(8, Math.min(origin.y, menu.height - height - 8))
    width: menu.panelWidth
    height: list.implicitHeight + 12
    radius: Theme.radiusCard + 2
    color: Theme.fill8
    shadowOpacity: 0.45
    Accessible.role: Accessible.PopupMenu
    Accessible.name: menu.name

    Column {
      id: list
      anchors.fill: parent
      anchors.margins: 6
      Repeater {
        id: choices
        model: menu.items
        Rectangle {
          id: choice
          required property var modelData
          required property int index
          readonly property bool isHeader: modelData.header !== undefined
          readonly property bool isDivider: Boolean(modelData.divider)
          readonly property var chips: modelData.chips || null
          // The chip the keyboard is on, in a row of chips: the chosen one first.
          property int chipAt: chips ? Math.max(0, chips.findIndex(function(c) { return c.checked })) : 0
          width: list.width
          height: isDivider ? 13
            : isHeader ? 28
            : chips ? chipFlow.implicitHeight + (chipMeans.text ? chipMeans.implicitHeight + 6 : 0) + 14
            : modelData.detail && modelData.danger ? words.implicitHeight + 16 : 32
          radius: 16
          color: !isHeader && !isDivider && !chips && (itemMouse.containsMouse || activeFocus) ? Theme.fill18 : "transparent"
          activeFocusOnTab: menu.pickable(modelData)

          Rectangle {
            visible: choice.isDivider
            x: 8; width: parent.width - 16; height: 1
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.divider
          }
          UiText {
            visible: choice.isHeader
            x: 12
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 5
            text: modelData.header || ""
            font.pixelSize: 12
            font.letterSpacing: 0.24
            weight: Font.DemiBold
            muted: true
          }

          // The chip under the pointer, to say what it would mean.
          property int chipHovered: -1
          // Chips wrap onto a second line rather than squeeze their words.
          Flow {
            id: chipFlow
            visible: Boolean(choice.chips)
            x: 12
            y: 7
            width: parent.width - 24
            spacing: 4
            Repeater {
              model: choice.chips || []
              Rectangle {
                id: chip
                required property var modelData
                required property int index
                readonly property bool focused: choice.activeFocus && choice.chipAt === index
                width: chipText.implicitWidth + 14
                height: 26
                radius: 13
                color: modelData.checked ? Theme.accent
                  : modelData.quiet ? (chipMouse.containsMouse ? Theme.fill18 : "transparent")
                  : chipMouse.containsMouse ? Theme.fill22 : Theme.fill18
                border.width: modelData.quiet && !modelData.checked ? 1 : 0
                border.color: Theme.outline
                UiText {
                  id: chipText
                  anchors.centerIn: parent
                  text: chip.modelData.label
                  font.pixelSize: 12
                  weight: chip.modelData.checked ? Font.DemiBold : Font.Normal
                  color: chip.modelData.checked ? Theme.onAccent : modelData.quiet ? Theme.secondary : Theme.text
                }
                // The keyboard ring, outside the shape like a Pill's.
                Rectangle { anchors.fill: parent; anchors.margins: -3; radius: height / 2; color: "transparent"; border.width: 2; border.color: Theme.accent; visible: chip.focused }
                MouseArea {
                  id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                  onClicked: menu.choose(chip.modelData.action)
                  onContainsMouseChanged: if (containsMouse) choice.chipHovered = chip.index; else if (choice.chipHovered === chip.index) choice.chipHovered = -1
                }
                Accessible.role: Accessible.RadioButton
                Accessible.name: chip.modelData.name || chip.modelData.label
                Accessible.checkable: true
                Accessible.checked: Boolean(chip.modelData.checked)
              }
            }
          }

          // What the chosen chip means, or the one under the pointer or the
          // keyboard: said once here so the chips stay short.
          UiText {
            id: chipMeans
            visible: Boolean(choice.chips) && text.length > 0
            x: 12
            anchors.top: chipFlow.bottom
            anchors.topMargin: 6
            width: parent.width - 24
            readonly property var shown: !choice.chips ? null
              : choice.chips[choice.chipHovered >= 0 ? choice.chipHovered : choice.activeFocus ? choice.chipAt : choice.chips.findIndex(function(c) { return c.checked })] || null
            text: shown && shown.means ? shown.means : ""
            font.pixelSize: 12
            muted: true
            elide: Text.ElideRight
          }

          Rectangle {
            visible: modelData.dot !== undefined
            x: 12; anchors.verticalCenter: parent.verticalCenter
            width: 7; height: 7; radius: 3.5
            color: modelData.dot || "transparent"
            border.width: modelData.dot ? 0 : 1.2
            border.color: Theme.outline
          }
          Column {
            id: words
            visible: menu.pickable(modelData) && !choice.chips
            anchors.left: parent.left
            anchors.leftMargin: modelData.dot !== undefined ? 28 : 12
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Row {
              width: parent.width
              spacing: 8
              UiText { anchors.verticalCenter: parent.verticalCenter; text: modelData.label || ""; color: modelData.danger ? Theme.redText : Theme.text }
              UiText { anchors.verticalCenter: parent.verticalCenter; visible: Boolean(modelData.detail) && !modelData.danger; text: modelData.detail || ""; muted: true }
              // The current choice, next to its name, so the times beside
              // every choice stay in one column.
              Icon { anchors.verticalCenter: parent.verticalCenter; visible: Boolean(modelData.checked) && Boolean(modelData.aside); name: "check"; size: 11; color: Theme.text }
            }
            UiText { visible: Boolean(modelData.detail) && Boolean(modelData.danger); width: parent.width; wrapMode: Text.Wrap; text: modelData.detail || ""; muted: true; font.pixelSize: 12 }
          }
          UiText { visible: Boolean(modelData.aside) && !choice.chips; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; text: modelData.aside || ""; muted: true }
          Icon { visible: Boolean(modelData.checked) && !modelData.aside && !choice.chips; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 11; color: Theme.text }
          MouseArea {
            id: itemMouse
            anchors.fill: parent
            enabled: menu.pickable(modelData) && !choice.chips
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: menu.choose(modelData.action)
          }
          function activate() { menu.choose(chips ? chips[chipAt].action : modelData.action) }
          Keys.onReturnPressed: activate()
          Keys.onEnterPressed: activate()
          Keys.onSpacePressed: activate()
          Keys.onEscapePressed: menu.open = false
          Keys.onDownPressed: menu.focusChoice(choice.index, 1)
          Keys.onUpPressed: menu.focusChoice(choice.index, -1)
          Keys.onLeftPressed: if (chips) chipAt = Math.max(0, chipAt - 1)
          Keys.onRightPressed: if (chips) chipAt = Math.min(chips.length - 1, chipAt + 1)
          // Tab stays in the open menu rather than walking into the page behind it.
          Keys.onTabPressed: menu.focusChoice(choice.index, 1)
          Keys.onBacktabPressed: menu.focusChoice(choice.index, -1)
          Accessible.role: isHeader ? Accessible.StaticText : chips ? Accessible.Grouping : Accessible.MenuItem
          Accessible.name: isHeader ? modelData.header : chips ? (modelData.name || "") + ", " + (chips[chipAt].name || chips[chipAt].label) : modelData.label || ""
          Accessible.ignored: isDivider
          // What a screen reader would otherwise miss: what a choice moves,
          // the time it means, and which one is current.
          Accessible.description: modelData.detail || modelData.aside || ""
          Accessible.checkable: modelData.checked !== undefined || Boolean(chips)
          Accessible.checked: chips ? Boolean(chips[chipAt].checked) : Boolean(modelData.checked)
        }
      }
    }
  }
}
