import QtQuick

// A settings page's name and one sentence on what it is for.
Column {
  property string title: ""
  property string subtitle: ""
  property string backText: ""
  signal back()
  spacing: 4
  Pill { visible: parent.backText.length > 0; kind: "link"; text: "‹ " + parent.backText; size: 13; horizontalPadding: 0; verticalPadding: 2; onClicked: parent.back() }
  UiText { text: parent.title; font.pixelSize: 22; weight: Font.Bold; font.letterSpacing: -0.22; lineHeight: 28; Accessible.role: Accessible.Heading }
  UiText { visible: parent.subtitle.length > 0; width: parent.width; text: parent.subtitle; muted: true; wrapMode: Text.Wrap }
}
