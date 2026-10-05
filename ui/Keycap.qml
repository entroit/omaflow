import QtQuick

// A key or a chord, set in the mono face because it is something you type.
Rectangle {
  id: cap
  property string text: ""
  property bool compact: false
  implicitWidth: label.implicitWidth + (compact ? 10 : 20)
  implicitHeight: compact ? 18 : 28
  radius: compact ? Theme.radiusKey : height / 2
  color: compact ? "transparent" : Theme.fill4
  border.width: 1
  border.color: Theme.outline

  UiText {
    id: label
    anchors.centerIn: parent
    text: cap.text
    font.family: Theme.mono
    font.pixelSize: cap.compact ? 11 : 12
    weight: cap.compact ? Font.Normal : Font.DemiBold
    color: cap.compact ? Theme.secondary : Theme.text
  }
}
