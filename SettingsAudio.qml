import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

ColumnLayout {
  id: page

  required property var flow

  spacing: Style.space(12)

  SettingsHeading {
    title: "Microphone sensitivity (" + page.flow.meterGateDb + " dB)"
    note: "Below the marker OmaFlow treats the room as silent. Set it above your room noise and below your voice."
  }

  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: sensitivityContent.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: Util.alpha(Color.popups.text, 0.055)

    ColumnLayout {
      id: sensitivityContent
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(7)

      RowLayout {
        Layout.fillWidth: true

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: page.flow.voiceDetected ? "Voice detected" : "Speak to test. Set the marker above room noise."
          color: page.flow.voiceDetected ? Color.accent : Util.alpha(Color.popups.text, 0.66)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        ActionButton {
          text: "Reset"
          foreground: Color.popups.text
          onClicked: page.flow.commitMeterGate(-60)
        }
      }

      // One control, not two. The live meter is the track and the threshold
      // marker is its handle, so "where my voice reaches" and "where the
      // cutoff sits" are read on the same scale and set by dragging the thing
      // you are looking at.
      Item {
        id: meterControl
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(22)

        readonly property real minimumDb: -70
        readonly property real maximumDb: -35
        // The meter spans -72..0 dBFS, so the adjustable range covers only the
        // quiet end of the track; clamp rather than rescale, or the marker
        // would stop matching the level it is measuring.
        readonly property real minimumPosition: (minimumDb + 72) / 72
        readonly property real maximumPosition: (maximumDb + 72) / 72
        readonly property real thresholdPosition:
          Math.max(0, Math.min(1, (page.flow.meterGateDb + 72) / 72))

        Rectangle {
          id: meterTrack
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: Style.space(10)
          radius: height / 2
          color: Util.alpha(Color.popups.text, 0.10)
          clip: true

          Rectangle {
            width: parent.width * page.flow.micLevel
            height: parent.height
            radius: height / 2
            color: page.flow.voiceDetected ? Color.accent : Util.alpha(Color.popups.text, 0.34)
            Behavior on width { NumberAnimation { duration: page.flow.reducedMotion ? 0 : 45; easing.type: Easing.OutQuad } }
          }
        }

        Rectangle {
          id: meterHandle
          x: Math.max(0, Math.min(parent.width - width,
            parent.width * meterControl.thresholdPosition - width / 2))
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(4, Style.space(4))
          height: parent.height
          radius: width / 2
          color: Color.urgent
          scale: meterDrag.pressed ? 1.12 : meterHover.hovered ? 1.06 : 1
          Behavior on scale { NumberAnimation { duration: page.flow.reducedMotion ? 0 : 90 } }
        }

        HoverHandler {
          id: meterHover
          cursorShape: Qt.SizeHorCursor
        }

        Controls.Slider {
          id: meterDrag
          anchors.fill: parent
          from: -72; to: 0; stepSize: 1
          value: page.flow.meterGateDb
          background: Rectangle { color: "transparent"; border.width: meterDrag.activeFocus ? 1 : 0; border.color: Color.accent }
          handle: Item {}
          Accessible.name: "Microphone sensitivity"
          onMoved: pressed ? page.flow.previewMeterGate(value) : page.flow.commitMeterGate(value)
          onPressedChanged: if (!pressed) page.flow.commitMeterGate(value)
        }
      }

      RowLayout {
        Layout.fillWidth: true

        Text {
          textFormat: Text.PlainText
          text: "More sensitive"
          color: Util.alpha(Color.popups.text, 0.48)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Item { Layout.fillWidth: true }

        Text {
          textFormat: Text.PlainText
          text: "Less sensitive"
          color: Util.alpha(Color.popups.text, 0.48)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  SettingsHeading {
    title: "Quiet everything else while you talk"
    note: "Music and video are turned down for as long as you hold the hotkey, and come back to where you left them the moment you let go."
  }

  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: duckContent.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: Util.alpha(Color.popups.text, 0.055)

    ColumnLayout {
      id: duckContent
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(7)

      RowLayout {
        Layout.fillWidth: true

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: duckSlider.liveValue <= 0 ? "Leave other audio alone"
            : duckSlider.liveValue >= 100 ? "Silence other audio completely"
            : "Turn other audio down by " + Math.round(duckSlider.liveValue) + "%"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        ActionButton {
          text: "Reset"
          foreground: Color.popups.text
          onClicked: page.flow.preference("duck_audio_percent", 70)
        }
      }

      PanelSlider {
        id: duckSlider
        Layout.fillWidth: true
        minimum: 0
        maximum: 100
        step: 5
        integer: true
        value: page.flow.duckAudioPercent
        trackColor: Util.alpha(Color.popups.text, 0.12)
        fillColor: Color.accent
        knobColor: Color.accent
        tickColor: Color.popups.background
        Accessible.name: "How much to quiet other audio while dictating"
        onReleased: function(value) { page.flow.preference("duck_audio_percent", Math.round(value)) }
      }

      RowLayout {
        Layout.fillWidth: true

        Text {
          textFormat: Text.PlainText
          text: "Off"
          color: Util.alpha(Color.popups.text, 0.48)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Item { Layout.fillWidth: true }

        Text {
          textFormat: Text.PlainText
          text: "Silent"
          color: Util.alpha(Color.popups.text, 0.48)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: "This moves the volume of your default output. If you change the volume yourself mid-sentence, releasing the hotkey puts back the level OmaFlow found."
        color: Util.alpha(Color.popups.text, 0.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
