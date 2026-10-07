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
      // The same line and link as Basics: which input, and whether it hears you.
      Item {
        width: parent.width
        height: Math.max(micText.implicitHeight, soundSettings.height)
        UiText {
          id: micText
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - soundSettings.width - 8
          wrapMode: Text.Wrap
          readonly property string device: String(page.app.inputDevice || "")
          text: page.app.micDetected ? "Your voice is coming through" + (device ? " on " + device : "") + "."
            : device ? "Listening on " + device + " (default input). Speak to test."
            : "Uses your default input. Speak to test."
          font.pixelSize: 15
          weight: Font.Bold
          color: page.app.micDetected ? Theme.greenText : Theme.text
        }
        Pill {
          id: soundSettings
          anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
          kind: "link"; text: "Change in sound settings"; size: 13; horizontalPadding: 4
          onClicked: page.app.spawn(["omarchy-shell", "shell", "toggle", "omarchy.audio"])
        }
      }
      Meter { width: parent.width; app: page.app; adjustable: true }
      // Automatic by default, as in call apps; the marker is only yours to
      // drag with this off. The words switch it too.
      Item {
        width: parent.width
        height: Math.max(autoLabels.implicitHeight, autoToggle.height)
        Column {
          id: autoLabels
          width: parent.width - autoToggle.width - 16
          spacing: 3
          UiText { text: "Set the threshold automatically"; font.pixelSize: 14; weight: Font.DemiBold }
          UiText { width: parent.width; wrapMode: Text.Wrap; muted: true; font.pixelSize: 12; text: "Follows the room's noise, like most call apps. The bar turns green when your voice passes the marker." }
        }
        MouseArea {
          anchors.fill: autoLabels
          cursorShape: Qt.PointingHandCursor
          onClicked: autoToggle.toggled()
        }
        Toggle {
          id: autoToggle
          anchors.right: parent.right
          anchors.top: parent.top
          label: "Set the threshold automatically"
          checked: page.app.meterGateAuto
          // Off keeps the threshold where the marker is now. Setting it turns
          // automatic off too, so that is the one command sent.
          onToggled: {
            if (!checked) page.app.setMeterGateAuto(true)
            else {
              page.app.commitMeterGate(page.app.meterGateEffectiveDb)
              page.app.meterGateAuto = false
            }
          }
        }
      }
      UiText { visible: !page.app.meterGateAuto; text: "Drag the marker just above the room's noise. It moves within the outlined range."; muted: true; font.pixelSize: 12 }
      UiText { width: parent.width; wrapMode: Text.Wrap; muted: true; font.pixelSize: 12; text: "The marker only decides when the card says it hears you. Every recorded sound still reaches the speech model." }
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
    UiText { width: parent.width; wrapMode: Text.Wrap; muted: true; font.pixelSize: 12; text: "Music and video come back to where they were the moment the recording ends." }
  }
}
