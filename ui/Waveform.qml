import QtQuick

// A recording's loudness outline, 2 px bars on a 4 px pitch. The played part
// takes the accent colour; `live` draws the newest levels scrolling in from
// the right instead.
Item {
  id: wave

  property var peaks: []           // 0..100 per step, or 0..1 when live
  property real progress: -1       // 0..1, or -1 when not playing
  property bool live: false
  property color color: Theme.outline
  property color playedColor: Theme.accent
  property int barWidth: 2
  property int gap: 2

  implicitHeight: 18
  readonly property int count: Math.max(1, Math.floor((width + gap) / (barWidth + gap)))

  function sample(index) {
    if (!peaks || peaks.length === 0) return 0.15
    if (live) {
      var offset = peaks.length - count + index
      return offset < 0 ? 0 : Number(peaks[offset])
    }
    var position = Math.floor(index * peaks.length / count)
    return Number(peaks[Math.min(peaks.length - 1, position)]) / 100
  }

  Row {
    anchors.verticalCenter: parent.verticalCenter
    spacing: wave.gap
    Repeater {
      model: wave.count
      Rectangle {
        required property int index
        readonly property real level: Math.max(0, Math.min(1, wave.sample(index)))
        anchors.verticalCenter: parent.verticalCenter
        width: wave.barWidth
        height: Math.max(3, Math.round(wave.height * (0.16 + 0.84 * level)))
        radius: width / 2
        color: wave.progress >= 0 && index / wave.count <= wave.progress ? wave.playedColor : wave.color
        Behavior on height { enabled: wave.live; NumberAnimation { duration: 50 } }
      }
    }
  }
}
