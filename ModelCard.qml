import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// One model in a picker: what it is, what it costs you in disk and memory,
// and the single button that matters right now. A model you do not have is
// offered for download; a model you have is offered for use; the one in use
// says so and offers nothing. Download progress replaces the button in place,
// because a weights pull is minutes long and the panel should not go quiet.
Rectangle {
  id: card

  required property var flow
  // "speech" or "cleanup". Decides which catalog the two commands address.
  required property string kind
  required property var entry
  readonly property var job: card.flow.downloadFor(card.entry.id)
  readonly property bool downloading: card.job !== null && card.job.state === "downloading"
  readonly property bool failed: card.job !== null && card.job.state === "failed"

  Layout.fillWidth: true
  Layout.preferredHeight: body.implicitHeight + Style.space(20)
  radius: Style.cornerRadius
  color: card.entry.selected
    ? Util.alpha(Color.accent, 0.14)
    : Util.alpha(Color.popups.text, 0.05)
  border.width: card.entry.selected ? Math.max(1, Style.spacing.hairline) : 0
  border.color: Util.alpha(Color.accent, 0.55)

  ColumnLayout {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.margins: Style.space(10)
    spacing: Style.space(6)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: String(card.entry.label || card.entry.id)
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Rectangle {
            visible: String(card.entry.tier || "") === "recommended"
            Layout.preferredWidth: tierLabel.implicitWidth + Style.space(10)
            Layout.preferredHeight: tierLabel.implicitHeight + Style.space(4)
            radius: height / 2
            color: Util.alpha(Color.accent, 0.22)

            Text {
              id: tierLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "Recommended"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Item { Layout.fillWidth: true }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: String(card.entry.detail || "")
          wrapMode: Text.Wrap
          color: Util.alpha(Color.popups.text, 0.62)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: [
            card.entry.size_mb > 0 ? (Number(card.entry.size_mb) / 1024).toFixed(1) + " GB download" : "",
            String(card.entry.hardware || ""),
            String(card.entry.license || "")
          ].filter(function(part) { return part.length > 0 }).join(" · ")
          wrapMode: Text.Wrap
          color: Util.alpha(Color.popups.text, 0.45)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ActionButton {
        visible: !card.downloading && !card.entry.selected && card.entry.installed
        text: "Use"
        foreground: Color.popups.text
        background: Util.alpha(Color.accent, 0.22)
        bordered: true
        onClicked: card.flow.selectModel(card.kind, card.entry.id)
      }

      ActionButton {
        visible: !card.downloading && !card.entry.installed
        text: card.failed ? "Try again" : "Download"
        foreground: Color.popups.text
        bordered: true
        tooltipText: "Downloads the weights, then switches to this model"
        onClicked: card.flow.installModel(card.kind, card.entry.id)
      }

      Text {
        visible: card.entry.selected && !card.downloading
        textFormat: Text.PlainText
        text: "In use"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    // Progress takes the full width rather than sitting inside the button,
    // so a long pull reads as a job the app is running, not a stuck control.
    ColumnLayout {
      visible: card.downloading
      Layout.fillWidth: true
      spacing: Style.space(4)

      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(5)
        radius: height / 2
        color: Util.alpha(Color.popups.text, 0.12)
        clip: true

        Rectangle {
          width: parent.width * Math.max(0, Math.min(1, Number(card.job ? card.job.percent : 0) / 100))
          height: parent.height
          radius: height / 2
          color: Color.accent
          Behavior on width { NumberAnimation { duration: card.flow.reducedMotion ? 0 : 200 } }
        }
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: card.job && card.job.message ? String(card.job.message)
          : "Downloading… " + Math.round(Number(card.job ? card.job.percent : 0)) + "%"
        wrapMode: Text.Wrap
        color: Util.alpha(Color.popups.text, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      visible: card.failed
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: card.job && card.job.message ? String(card.job.message) : "The download did not finish."
      wrapMode: Text.Wrap
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
