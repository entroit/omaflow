import QtQuick
import QtQuick.Controls as Controls
import "Dates.js" as Dates

// One entry: the time, your words in the book face, and for a spoken entry
// the recording you can play back. The actions appear under the pointer so a
// page of entries reads as a page, not a toolbar.
Rectangle {
  id: row

  required property var entry
  required property string date
  property string today: ""
  property var playback: null      // the daemon's journal_playback, if any
  property real nowMs: Date.now()
  property bool editing: false
  // Words typed in the editor before the row was rebuilt, or "".
  property string draft: ""
  property bool spoken: false      // showing the words as spoken
  property bool current: false     // keyboard cursor
  signal editRequested()
  signal saveRequested(string text)
  signal cancelRequested()
  signal deleteRequested()
  signal copyRequested()
  signal playRequested(real offsetMs)
  signal stopRequested()

  readonly property bool playing: playback !== null && playback.date === date && Number(playback.id) === Number(entry.id)
  readonly property real durationMs: playing ? Number(playback.duration_ms) : Number(entry.duration_ms || 0)
  readonly property real positionMs: playing
    ? Math.min(durationMs, Number(playback.offset_ms) + Math.max(0, nowMs - Number(playback.started_at_ms)))
    : pausedAt
  property real pausedAt: 0
  readonly property bool showActions: (hover.hovered || editing || current) && !sealed
  // A note written ahead to this day. Until the day comes it stays sealed,
  // unless you open it early.
  readonly property bool note: String(entry.written || "").length > 0
  property bool openedEarly: false
  readonly property bool sealed: note && today.length > 0 && date > today && !openedEarly
  // Added later to a past day: the day it was really written, or "".
  readonly property string added: String(entry.added || "")
  readonly property string addedDay: added ? Dates.long(added, today || added) : ""
  readonly property string addedText: added ? (entry.typed ? "Typed, added " : "Added ") + addedDay : ""
  // How the entry's buttons name it: "entry from 12:15", or for a note the
  // day it was written.
  readonly property string named: note ? "note from " + Dates.full(entry.written) : "entry from " + entry.time

  width: ListView.view ? ListView.view.width : implicitWidth
  implicitHeight: body.implicitHeight + 28
  radius: Theme.radiusPanel
  color: showActions || playing ? Theme.fill4 : "transparent"
  Behavior on color { ColorAnimation { duration: 120 } }

  HoverHandler { id: hover }

  UiText {
    id: time
    x: 16
    y: 14 + 5
    width: 40
    text: row.note ? "Note" : row.entry.time
    muted: true
    weight: Font.DemiBold
    elide: Text.ElideRight
  }

  Column {
    id: body
    x: 16 + 40 + 16
    y: 14
    width: row.width - x - 16
    spacing: row.entry.typed ? 8 : 10

    // Sealed: when it opens, and a way to read it now.
    BookText {
      visible: row.sealed
      width: parent.width
      text: "Sealed until " + Dates.full(row.date) + "."
      color: Theme.secondary
      font.family: Theme.book
      font.italic: true
      size: 18
      lineHeightMode: Text.FixedHeight
      lineHeight: 28
    }
    Row {
      visible: row.sealed
      spacing: 10
      UiText { anchors.verticalCenter: parent.verticalCenter; text: "Written " + Dates.full(row.entry.written); muted: true; font.pixelSize: 12 }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "link"; text: "Open early"; size: 12; onClicked: row.openedEarly = true }
    }
    BookText {
      visible: !row.editing && !row.sealed
      width: parent.width
      text: row.spoken && row.entry.raw_text ? row.entry.raw_text : row.entry.text
      color: row.spoken ? Theme.secondary : Theme.text
      font.family: Theme.book
      size: 18
      font.italic: row.spoken
      lineHeightMode: Text.FixedHeight
      lineHeight: 28
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
    }

    Controls.TextArea {
      id: editor
      visible: row.editing
      width: parent.width
      text: row.entry.text
      color: Theme.text
      font.family: Theme.book
      font.variableAxes: ({ "wght": 400, "opsz": 18 })
      font.pixelSize: 18
      wrapMode: TextEdit.Wrap
      selectByMouse: true
      selectionColor: Theme.alpha(Theme.accent, 0.4)
      selectedTextColor: Theme.text
      padding: 10
      background: Rectangle { radius: Theme.radiusInput; color: Theme.background; border.width: 1; border.color: Theme.accent }
      // As in the composer: Enter saves, Shift+Enter starts a new line.
      Keys.onEscapePressed: row.cancelRequested()
      Keys.onPressed: function(event) {
        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
          row.saveRequested(editor.text)
          event.accepted = true
        }
      }
      function begin() { text = row.draft || row.entry.text; forceActiveFocus(); cursorPosition = length }
      onVisibleChanged: if (visible) begin()
      // Rebuilt while editing, such as after a failed save: the words come back.
      Component.onCompleted: if (row.editing) Qt.callLater(begin)
      Accessible.name: "Edit " + row.named
    }

    UiText {
      visible: row.note && !row.sealed && !row.editing
      text: "A note you wrote on " + Dates.full(row.entry.written)
      muted: true
      font.pixelSize: 12
    }
    UiText {
      visible: (row.entry.typed || row.added) && !row.editing && !row.note
      text: row.addedText || "Typed"
      muted: true
      font.pixelSize: 12
    }

    Item {
      id: controls
      width: parent.width
      // Where the actions would cover the recording, such as while it plays
      // or in a narrow window, they move to a line of their own under it.
      readonly property bool stacked: player.visible && actionsRow.visible && player.width + actionsRow.width + 6 > width
      height: stacked ? 26 + 8 + 26 : 26
      visible: !row.sealed && (!row.entry.typed || row.editing || row.showActions)

      Row {
        id: player
        visible: !row.editing && !row.entry.typed
        y: (26 - height) / 2
        spacing: 10

        Rectangle {
          width: 24; height: 24; radius: 12
          anchors.verticalCenter: parent.verticalCenter
          visible: row.entry.audio
          color: row.playing ? Theme.accent : playMouse.containsMouse ? Theme.fill22 : Theme.fill18
          activeFocusOnTab: true
          border.width: activeFocus ? 2 : 0
          border.color: Theme.accent
          Icon {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: row.playing ? 0 : 1
            name: row.playing ? "pause" : "play"
            size: 10
            color: row.playing ? Theme.onAccent : Theme.text
          }
          MouseArea {
            id: playMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: row.togglePlay()
          }
          Keys.onSpacePressed: row.togglePlay()
          Keys.onReturnPressed: row.togglePlay()
          Accessible.role: Accessible.Button
          Accessible.name: (row.playing ? "Pause the recording of " : "Play the recording of ") + row.named
        }

        Waveform {
          id: wave
          width: 176
          height: 18
          anchors.verticalCenter: parent.verticalCenter
          peaks: row.entry.peaks
          progress: row.playing || row.pausedAt > 0 ? row.positionMs / Math.max(1, row.durationMs) : -1
          color: row.entry.audio ? Theme.outline : Theme.fill22
          MouseArea {
            anchors.fill: parent
            enabled: row.entry.audio
            cursorShape: Qt.PointingHandCursor
            onClicked: function(mouse) { row.playRequested(row.durationMs * mouse.x / width) }
          }
        }

        UiText {
          anchors.verticalCenter: parent.verticalCenter
          text: row.playing || row.pausedAt > 0
            ? Dates.clock(row.positionMs) + " / " + Dates.clock(row.durationMs)
            : Dates.clock(row.durationMs)
          muted: true
          font.pixelSize: 12
          // Figures only stop jittering where they count up.
          font.features: row.playing ? { "tnum": 1 } : {}
        }
        // The waveform is kept, the sound is not: say why there is no play.
        UiText {
          visible: !row.entry.audio
          anchors.verticalCenter: parent.verticalCenter
          text: "Recording not kept"
          muted: true
          font.pixelSize: 12
        }
      }

      Row {
        id: actionsRow
        anchors.right: parent.right
        y: (controls.stacked ? 26 + 8 : 0) + (26 - height) / 2
        spacing: 6
        opacity: row.showActions ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        Pill { visible: !row.editing; kind: "fill"; text: "Edit"; Accessible.name: "Edit " + row.named; verticalPadding: 4; horizontalPadding: 11; onClicked: row.editRequested() }
        Pill { visible: !row.editing; kind: "fill"; text: "Copy"; Accessible.name: "Copy " + row.named; verticalPadding: 4; horizontalPadding: 11; onClicked: row.copyRequested() }
        Pill {
          visible: !row.editing && !row.entry.typed && Boolean(row.entry.raw_text) && row.entry.raw_text !== row.entry.text
          kind: "fill"; text: "As spoken"; verticalPadding: 4; horizontalPadding: 11
          Accessible.name: "Show " + row.named + " as spoken"
          Accessible.checkable: true
          Accessible.checked: row.spoken
          selected: row.spoken
          onClicked: row.spoken = !row.spoken
        }
        Pill { visible: !row.editing; kind: "danger"; text: "Delete"; Accessible.name: "Delete " + row.named; verticalPadding: 4; horizontalPadding: 11; onClicked: row.deleteRequested() }
        // Enter saves, so say how to start a new paragraph, as the composer does.
        UiText { visible: row.editing; anchors.verticalCenter: parent.verticalCenter; rightPadding: 6; text: "Shift+Enter for a new line"; muted: true; font.pixelSize: 12 }
        // Throws the changes away, as Discard does for a dictation in History.
        Pill { visible: row.editing; kind: "fill"; text: "Discard"; shortcut: "Esc"; verticalPadding: 4; horizontalPadding: 11; onClicked: row.cancelRequested() }
        Pill { visible: row.editing; kind: "primary"; text: "Save"; verticalPadding: 4; horizontalPadding: 11; onClicked: row.saveRequested(editor.text) }
      }
    }
  }

  function togglePlay() {
    if (row.playing) {
      row.pausedAt = row.positionMs >= row.durationMs - 150 ? 0 : row.positionMs
      row.stopRequested()
    } else {
      row.playRequested(row.pausedAt)
    }
  }

  // A pause remembers where it stopped; playing again, from there or from a
  // click on the waveform, starts a new position.
  onPlayingChanged: if (playing) pausedAt = 0

  Accessible.role: Accessible.ListItem
  // A sealed note keeps its words to itself here too.
  Accessible.name: row.sealed ? "Sealed note, opens " + Dates.long(row.date, row.today)
    : row.note ? "Note from " + Dates.full(row.entry.written) + ". " + row.entry.text
    : row.entry.time + (row.added ? (row.entry.typed ? ", typed, added " : ", added ") + row.addedDay : "") + ". " + row.entry.text
}
