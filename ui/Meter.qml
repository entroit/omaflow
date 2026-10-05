import QtQuick
import QtQuick.Controls as Controls

// The live microphone level, and optionally the voice threshold as a marker
// you drag on the same scale: where your voice reaches and where the cutoff
// sits are read, and set, in one place.
Item {
  id: meter
  required property var app
  property bool adjustable: false
  implicitHeight: adjustable ? 22 : 6

  readonly property real thresholdPosition: Math.max(0, Math.min(1, (app.meterGateDb + 72) / 72))

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

  Rectangle {
    visible: meter.adjustable
    x: Math.max(0, Math.min(parent.width - width, parent.width * meter.thresholdPosition - width / 2))
    anchors.verticalCenter: parent.verticalCenter
    width: 4
    height: parent.height
    radius: 2
    color: Theme.text
  }

  Controls.Slider {
    visible: meter.adjustable
    anchors.fill: parent
    from: -72; to: 0; stepSize: 1
    value: meter.app.meterGateDb
    background: Item {}
    handle: Item {}
    onMoved: pressed ? meter.app.previewMeterGate(value) : meter.app.commitMeterGate(value)
    onPressedChanged: if (!pressed) meter.app.commitMeterGate(value)
    Accessible.name: "Voice threshold"
  }
}
