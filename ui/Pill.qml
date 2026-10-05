import QtQuick

// Anything you press is a capsule. The kind says how loud it is:
//   primary  one per view, accent fill
//   fill     a quiet action on a surface
//   outline  a control that sits on the background, such as Change
//   ghost    a tab or a list action that should not compete
//   link     words in the accent colour, no shape until hovered
//   danger   an outline in the error colour
Rectangle {
  id: pill

  property string text: ""
  property string kind: "fill"
  property bool selected: false
  property int size: 12
  property real horizontalPadding: 10
  property real verticalPadding: 6
  property bool bold: kind === "primary" || selected
  property string hint: ""
  // A key that also does this, shown quieter after the label: "Discard Esc".
  property string shortcut: ""
  property Component leading: null
  property Component trailing: null
  signal clicked()

  readonly property bool hovered: mouse.containsMouse
  readonly property bool pressed: mouse.pressed

  implicitWidth: row.implicitWidth + horizontalPadding * 2
  implicitHeight: Math.round(label.lineHeight + verticalPadding * 2)
  radius: height / 2
  activeFocusOnTab: enabled && visible
  opacity: enabled ? 1 : 0.45
  color: kind === "primary" ? (pressed ? Theme.mix(Theme.accent, Theme.background, 0.2)
                                : hovered ? Theme.mix(Theme.accent, Theme.text, 0.12) : Theme.accent)
    : kind === "fill" ? (selected ? Theme.fill22 : hovered ? Theme.fill22 : Theme.fill18)
    : kind === "outline" || kind === "danger" ? (hovered ? Theme.fill8 : Theme.fill4)
    : selected ? Theme.fill18
    : hovered ? Theme.fill8 : "transparent"
  border.width: kind === "outline" || kind === "danger" ? 1 : 0
  border.color: kind === "danger" ? Theme.redText : Theme.outline

  Behavior on color { ColorAnimation { duration: 90 } }

  Rectangle {
    // Keyboard focus is a ring outside the shape, never a colour change,
    // so it reads the same on every kind.
    anchors.fill: parent
    anchors.margins: -3
    radius: height / 2
    color: "transparent"
    border.width: 2
    border.color: Theme.accent
    visible: pill.activeFocus
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 6
    Loader { sourceComponent: pill.leading; anchors.verticalCenter: parent.verticalCenter; active: pill.leading !== null; visible: active }
    UiText {
      id: label
      anchors.verticalCenter: parent.verticalCenter
      text: pill.text
      font.pixelSize: pill.size
      weight: pill.bold ? Font.DemiBold : Font.Normal
      color: pill.kind === "primary" ? Theme.onAccent
        : pill.kind === "link" ? Theme.accentText
        : pill.kind === "danger" ? Theme.redText
        : Theme.text
    }
    UiText {
      anchors.verticalCenter: parent.verticalCenter
      visible: pill.shortcut.length > 0
      text: pill.shortcut
      font.pixelSize: pill.size
      color: pill.kind === "primary" ? Theme.alpha(Theme.onAccent, 0.7) : Theme.secondary
    }
    Loader { sourceComponent: pill.trailing; anchors.verticalCenter: parent.verticalCenter; active: pill.trailing !== null }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: pill.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (pill.enabled) pill.clicked()
  }

  Keys.onReturnPressed: pill.clicked()
  Keys.onEnterPressed: pill.clicked()
  Keys.onSpacePressed: pill.clicked()

  Accessible.role: Accessible.Button
  Accessible.name: pill.text
  Accessible.description: pill.hint
  Accessible.onPressAction: pill.clicked()
}
