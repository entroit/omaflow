import QtQuick

// Check the microphone before you rely on it, and decide what happens to
// other audio while you talk.
Column {
  id: page
  required property var app
  spacing: 22

  PageTitle { width: parent.width; title: "Audio"; subtitle: "Check the microphone before you rely on it." }

  Rectangle {
    width: parent.width
    height: mic.implicitHeight + 36
    radius: Theme.radiusPanel
    color: Theme.fill4
    Column {
      id: mic
      x: 18; y: 18
      width: parent.width - 36
      spacing: 10
      UiText { text: "Microphone"; muted: true; font.pixelSize: 12 }
      UiText { text: page.app.micDetected ? "Voice detected" : "Speak to test"; font.pixelSize: 15; weight: Font.Bold; color: page.app.micDetected ? Theme.greenText : Theme.text }
      Meter { width: parent.width; app: page.app; adjustable: true }
      Item {
        width: parent.width
        height: 20
        UiText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Voice threshold " + page.app.meterGateDb + " dB. Drag the marker just above the room's noise."; muted: true; font.pixelSize: 12 }
        Pill { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; kind: "link"; text: "Reset"; size: 12; horizontalPadding: 4; onClicked: page.app.commitMeterGate(-60) }
      }
      UiText { width: parent.width; wrapMode: Text.Wrap; muted: true; font.pixelSize: 12; text: "The threshold only decides when the card says it hears you. Every recorded sound still reaches the speech model." }
    }
  }

  Column {
    width: parent.width
    spacing: 12
    Item {
      width: parent.width
      height: 22
      UiText { anchors.verticalCenter: parent.verticalCenter; text: "Lower other audio while recording"; font.pixelSize: 14; weight: Font.DemiBold }
      UiText {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: duck.value <= 0 ? "Off" : duck.value >= 100 ? "Silent" : "By " + Math.round(duck.value) + "%"
        muted: true
      }
    }
    Slider {
      id: duck
      width: parent.width
      label: "Lower other audio while recording"
      from: 0; to: 100; stepSize: 5
      value: page.app.duckAudioPercent
      onPressedChanged: if (!pressed) page.app.preference("duck_audio_percent", Math.round(value))
    }
    UiText { width: parent.width; wrapMode: Text.Wrap; muted: true; font.pixelSize: 12; text: "Music and video come back to where they were the moment the take ends." }
  }
}
