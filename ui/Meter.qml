import QtQuick
import QtQuick.Controls as Controls

// The live microphone level, and optionally the voice threshold as a marker
// on the same scale: where your voice reaches and where the cutoff sits are
// read, and set, in one place. With the threshold set automatically the
// marker follows it and can't be dragged.
Item {
  id: meter
  required property var app
  property bool adjustable: false
  implicitHeight: adjustable ? 22 : 6

  readonly property int thresholdDb: app.meterGateAuto ? app.meterGateEffectiveDb : app.meterGateDb
  readonly property real thresholdPosition: position(thresholdDb)
  // The scale runs from -72 to 0 dB; the threshold can sit from -70 to -35.
  function position(db) { return Math.max(0, Math.min(1, (db + 72) / 72)) }

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: meter.adjustable ? 10 : 6
    radius: height / 2
    color: Theme.fill8
    clip: true
    Rectangle {
      width: parent.width * meter.app.micLevel
      height: parent.height
      radius: height / 2
      color: meter.app.micDetected ? Theme.green : Theme.outline
      Behavior on width { NumberAnimation { duration: 45 } }
    }
  }

  // Where the marker can go, shown while you set it, so it doesn't seem to
  // stop halfway for no reason.
  Rectangle {
    visible: gate.visible
    x: gate.x
    width: gate.width
    anchors.verticalCenter: parent.verticalCenter
    height: track.height + 6
    radius: height / 2
    color: "transparent"
    border.width: 1
    border.color: Theme.outline
  }

  Rectangle {
    id: marker
    visible: meter.adjustable
    x: Math.max(0, Math.min(parent.width - width, parent.width * meter.thresholdPosition - width / 2))
    anchors.verticalCenter: parent.verticalCenter
    width: 4
    height: parent.height
    radius: 2
    color: meter.app.meterGateAuto ? Theme.secondary : Theme.text
    // The automatic threshold moves in whole dB steps; glide between them.
    Behavior on x { enabled: meter.app.meterGateAuto; NumberAnimation { duration: 250 } }
  }

  // Keyboard focus is a ring around the marker, like the other controls.
  Rectangle {
    visible: gate.visible && gate.activeFocus
    x: marker.x - 3
    y: marker.y - 3
    width: marker.width + 6
    height: marker.height + 6
    radius: 4
    color: "transparent"
    border.width: 2
    border.color: Theme.accent
  }

  // Spans only the range the threshold can take, so the marker follows the
  // pointer exactly and the arrow keys move it by one dB.
  Controls.Slider {
    id: gate
    visible: meter.adjustable && !meter.app.meterGateAuto
    x: meter.width * meter.position(-70)
    width: meter.width * (meter.position(-35) - meter.position(-70))
    height: parent.height
    padding: 0
    from: -70; to: -35; stepSize: 1
    value: meter.app.meterGateDb
    background: Item {}
    handle: Item {}
    onMoved: pressed ? meter.app.previewMeterGate(value) : meter.app.commitMeterGate(value)
    onPressedChanged: if (!pressed) meter.app.commitMeterGate(value)
    Accessible.name: "Voice threshold"
  }
}
