import QtQuick

// One model: what it is and costs, and the one action that matters now.
// A model you do not have is offered for download, one you have for use, and
// the one in use says so. Download progress replaces the action in place.
Item {
  id: row

  required property var app
  required property string kind
  required property var entry
  property bool first: false
  readonly property var job: app.downloadFor(entry.id)
  readonly property bool downloading: job !== null && job.state === "downloading"
  readonly property bool failed: job !== null && job.state === "failed"

  width: parent ? parent.width : 600
  implicitHeight: body.implicitHeight + 26

  Rectangle { visible: !row.first; width: parent.width; height: 1; color: Theme.divider }
  Rectangle { anchors.fill: parent; anchors.topMargin: row.first ? 0 : 1; color: row.entry.selected ? Theme.fill4 : "transparent"; radius: row.first ? 0 : 0 }

  Column {
    id: body
    x: 14; y: 13
    width: parent.width - 28
    spacing: 6

    Item {
      width: parent.width
      height: titles.implicitHeight
      Column {
        id: titles
        width: parent.width - 260
        spacing: 2
        UiText { text: String(row.entry.label || row.entry.id); font.pixelSize: 14; weight: Font.DemiBold }
        UiText {
          width: parent.width
          text: row.entry.selected ? "In use" : String(row.entry.detail || "")
          color: row.entry.selected ? Theme.greenText : Theme.secondary
          font.pixelSize: 12
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }
      UiText {
        x: parent.width - 250
        width: 70
        text: row.entry.size_mb > 0 ? (row.entry.size_mb >= 1000 ? (row.entry.size_mb / 1024).toFixed(1) + " GB" : row.entry.size_mb + " MB") : ""
        font.pixelSize: 13
      }
      UiText {
        x: parent.width - 175
        width: 100
        text: String(row.entry.license || "")
        muted: true
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      Item {
        anchors.right: parent.right
        width: 76
        height: 28
        Pill {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !row.downloading && !row.entry.selected
          kind: "link"
          text: row.entry.installed ? "Use" : row.failed ? "Try again" : "Download"
          size: 13
          horizontalPadding: 4
          onClicked: row.entry.installed ? row.app.selectModel(row.kind, row.entry.id) : row.app.installModel(row.kind, row.entry.id)
        }
      }
    }

    Column {
      visible: row.downloading
      width: parent.width
      spacing: 4
      Rectangle {
        width: parent.width; height: 5; radius: 2.5; color: Theme.fill18
        Rectangle { width: parent.width * Math.max(0, Math.min(1, Number(row.job ? row.job.percent : 0) / 100)); height: parent.height; radius: 2.5; color: Theme.accent }
      }
      UiText { width: parent.width; text: row.job && row.job.message ? String(row.job.message) : "Downloading"; muted: true; font.pixelSize: 12; elide: Text.ElideRight }
    }
    UiText {
      visible: row.failed
      width: parent.width
      text: row.job && row.job.message ? String(row.job.message) : "The download did not finish."
      color: Theme.redText
      font.pixelSize: 12
      wrapMode: Text.Wrap
    }
  }
}
