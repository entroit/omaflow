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
  // The last row's fill follows the table's rounded corners.
  property bool last: false
  readonly property var job: app.downloadFor(entry.id)
  readonly property bool downloading: job !== null && job.state === "downloading"
  readonly property bool failed: job !== null && job.state === "failed"
  // Chosen but not on disk yet, as after a fresh install: still the one to get.
  readonly property bool inUse: entry.selected === true && entry.installed === true
  readonly property bool missing: entry.selected === true && entry.installed !== true
  readonly property string label: String(entry.label || entry.id)
  // Decimal units, as the download progress counts them: 1178 MB is 1.2 GB.
  readonly property string size: entry.size_mb > 0 ? (entry.size_mb >= 1000 ? (entry.size_mb / 1000).toFixed(1) + " GB" : entry.size_mb + " MB") : ""
  // The speech model says whether it is loaded; cleanup loads on demand,
  // and only Medium uses it.
  readonly property bool cleanupDown: kind !== "speech" && app.cleanupLevel === "medium" && app.cleanupRuntime !== "ready"
  readonly property string inUseText: kind !== "speech" ? (app.cleanupLevel !== "medium" ? "Used by Medium" : cleanupDown ? "In use, not answering" : "In use")
    : app.asrRunning ? "In use, loaded"
    : app.asrFailed === true ? "In use, stopped"
    : "In use, not loaded right now"
  // Green only while it works: a stopped model is a problem, a cleanup
  // model whose runtime is not answering is a warning, and one that is idle
  // or waiting for Medium is neither.
  readonly property bool stopped: kind === "speech" && !app.asrRunning && app.asrFailed === true
  readonly property color inUseColor: stopped ? Theme.redText
    : cleanupDown ? Theme.yellowText
    : (kind === "speech" ? app.asrRunning : app.cleanupLevel === "medium") ? Theme.greenText : Theme.secondary
  readonly property string action: entry.installed ? "Use" : failed ? "Try again"
    : missing ? "Download" + (size ? " (" + size + ")" : "")
    // Under Light or Off a cleanup model is only Medium's, not used yet.
    : kind !== "speech" && app.cleanupLevel !== "medium" ? "Download for Medium" : "Download and use"

  width: parent ? parent.width : 600
  implicitHeight: body.implicitHeight + 26

  Rectangle { visible: !row.first; width: parent.width; height: 1; color: Theme.divider }
  Rectangle {
    anchors.fill: parent
    anchors.topMargin: row.first ? 0 : 1
    topLeftRadius: row.first ? Theme.radiusCard + 1 : 0
    topRightRadius: topLeftRadius
    bottomLeftRadius: row.last ? Theme.radiusCard + 1 : 0
    bottomRightRadius: bottomLeftRadius
    color: row.entry.selected ? Theme.fill4 : "transparent"
  }

  Column {
    id: body
    x: 14; y: 13
    width: parent.width - 28
    spacing: 6

    Item {
      width: parent.width
      height: Math.max(titles.implicitHeight, actions.height)
      Column {
        id: titles
        width: parent.width - 250
        spacing: 2
        // The badge wraps under the name where the two don't fit beside the
        // Size column.
        Flow {
          width: parent.width
          spacing: 8
          UiText { id: name; width: Math.min(implicitWidth, parent.width); wrapMode: Text.Wrap; text: row.label; font.pixelSize: 14; weight: Font.DemiBold }
          // One name line high, so the badge centres on that line.
          Item {
            visible: row.entry.tier === "recommended"
            width: badge.width
            height: name.lineHeight
            Rectangle {
              id: badge
              anchors.verticalCenter: parent.verticalCenter
              width: tag.implicitWidth + 12
              height: tag.implicitHeight + 2
              radius: height / 2
              color: "transparent"
              border.width: 1
              border.color: Theme.outline
              UiText { id: tag; anchors.centerIn: parent; text: "Recommended"; font.pixelSize: 11; color: Theme.secondary }
            }
          }
        }
        UiText {
          visible: row.inUse
          text: row.inUseText
          color: row.inUseColor
          font.pixelSize: 12
        }
        UiText {
          width: parent.width
          text: String(row.entry.detail || "")
          color: Theme.secondary
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
        UiText {
          width: parent.width
          visible: text.length > 0
          text: [String(row.entry.hardware || "").replace(/\.$/, ""), row.entry.license ? "Licence: " + row.entry.license : ""]
            .filter(function(part) { return part.length > 0 }).join(". ")
          muted: true
          font.pixelSize: 11
          wrapMode: Text.Wrap
        }
      }
      UiText {
        x: parent.width - 236
        width: 70
        text: row.size
        font.pixelSize: 13
      }
      Item {
        id: actions
        anchors.right: parent.right
        width: 150
        height: 28
        Pill {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !row.downloading && !row.inUse
          kind: row.missing ? "primary" : "link"
          text: row.action
          size: 13
          horizontalPadding: row.missing ? 12 : 4
          Accessible.name: row.failed ? "Try downloading " + row.label + " again"
            : row.action === "Download for Medium" ? "Download " + row.label + " for Medium"
            : (row.missing ? "Download" : row.action) + " " + row.label
          onClicked: row.entry.installed ? row.app.selectModel(row.kind, row.entry.id) : row.app.installModel(row.kind, row.entry.id)
        }
        // The fix for a stopped model, where the row says it stopped.
        Pill {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: row.inUse && row.stopped
          kind: "link"; text: "Restart"; size: 13; horizontalPadding: 4
          Accessible.name: "Restart " + row.label
          onClicked: row.app.restartSpeech()
        }
      }
    }

    Column {
      visible: row.downloading
      width: parent.width
      spacing: 4
      Item {
        width: parent.width
        height: cancel.height
        Rectangle {
          anchors.left: parent.left
          anchors.right: cancel.left
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          height: 5; radius: 2.5; color: Theme.fill18
          Rectangle { width: parent.width * Math.max(0, Math.min(1, Number(row.job ? row.job.percent : 0) / 100)); height: parent.height; radius: 2.5; color: Theme.accent }
        }
        Pill {
          id: cancel
          anchors.right: parent.right
          kind: "link"; text: "Cancel"; size: 13; horizontalPadding: 4
          Accessible.name: "Cancel the " + row.label + " download"
          onClicked: row.app.cancelModel(row.kind, row.entry.id)
        }
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
