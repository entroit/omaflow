import QtQuick

// Journal words, in Newsreader. Its optical size follows the type size, so a
// 36 px heading gets the display cut and an 18 px entry the text cut.
Text {
  property int weight: Font.Normal
  property int size: 18
  color: Theme.text
  font.family: Theme.book
  font.pixelSize: size
  font.weight: weight
  font.variableAxes: ({ "wght": weight, "opsz": Math.max(6, Math.min(72, size)) })
  textFormat: Text.PlainText
  wrapMode: Text.Wrap
}
