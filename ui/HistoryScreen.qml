import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import "Dates.js" as Dates
import "Diff.js" as Diff

// Every dictation you kept, newest first, and what cleanup did to it. The
// list is for finding; the page on the right is for getting the words back
// out: paste again, copy, or fix a word and save it.
FocusScope {
  id: screen

  required property var app
  signal openSettings(string target)

  property string query: ""
  property string selectedId: ""
  property string view: "cleaned"
  property string toast: ""

  readonly property var entries: {
    var needle = query.trim().toLowerCase()
    if (needle.length === 0) return app.history
    return app.history.filter(function(entry) {
      return String(entry.text || "").toLowerCase().indexOf(needle) >= 0
        || String(entry.raw_text || "").toLowerCase().indexOf(needle) >= 0
    })
  }
  readonly property int selectedIndex: {
    for (var i = 0; i < entries.length; i++) if (String(entries[i].id) === selectedId) return i
    return entries.length > 0 ? 0 : -1
  }
  readonly property var selected: selectedIndex >= 0 ? entries[selectedIndex] : null
  // The raw transcript is always offered when there is one, even when cleanup
  // left it as it was; the actions that only matter when the two differ check
  // rawDiffers.
  readonly property bool hasRaw: selected !== null && Boolean(selected.raw_text)
  readonly property bool rawDiffers: hasRaw && selected.raw_text !== selected.text

  function select(index) {
    if (index < 0 || index >= entries.length) return
    selectedId = String(entries[index].id)
    list.positionViewAtIndex(index, ListView.Contain)
  }

  onSelectedIdChanged: view = "cleaned"
  // A different entry, or a saved change to this one, replaces the editor's
  // text; your unsaved typing on the same entry is left alone.
  onSelectedChanged: loadEditor()
  function loadEditor() {
    var entry = selected
    var id = entry ? String(entry.id) : ""
    var text = entry ? String(entry.text || "") : ""
    if (id === editor.loadedId && editor.text !== editor.loadedText && editor.text !== text) return
    editor.loadedId = id
    editor.loadedText = text
    editor.text = text
  }

  Connections {
    target: screen.app
    function onFeedbackChanged() {
      if (screen.app.feedback.length > 0) { screen.toast = screen.app.feedback; toastTimer.restart() }
    }
  }
  Timer { id: toastTimer; interval: 5000; onTriggered: screen.toast = "" }

  // The page's own keys, with no field focused. Focusing the scope itself
  // would hand focus back to the last field in it.
  Item { id: keyTarget; focus: true }
  function focusKeys() { keyTarget.forceActiveFocus() }

  Keys.onPressed: function(event) {
    if (event.text === "/" && !search.input.activeFocus) { search.input.forceActiveFocus(); event.accepted = true; return }
    if (editor.activeFocus) return
    if (event.key === Qt.Key_Down || event.text === "j") { screen.select(screen.selectedIndex + 1); event.accepted = true }
    else if (event.key === Qt.Key_Up || event.text === "k") { screen.select(screen.selectedIndex - 1); event.accepted = true }
    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && screen.selected) { screen.app.pasteHistory(screen.selected.id); event.accepted = true }
    else if (event.key === Qt.Key_Delete && screen.selected) { screen.app.deleteHistory(screen.selected.id); event.accepted = true }
    else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier) && screen.selected) { screen.app.copyHistory(screen.selected.id); event.accepted = true }
  }

  // ------------------------------------------------------ nothing kept yet
  Item {
    anchors.fill: parent
    visible: screen.app.history.length === 0

    Column {
      x: 120
      width: Math.min(parent.width - 240, 520)
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -20
      spacing: 44

      SetupBanner { width: Math.min(640, screen.width - 240); app: screen.app; onOpenSettings: function(target) { screen.openSettings(target) } }

      EmptyState {
        width: parent.width
        title: "No dictations yet"
        body: !screen.app.binaryFound || screen.app.setupUnfinished
          ? "Once a speech model is ready, hold " + screen.app.hotkeyLabel + " in any app and start talking. Each take is saved here."
          : "Hold " + screen.app.hotkeyLabel + " in any app and start talking. Each take is saved here, so you can paste it again or fix a word."
        footnote: screen.app.historyLimit === 0
          ? "History is off, so nothing is kept. Change this in Privacy."
          : "The last " + screen.app.historyLimit + " dictations are kept on this computer. Change this in Privacy."
        Pill { kind: "outline"; text: "Retention settings"; size: 13; verticalPadding: 7; horizontalPadding: 12; onClicked: screen.openSettings("privacy") }
      }
    }
  }

  // ------------------------------------------------------------ the list
  RowLayout {
    anchors.fill: parent
    spacing: 0
    visible: screen.app.history.length > 0

    Item {
      Layout.preferredWidth: 320
      Layout.fillHeight: true

      SearchField {
        id: search
        x: 12; y: 16
        width: parent.width - 24
        placeholder: "Search dictations"
        onTextChanged: screen.query = text
        onEscaped: screen.focusKeys()
        onDown: screen.select(screen.selectedIndex + 1)
        onUp: screen.select(screen.selectedIndex - 1)
      }

      ListView {
        id: list
        anchors.top: search.bottom
        anchors.topMargin: 4
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 12
        x: 12
        width: parent.width - 24
        clip: true
        spacing: 5
        boundsBehavior: Flickable.StopAtBounds
        model: screen.entries
        delegate: Item {
          id: item
          required property var modelData
          required property int index
          // A day heading above the first take of each day.
          readonly property string group: Dates.group(modelData.created_at_ms, screen.app.nowMs)
          readonly property bool opensGroup: index === 0
            || Dates.group(screen.entries[index - 1].created_at_ms, screen.app.nowMs) !== group
          readonly property bool isSelected: index === screen.selectedIndex
          width: list.width
          height: card.height + (opensGroup ? 34 : 0)

          UiText {
            visible: item.opensGroup
            x: 10; y: 14
            text: item.group
            weight: Font.DemiBold
          }

          Rectangle {
          id: card
          y: item.opensGroup ? 34 : 0
          width: parent.width
          height: column.implicitHeight + 20
          radius: Theme.radiusCard
          color: item.isSelected ? Theme.fill18 : itemMouse.containsMouse ? Theme.fill8 : "transparent"

          Column {
            id: column
            x: 10; y: 10
            width: parent.width - 20
            spacing: 3
            // The time, and a word only when the take did not go as usual.
            Row {
              spacing: 8
              UiText {
                text: Dates.stamp(item.modelData.created_at_ms, screen.app.nowMs)
                color: Theme.secondary
                font.pixelSize: 12
              }
              UiText {
                visible: text.length > 0
                text: item.modelData.cleanup_warning ? "Cleanup skipped" : item.modelData.pasted ? "" : "Copied only"
                color: item.modelData.cleanup_warning ? Theme.yellowText : Theme.secondary
                font.pixelSize: 12
              }
            }
            UiText {
              width: parent.width
              text: String(item.modelData.text || "")
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
              lineHeight: 17
            }
          }
          MouseArea { id: itemMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { screen.select(item.index); screen.focusKeys() } }
          }
          Accessible.role: Accessible.ListItem
          Accessible.name: String(item.modelData.text || "")
          Accessible.selected: isSelected
        }

        Column {
          visible: screen.entries.length === 0 && screen.query.length > 0
          x: 10; y: 22
          width: parent.width - 20
          spacing: 10
          UiText { text: "Nothing matches “" + screen.query.trim() + "”"; font.pixelSize: 14; weight: Font.Bold; width: parent.width; elide: Text.ElideRight }
          UiText { width: parent.width; text: "Searched the cleaned and the raw text of the last " + screen.app.history.length + " dictations."; muted: true; wrapMode: Text.Wrap }
          Pill { kind: "outline"; text: "Clear search"; size: 13; onClicked: search.text = "" }
        }
      }
    }

    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.divider }

    // ---------------------------------------------------------- one take
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      UiText {
        anchors.centerIn: parent
        visible: screen.selected === null
        text: "Select a dictation to see what was said and what changed."
        muted: true
      }

      Column {
        id: detail
        visible: screen.selected !== null
        x: 24; y: 20
        width: parent.width - 48
        spacing: 16

        SetupBanner { width: parent.width; app: screen.app; onOpenSettings: function(target) { screen.openSettings(target) } }

        UiText {
          width: parent.width
          wrapMode: Text.Wrap
          font.pixelSize: 12
          muted: true
          text: {
            var entry = screen.selected
            if (!entry) return ""
            var date = new Date(Number(entry.created_at_ms))
            var parts = [Dates.group(entry.created_at_ms, screen.app.nowMs) + " " + Dates.stamp(entry.created_at_ms)]
            var words = String(entry.text || "").split(/\s+/).filter(function(w) { return w }).length
            parts.push(words + (words === 1 ? " word" : " words"))
            parts.push(entry.pasted ? "Pasted" : "Copied, not pasted")
            if (entry.cleanup_model && !entry.cleanup_warning) parts.push("Cleaned by " + entry.cleanup_model)
            return parts.join(". ") + "."
          }
        }

        UiText {
          visible: screen.selected !== null && Boolean(screen.selected.cleanup_warning)
          width: parent.width
          wrapMode: Text.Wrap
          text: screen.selected ? String(screen.selected.cleanup_warning || "") : ""
          color: Theme.yellowText
          font.pixelSize: 12
        }

        // The recording, when dictation audio is kept.
        Rectangle {
          id: player
          visible: screen.selected !== null && screen.selected.audio === true
          readonly property var playback: screen.app.journalPlayback
          readonly property bool playing: playback !== null && playback.date === ""
            && screen.selected !== null && Number(playback.id) === Number(screen.selected.id)
          readonly property real duration: playing ? Number(playback.duration_ms) : 0
          readonly property real position: playing
            ? Math.min(duration, Number(playback.offset_ms) + Math.max(0, screen.app.nowMs - Number(playback.started_at_ms))) : 0
          width: parent.width
          height: 40
          radius: height / 2
          color: Theme.fill4

          Rectangle {
            id: playButton
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 26; height: 26; radius: 13
            color: player.playing ? Theme.accent : playMouse.containsMouse ? Theme.fill22 : Theme.fill18
            activeFocusOnTab: true
            border.width: activeFocus ? 2 : 0
            border.color: Theme.accent
            Icon {
              anchors.centerIn: parent
              anchors.horizontalCenterOffset: player.playing ? 0 : 1
              name: player.playing ? "pause" : "play"
              size: 10
              color: player.playing ? Theme.onAccent : Theme.text
            }
            MouseArea {
              id: playMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: player.playing ? screen.app.journalStopPlayback() : screen.app.historyPlay(screen.selected.id, 0)
            }
            Keys.onSpacePressed: player.playing ? screen.app.journalStopPlayback() : screen.app.historyPlay(screen.selected.id, 0)
            Accessible.role: Accessible.Button
            Accessible.name: player.playing ? "Stop the recording" : "Play the recording"
          }
          Rectangle {
            anchors.left: playButton.right
            anchors.leftMargin: 12
            anchors.right: time.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            height: 4
            radius: 2
            color: Theme.fill18
            Rectangle {
              width: player.duration > 0 ? parent.width * player.position / player.duration : 0
              height: parent.height
              radius: 2
              color: Theme.accent
            }
          }
          UiText {
            id: time
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: player.playing ? Dates.clock(player.position) + " / " + Dates.clock(player.duration) : "Recording"
            muted: true
            font.pixelSize: 12
            font.features: player.playing ? { "tnum": 1 } : {}
          }
        }

        Segmented {
          visible: screen.hasRaw
          size: 12
          horizontalPadding: 10
          options: [{ value: "cleaned", label: "Cleaned" }, { value: "raw", label: "Raw" }, { value: "changes", label: "Changes" }]
          current: screen.view
          onPicked: function(value) { screen.view = value }
        }

        Controls.TextArea {
          id: editor
          visible: screen.view === "cleaned"
          width: parent.width
          // Loaded by the screen, not bound: a binding would be rewritten under
          // your cursor every time the daemon republishes its state.
          property string loadedId: ""
          property string loadedText: ""
          property bool dirty: screen.selected !== null && loadedId === String(screen.selected.id) && text !== loadedText
          color: Theme.text
          font.family: Theme.sans
          font.pixelSize: 15
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          selectionColor: Theme.alpha(Theme.accent, 0.4)
          leftPadding: 0; rightPadding: 0; topPadding: 2; bottomPadding: 2
          background: Rectangle {
            anchors.fill: parent
            anchors.margins: -8
            radius: Theme.radiusInput
            color: editor.activeFocus ? Theme.fill4 : "transparent"
            border.width: editor.activeFocus ? 1 : 0
            border.color: Theme.outline
          }
          Keys.onEscapePressed: { text = loadedText; screen.focusKeys() }
          Accessible.name: "Dictation text, editable"
        }

        UiText {
          visible: screen.view === "raw"
          width: parent.width
          text: screen.selected ? String(screen.selected.raw_text || "") : ""
          font.pixelSize: 15
          lineHeight: 24
          wrapMode: Text.Wrap
        }

        Text {
          visible: screen.view === "changes" && screen.rawDiffers
          width: parent.width
          textFormat: Text.RichText
          text: screen.selected ? Diff.html(screen.selected.raw_text, screen.selected.text, { removed: Theme.redText, added: Theme.greenText }) : ""
          color: Theme.text
          font.family: Theme.sans
          font.pixelSize: 15
          lineHeightMode: Text.FixedHeight
          lineHeight: 24
          wrapMode: Text.Wrap
        }

        UiText {
          visible: screen.view === "changes" && screen.rawDiffers
          text: "Struck through was said and removed. Underlined was added by cleanup."
          muted: true
          font.pixelSize: 12
        }

        UiText {
          visible: screen.view === "changes" && !screen.rawDiffers
          width: parent.width
          text: "Cleanup changed nothing. The text is exactly what was said."
          muted: true
          font.pixelSize: 15
          wrapMode: Text.Wrap
        }

        Rectangle { width: parent.width; height: 1; color: Theme.divider }

        Flow {
          width: parent.width
          spacing: 6
          Pill {
            visible: editor.dirty
            kind: "primary"; text: "Save changes"
            onClicked: { screen.app.editHistory(screen.selected.id, editor.text); screen.focusKeys() }
          }
          Pill {
            visible: !editor.dirty && screen.app.pasteMode !== "clipboard"
            kind: "primary"; text: "Paste again"; shortcut: "Enter"
            onClicked: screen.app.pasteHistory(screen.selected.id)
          }
          Pill { kind: "fill"; text: "Copy"; onClicked: screen.app.copyHistory(screen.selected.id) }
          Pill { visible: screen.rawDiffers; kind: "fill"; text: "Copy raw"; onClicked: screen.app.copyRawHistory(screen.selected.id) }
          Pill {
            visible: screen.rawDiffers && screen.view === "raw"
            kind: "fill"; text: "Keep the raw text"
            hint: "Replace the cleaned text with what was said"
            onClicked: screen.app.editHistory(screen.selected.id, screen.selected.raw_text)
          }
          Pill { kind: "fill"; text: "Delete"; onClicked: screen.app.deleteHistory(screen.selected.id) }
        }
      }

      Toast {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        message: screen.toast
        error: screen.app.feedbackError
        actionText: screen.app.canUndoDelete && !screen.app.feedbackError ? "Undo" : ""
        onAction: { screen.app.undoDelete(); screen.toast = "" }
      }
    }
  }
}
