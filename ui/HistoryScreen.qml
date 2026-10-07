import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import "Dates.js" as Dates
import "Diff.js" as Diff

// Every dictation you kept, newest first, and what cleanup did to it. The
// list is for finding; the page on the right is for getting the words back
// out: paste again, copy, or fix a word and save it. A dictation the speech
// model failed waits here with its recording until it is transcribed again.
FocusScope {
  id: screen

  required property var app
  signal openSettings(string target)
  // A message for the window's toast, for what the window does by itself.
  signal flash(string message)
  // Ctrl+Z in a search with nothing of its own to undo: the window's Undo.
  signal undoRequested()

  property string query: ""
  property string selectedId: ""
  property string view: "cleaned"

  readonly property var entries: {
    var needle = query.trim().toLowerCase()
    if (needle.length === 0) return app.history
    return app.history.filter(function(entry) {
      return String(entry.text || "").toLowerCase().indexOf(needle) >= 0
        || String(entry.raw_text || "").toLowerCase().indexOf(needle) >= 0
    })
  }
  // Where the selection was, so deleting a dictation selects the one that
  // moves into its place instead of jumping back to the newest.
  property int anchorIndex: 0
  readonly property int selectedIndex: {
    for (var i = 0; i < entries.length; i++) if (String(entries[i].id) === selectedId) return i
    if (entries.length === 0) return -1
    return query.trim().length > 0 ? 0 : Math.min(anchorIndex, entries.length - 1)
  }
  onSelectedIndexChanged: if (selectedIndex >= 0 && String(entries[selectedIndex].id) === selectedId) anchorIndex = selectedIndex
  Connections {
    target: screen.app
    function onHistoryChanged() { Qt.callLater(screen.followDeleted) }
  }
  function followDeleted() {
    var gone = selectedId.length > 0 && !app.history.some(function(entry) { return String(entry.id) === selectedId })
    if (gone && selectedIndex >= 0) selectedId = String(entries[selectedIndex].id)
  }
  readonly property var selected: selectedIndex >= 0 ? entries[selectedIndex] : null
  // Not transcribed: no words yet, only the recording and why it failed.
  function waiting(entry) { return entry !== null && entry.status !== undefined && entry.status.state === "not_transcribed" }
  function reason(entry) {
    return entry.audio === true ? String(entry.status.reason || "The speech model did not transcribe it.")
      : "The recording was deleted, so this dictation cannot be transcribed."
  }
  // Copied but not pasted. With Paste set to Clipboard only that is every
  // dictation, so it is not worth a word.
  function copiedOnly(entry) { return !entry.pasted && app.pasteMode !== "clipboard" }
  readonly property bool selectedWaiting: waiting(selected)
  readonly property bool canTranscribe: selectedWaiting && selected.audio === true
  readonly property bool transcribing: selectedWaiting && app.isTranscribing(selected.id)
  function transcribeAgain() { if (canTranscribe && !transcribing) app.retryHistory(selected.id) }
  // The raw transcript is offered when it differs, or when a cleanup model
  // read it and left it as it was. With cleanup off the two are the same
  // words, so there is nothing to switch between. The actions that only
  // matter when the two differ check rawDiffers.
  readonly property bool hasRaw: selected !== null && Boolean(selected.raw_text)
    && (selected.raw_text !== selected.text || Boolean(selected.cleanup_model) || selected.edited === true)
  readonly property bool rawDiffers: hasRaw && selected.raw_text !== selected.text
  // What the text you get back is called once you changed it by hand.
  readonly property string mainName: selected && selected.edited === true ? "Saved" : "Cleaned"
  // While the setup banner shows, its button is the one primary in view.
  readonly property string mainKind: detailBanner.visible ? "fill" : "primary"

  function select(index) {
    if (index < 0 || index >= entries.length) return
    selectedId = String(entries[index].id)
    anchorIndex = index
    list.positionViewAtIndex(index, ListView.Contain)
  }

  // Copy takes what is on screen: the raw text on Raw, otherwise the
  // cleaned text, with your unsaved edits.
  function copyShown() {
    if (!selected) return
    if (view === "raw") app.copyRawHistory(selected.id)
    else copyCleaned()
  }
  function copyCleaned() {
    if (!selected) return
    if (editor.dirty) { app.copy(editor.text); flash("Copied to clipboard") }
    else app.copyHistory(selected.id)
  }
  function save() {
    if (!editor.dirty) return
    app.editHistory(selected.id, editor.text)
    focusKeys()
  }
  function discard() {
    editor.text = editor.loadedText
    focusKeys()
  }

  onSelectedIdChanged: { view = "cleaned"; detailFlick.contentY = 0 }
  // A different entry, or a saved change to this one, replaces the editor's
  // text; your unsaved typing on the same entry is left alone. Moving to
  // another entry saves that typing to the one it belongs to first, unless
  // that entry was deleted.
  onSelectedChanged: loadEditor()
  function loadEditor() {
    var entry = selected
    var id = entry ? String(entry.id) : ""
    var text = entry ? String(entry.text || "") : ""
    if (id === editor.loadedId && editor.text !== editor.loadedText && editor.text !== text) return
    var left = editor.loadedId
    if (id !== left && editor.text !== editor.loadedText
        && app.history.some(function(kept) { return String(kept.id) === left }))
      app.editHistory(left, editor.text)
    editor.loadedId = id
    editor.loadedText = text
    editor.text = text
  }

  // The page's own keys, with no field focused. Focusing the scope itself
  // would hand focus back to the last field in it.
  Item { id: keyTarget; focus: true }
  function focusKeys() { keyTarget.forceActiveFocus() }

  // What Enter does, from the page or from the search.
  function runMain() {
    if (!selected) return
    // On a dictation not transcribed, Enter does the one thing it offers.
    if (selectedWaiting) transcribeAgain()
    // With Paste set to Clipboard only, Enter copies and the window stays.
    else if (app.pasteMode === "clipboard") copyCleaned()
    else app.pasteHistory(selected.id)
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) { screen.save(); event.accepted = true; return }
    if (event.key === Qt.Key_Escape && editor.dirty) { screen.discard(); event.accepted = true; return }
    if (event.text === "/" && !search.input.activeFocus) { search.input.forceActiveFocus(); event.accepted = true; return }
    if (editor.activeFocus) return
    if (event.key === Qt.Key_Down || event.text === "j") { screen.select(screen.selectedIndex + 1); event.accepted = true }
    else if (event.key === Qt.Key_Up || event.text === "k") { screen.select(screen.selectedIndex - 1); event.accepted = true }
    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && screen.selected) { screen.runMain(); event.accepted = true }
    else if (event.key === Qt.Key_Delete && screen.selected) { screen.app.deleteHistory(screen.selected.id); event.accepted = true }
    else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier) && screen.selected && !screen.selectedWaiting) { screen.copyShown(); event.accepted = true }
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

      SetupBanner { id: emptyBanner; width: Math.min(640, screen.width - 240); app: screen.app; onOpenSettings: function(target) { screen.openSettings(target) } }

      EmptyState {
        visible: screen.app.historyLimit === 0
        width: parent.width
        title: "History is off"
        body: "Dictations still work but are not kept here."
        footnote: "Turning it on keeps the last 30 dictations on this computer."
        Pill { kind: emptyBanner.visible ? "fill" : "primary"; text: "Turn on history"; size: 13; verticalPadding: 7; horizontalPadding: 12; onClicked: screen.app.preference("history_limit", 30) }
      }
      EmptyState {
        visible: screen.app.historyLimit !== 0
        width: parent.width
        title: "No dictations yet"
        body: !screen.app.binaryFound
          ? "Once OmaFlow is installed and has a speech model, hold " + screen.app.hotkeyLabel + " in any app and start talking. Each dictation is saved here."
          : !screen.app.connected
          ? "Once OmaFlow is running, hold " + screen.app.hotkeyLabel + " in any app and start talking. Start it from the top of the window."
          : screen.app.setupUnfinished
          ? "Once a speech model is ready, hold " + screen.app.hotkeyLabel + " in any app and start talking. Each dictation is saved here."
          : "Hold " + screen.app.hotkeyLabel + " in any app and start talking. Each dictation is saved here, so you can paste it again or fix a word."
        footnote: "The last " + screen.app.historyLimit + " dictations are kept on this computer."
        footnoteLink: "Change this in Privacy"
        onFootnoteClicked: screen.openSettings("privacy")
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
        onUndoPressed: screen.undoRequested()
        onAccepted: { screen.focusKeys(); screen.runMain() }
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
          readonly property bool waiting: screen.waiting(modelData)
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
          color: item.isSelected ? Theme.fill18 : itemMouse.containsMouse ? Theme.hover : "transparent"

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
                text: item.waiting ? "Not transcribed"
                  : item.modelData.cleanup_warning ? "Cleanup skipped" : screen.copiedOnly(item.modelData) ? "Copied only" : ""
                color: item.waiting || item.modelData.cleanup_warning ? Theme.yellowText : Theme.secondary
                font.pixelSize: 12
              }
            }
            UiText {
              width: parent.width
              text: item.waiting ? screen.reason(item.modelData) : String(item.modelData.text || "")
              muted: item.waiting
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
              lineHeight: 17
            }
          }
          MouseArea { id: itemMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { screen.select(item.index); screen.focusKeys() } }
          }
          Accessible.role: Accessible.ListItem
          // "18:02, copied only: Thanks, I'll have the numbers…"
          Accessible.name: {
            var entry = item.modelData
            if (item.waiting) return Dates.stamp(entry.created_at_ms, screen.app.nowMs) + ", not transcribed: " + screen.reason(entry)
            var note = entry.cleanup_warning ? ", cleanup skipped" : screen.copiedOnly(entry) ? ", copied only" : ""
            var words = String(entry.text || "")
            return Dates.stamp(entry.created_at_ms, screen.app.nowMs) + note + ": "
              + (words.length > 60 ? words.slice(0, 60).trim() + "…" : words)
          }
          Accessible.selected: isSelected
        }

        Column {
          visible: screen.entries.length === 0 && screen.query.length > 0
          x: 10; y: 22
          width: parent.width - 20
          spacing: 10
          UiText { text: "Nothing matches “" + screen.query.trim() + "”"; font.pixelSize: 14; weight: Font.Bold; width: parent.width; elide: Text.ElideRight }
          UiText {
            width: parent.width
            text: screen.app.history.length === 1 ? "Searched the cleaned and the raw text of your one dictation."
              : "Searched the cleaned and the raw text of the last " + screen.app.history.length + " dictations."
            muted: true
            wrapMode: Text.Wrap
          }
          Pill { kind: "outline"; text: "Clear search"; size: 13; onClicked: search.text = "" }
        }
      }
    }

    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.divider }

    // ---------------------------------------------------------- one take
    // A long dictation scrolls, with its actions under it.
    Flickable {
      id: detailFlick
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentWidth: width
      contentHeight: detail.visible ? detail.height + 40 : 0
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Controls.ScrollBar.vertical: Controls.ScrollBar {
        id: detailBar
        policy: detailFlick.contentHeight > detailFlick.height ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
        contentItem: Rectangle { implicitWidth: 4; radius: 2; color: detailBar.pressed || detailBar.hovered ? Theme.secondary : Theme.outline }
        background: null
      }
      // Typing past the bottom keeps the cursor in view.
      function reveal(item, top, bottom) {
        var y = item.mapToItem(contentItem, 0, top).y
        var end = item.mapToItem(contentItem, 0, bottom).y
        if (y - 12 < contentY) contentY = Math.max(0, y - 12)
        else if (end + 12 > contentY + height) contentY = Math.min(contentHeight - height, end + 12 - height)
      }

      // A search with no match leaves this side empty; the list says why.
      Column {
        id: detail
        visible: screen.selected !== null
        x: 24; y: 20
        width: detailFlick.width - 48
        spacing: 16

        SetupBanner { id: detailBanner; width: parent.width; app: screen.app; onOpenSettings: function(target) { screen.openSettings(target) } }

        UiText {
          width: parent.width
          wrapMode: Text.Wrap
          font.pixelSize: 12
          muted: true
          text: {
            var entry = screen.selected
            if (!entry) return ""
            var parts = [Dates.group(entry.created_at_ms, screen.app.nowMs) + " " + Dates.stamp(entry.created_at_ms)]
            if (screen.selectedWaiting) return parts[0] + ". Not transcribed."
            var words = String(entry.text || "").split(/\s+/).filter(function(w) { return w }).length
            parts.push(words + (words === 1 ? " word" : " words"))
            parts.push(entry.pasted ? "Pasted" : screen.copiedOnly(entry) ? "Copied only" : "Copied")
            if (entry.cleanup_model && !entry.cleanup_warning) parts.push("Cleaned by " + screen.app.cleanupModelName(entry.cleanup_model))
            // Keep the raw text is saved as an edit whose words are the raw text.
            if (entry.edited === true) parts.push(entry.raw_text && entry.text === entry.raw_text ? "Raw text kept" : "Edited by you")
            return parts.join(". ") + "."
          }
        }

        // Why it has no words yet, as large as the words would be.
        UiText {
          visible: screen.selectedWaiting
          width: parent.width
          wrapMode: Text.Wrap
          text: screen.selectedWaiting ? screen.reason(screen.selected) : ""
          font.pixelSize: 15
          lineHeight: 24
        }

        // Why cleanup was skipped, and the way to where it is set up.
        Column {
          visible: screen.selected !== null && Boolean(screen.selected.cleanup_warning)
          width: parent.width
          spacing: 4
          UiText {
            width: parent.width
            wrapMode: Text.Wrap
            // The link under it is the way to Settings, so the warning does
            // not name the page again.
            text: screen.selected ? String(screen.selected.cleanup_warning || "").replace(/ Check Settings, Cleanup\.$/, "") : ""
            color: Theme.yellowText
            font.pixelSize: 12
          }
          Pill {
            kind: "link"; text: "Open Cleanup settings"; size: 12
            horizontalPadding: 0; verticalPadding: 2
            onClicked: screen.openSettings("cleanup")
          }
        }

        // The recording, when dictation audio is kept.
        Rectangle {
          id: player
          visible: screen.selected !== null && screen.selected.audio === true
          readonly property var playback: screen.app.journalPlayback
          readonly property bool playing: playback !== null && playback.date === ""
            && screen.selected !== null && Number(playback.id) === Number(screen.selected.id)
          // Pause keeps the place and the length, so Play goes on from there.
          property real pausedAt: 0
          property real knownDuration: 0
          readonly property real duration: playing ? Number(playback.duration_ms) : knownDuration
          readonly property real position: playing
            ? Math.min(duration, Number(playback.offset_ms) + Math.max(0, screen.app.nowMs - Number(playback.started_at_ms))) : pausedAt
          readonly property bool paused: !playing && pausedAt > 0
          function toggle() {
            if (playing) {
              knownDuration = duration
              pausedAt = position >= duration - 150 ? 0 : position
              screen.app.journalStopPlayback()
            } else screen.app.historyPlay(screen.selected.id, pausedAt)
          }
          onPlayingChanged: if (playing) pausedAt = 0
          Connections {
            target: screen
            function onSelectedIdChanged() { player.pausedAt = 0; player.knownDuration = 0 }
          }
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
            // The focus ring sits outside, as on every button.
            Rectangle {
              anchors.fill: parent
              anchors.margins: -3
              radius: height / 2
              color: "transparent"
              border.width: 2
              border.color: Theme.accent
              visible: playButton.activeFocus
            }
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
              onClicked: player.toggle()
            }
            Keys.onSpacePressed: player.toggle()
            Keys.onReturnPressed: player.toggle()
            Accessible.role: Accessible.Button
            Accessible.name: player.playing ? "Pause recording" : player.paused ? "Resume recording" : "Play recording"
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
              width: player.duration > 0 ? parent.width * Math.min(1, player.position / player.duration) : 0
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
            text: player.playing || player.paused ? Dates.clock(player.position) + " / " + Dates.clock(player.duration) : "Play recording"
            muted: true
            font.pixelSize: 12
            font.features: player.playing || player.paused ? { "tnum": 1 } : {}
            // "Play recording" reads as the action, so it is one.
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: player.toggle() }
          }
        }

        Segmented {
          name: "Which text to show"
          visible: screen.hasRaw
          size: 12
          horizontalPadding: 10
          options: [{ value: "cleaned", label: screen.mainName }, { value: "raw", label: "Raw" }, { value: "changes", label: "Changes" }]
          current: screen.view
          onPicked: function(value) { screen.view = value }
        }

        Controls.TextArea {
          id: editor
          visible: screen.view === "cleaned" && !screen.selectedWaiting
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
          Keys.onEscapePressed: screen.discard()
          // Tab moves on to the actions; a dictation has no use for tabs.
          Keys.onTabPressed: function(event) { nextItemInFocusChain(true).forceActiveFocus(); event.accepted = true }
          // Hidden by Raw or Changes, it hands the keys back to the page.
          onVisibleChanged: if (!visible && activeFocus) screen.focusKeys()
          onCursorRectangleChanged: if (activeFocus) detailFlick.reveal(editor, cursorRectangle.y, cursorRectangle.y + cursorRectangle.height)
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

        // After a change by hand the differences are not all cleanup's.
        UiText {
          visible: screen.view === "changes" && screen.rawDiffers
          width: parent.width
          wrapMode: Text.Wrap
          text: screen.selected && screen.selected.edited === true
            ? "Underlined is new. Struck through was removed."
            : screen.selected && screen.selected.cleanup_model
            ? "Struck through was said and removed. Underlined was added by cleanup."
            : "Struck through was said and removed. Underlined was added."
          muted: true
          font.pixelSize: 12
        }

        UiText {
          visible: screen.view === "changes" && !screen.rawDiffers
          width: parent.width
          text: screen.selected && screen.selected.edited === true ? "You kept the raw text."
            : screen.selected && screen.selected.cleanup_model ? "Cleanup changed nothing. The text is exactly what was said."
            : "The text is exactly what was said."
          muted: true
          font.pixelSize: 15
          wrapMode: Text.Wrap
        }

        Rectangle { width: parent.width; height: 1; color: Theme.divider }

        // Not transcribed: transcribe it again, or let it go.
        Column {
          visible: screen.selectedWaiting
          width: parent.width
          spacing: 6
          Row {
            spacing: 6
            Pill {
              visible: screen.canTranscribe
              enabled: !screen.transcribing
              kind: screen.mainKind; text: "Transcribe again"; shortcut: "Enter"
              onClicked: screen.transcribeAgain()
            }
            Pill { kind: "fill"; text: "Delete"; onClicked: screen.app.deleteHistory(screen.selected.id) }
            UiText {
              visible: screen.transcribing
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: 4
              text: "Transcribing…"
              muted: true
            }
          }
          UiText {
            visible: screen.canTranscribe
            width: parent.width
            wrapMode: Text.Wrap
            text: "The words show up here. Nothing is pasted."
            muted: true
            font.pixelSize: 12
          }
        }

        Flow {
          visible: !screen.selectedWaiting
          width: parent.width
          spacing: 6
          Pill {
            visible: editor.dirty
            kind: screen.mainKind; text: "Save changes"; shortcut: "Ctrl+S"
            onClicked: screen.save()
          }
          Pill {
            visible: editor.dirty
            kind: "fill"; text: "Discard"; shortcut: "Esc"
            hint: "Puts back the saved text"
            onClicked: screen.discard()
          }
          // Away from the cleaned text, the button says which text it pastes.
          Pill {
            visible: !editor.dirty && screen.app.pasteMode !== "clipboard"
            kind: screen.mainKind; text: screen.rawDiffers && screen.view !== "cleaned" ? "Paste " + screen.mainName.toLowerCase() : "Paste again"; shortcut: "Enter"
            onClicked: screen.app.pasteHistory(screen.selected.id)
          }
          // Named for what it copies when there are two texts to choose from.
          Pill {
            readonly property bool main: !editor.dirty && screen.app.pasteMode === "clipboard"
            kind: main ? screen.mainKind : "fill"
            text: screen.rawDiffers ? "Copy " + screen.mainName.toLowerCase() : "Copy"
            shortcut: main ? "Enter" : ""
            onClicked: screen.copyCleaned()
          }
          Pill { visible: screen.rawDiffers; kind: "fill"; text: "Copy raw"; onClicked: screen.app.copyRawHistory(screen.selected.id) }
          Pill { kind: "fill"; text: "Delete"; onClicked: screen.app.deleteHistory(screen.selected.id) }
        }

        // On Raw, the one action that changes the saved text, with what it does
        // right under it.
        Column {
          // Not beside unsaved typing, which the next save would put back
          // over the raw text you kept.
          visible: screen.rawDiffers && screen.view === "raw" && !editor.dirty
          width: parent.width
          spacing: 6
          Pill {
            kind: "fill"; text: "Keep the raw text"
            hint: "Replaces the cleaned text. You can undo it right after."
            onClicked: screen.app.editHistory(screen.selected.id, screen.selected.raw_text)
          }
          UiText {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Replaces the cleaned text. You can undo it right after."
            muted: true
            font.pixelSize: 12
          }
        }
      }
    }
  }
}
