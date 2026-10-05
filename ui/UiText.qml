import QtQuick

// Interface text: Schibsted Grotesk in the theme's text colour, plain text
// unless a caller asks otherwise.
Text {
  property bool muted: false
  // Set the weight here, not on font.weight: the variable font's weight axis
  // follows this, and Qt does not map font.weight onto that axis by itself.
  property int weight: Font.Normal
  color: muted ? Theme.secondary : Theme.text
  font.family: Theme.sans
  font.pixelSize: 13
  lineHeightMode: Text.FixedHeight
  lineHeight: Math.round(font.pixelSize * 1.3)
  font.weight: weight
  font.variableAxes: ({ "wght": weight })
  textFormat: Text.PlainText
  wrapMode: Text.NoWrap
  verticalAlignment: Text.AlignVCenter
}
