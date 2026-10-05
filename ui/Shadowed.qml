import QtQuick
import QtQuick.Effects

// A surface that floats: the overlay card, the composer, toasts and sheets.
// Only things that sit above other things get a shadow.
Item {
  id: root

  property color color: Theme.fill4
  property real radius: height / 2
  property color borderColor: Theme.divider
  property real borderWidth: 1
  property real shadowBlur: 28
  property real shadowOffset: 10
  property real shadowOpacity: 0.35
  // Keeps what is inside within the surface while it changes size.
  property bool clipContent: false
  default property alias content: body.data

  Rectangle {
    id: plate
    anchors.fill: parent
    radius: root.radius
    color: root.color
    visible: false
  }

  MultiEffect {
    source: plate
    anchors.fill: plate
    shadowEnabled: true
    shadowColor: Qt.rgba(0, 0, 0, root.shadowOpacity)
    shadowBlur: 1.0
    blurMax: root.shadowBlur
    shadowVerticalOffset: root.shadowOffset
    autoPaddingEnabled: true
  }

  // The fill is drawn again above the shadow, so the surface never depends
  // on the effect having rendered its source.
  Rectangle {
    anchors.fill: parent
    radius: root.radius
    color: root.color
    border.width: root.borderWidth
    border.color: root.borderColor
  }

  Item {
    id: body
    anchors.fill: parent
    clip: root.clipContent
  }
}
