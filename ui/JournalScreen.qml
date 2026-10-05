import QtQuick
import QtQuick.Layouts
import "Dates.js" as Dates

// The journal: a calendar on the left, one day on the right, and a place at
// the bottom of today to talk or type. It reads the day's Markdown file through
// the app, so an entry edited in any editor shows up here as written.
FocusScope {
  id: screen

  required property var app
  property bool active: false

  property string today: app.todayIso()
  property string date: today
  property string month: date.slice(0, 7)
  property var day: null
  property var counts: ({})
  property var yearAgo: null
  property int totalDays: -1
  property string loadError: ""

  property string query: ""
  property var results: null
  property int resultIndex: 0

  property string editingId: ""
  property int cursor: -1
  property string toast: ""
  property bool toastError: false
  // The entry just deleted, still shown in its place until it can no longer
  // come back: { date, id, index, entry }, or null.
  property var pendingDelete: null
  // The day's entries, with the deleted one kept in its slot while it can be undone.
  readonly property var listed: {
    var list = day ? day.entries.slice() : []
    var gone = pendingDelete
    if (gone && gone.date === date) {
      list = list.filter(function(entry) { return Number(entry.id) !== Number(gone.id) })
      list.splice(Math.min(gone.index, list.length), 0, { deleted: true, id: gone.id, entry: gone.entry })
    }
    return list
  }

  readonly property bool searching: query.trim().length > 0
  readonly property bool isToday: date === today
  // A later day holds notes written ahead to it, sealed until it comes.
  readonly property bool isFuture: date > today
  readonly property bool firstTime: totalDays === 0 && !(day && day.entries.length > 0)
    && !(app.journalTake && ["recording", "processing"].indexOf(app.phase) >= 0)
  readonly property var questions: [
    "What surprised you today?",
    "What would you like to remember about today?",
    "What went better than you expected?",
    "Who did you talk to today, and what stayed with you?",
    "What took more energy than it should have?",
    "What made you laugh?",
    "What are you looking forward to?"
  ]
  readonly property string question: questions[Math.floor(Dates.parse(today).getTime() / 86400000) % questions.length]

  function reload() {
    today = app.todayIso()
    app.query(["journal", "day", date], function(value, error) {
      if (value) { day = value; loadError = "" } else loadError = error
    })
    loadMonth()
    app.query(["journal", "year-ago", date], function(value) { yearAgo = value })
    app.query(["journal", "stats"], function(value) { totalDays = value ? Number(value.days) : 0 })
  }
  function loadMonth() {
    app.query(["journal", "month", month], function(value) {
      var next = {}
      if (value && Array.isArray(value.days))
        value.days.forEach(function(d) { next[d.date] = d.entries })
      counts = next
    })
  }
  function openDay(iso) {
    date = iso
    month = iso.slice(0, 7)
    editingId = ""
    cursor = -1
    reload()
  }
  function runSearch() {
    if (!searching) { results = null; return }
    app.query(["journal", "search", query.trim()], function(value) {
      results = value
      resultIndex = 0
    })
  }
  function openResult(index) {
    if (!results || index < 0 || index >= results.hits.length) return
    var hit = results.hits[index]
    search.text = ""
    openDay(hit.date)
  }
  function flash(message, error) {
    toast = message
    toastError = Boolean(error)
    toastTimer.restart()
  }
  // One click deletes. The entry stays in its place, greyed out, with Undo
  // for ten seconds instead of a question first; then it is gone for good.
  function deleteEntry(date, entry, index) {
    editingId = ""
    pendingDelete = { date: date, id: entry.id, index: index, entry: entry }
    deleteTimer.restart()
    app.query(["journal", "delete", date, entry.id], function(value, error) {
      if (error) { pendingDelete = null; deleteTimer.stop(); flash(error, true) }
      reload()
    })
  }
  function undoDelete() {
    var entry = pendingDelete
    if (!entry) return
    pendingDelete = null
    deleteTimer.stop()
    app.query(["journal", "restore", entry.date, entry.id], function(value, error) { afterWrite(value, error, "") })
  }
  function afterWrite(value, error, message) {
    if (error) flash(error, true)
    else if (message) flash(message, false)
    reload()
  }

  onActiveChanged: if (active) reload()
  onQueryChanged: searchTimer.restart()
  Component.onCompleted: if (active) reload()

  Connections {
    target: screen.app
    // A new entry landed in today's file. Refresh today, but never pull you
    // off another day or reload under an edit you are making.
    function onJournalRevisionChanged() {
      if (!screen.active) return
      if (screen.date === screen.today && screen.editingId === "") screen.reload()
      else { screen.loadMonth(); screen.app.query(["journal", "stats"], function(value) { screen.totalDays = value ? Number(value.days) : screen.totalDays }) }
    }
  }
  Timer { id: searchTimer; interval: 160; onTriggered: screen.runSearch() }
  Timer { id: toastTimer; interval: 3200; onTriggered: screen.toast = "" }
  // Ten seconds, and the fold under the row: then the entry is deleted for good.
  Timer {
    id: deleteTimer
    interval: 10250
    onTriggered: {
      screen.pendingDelete = null
      screen.app.spawn(["omaflow", "journal", "forget-deleted"])
    }
  }

  // The page's own keys, with no field focused. Focusing the scope itself
  // would hand focus back to the last field in it.
  Item { id: keyTarget; focus: true }
  function focusKeys() { keyTarget.forceActiveFocus() }

  Keys.onPressed: function(event) {
    if (screen.pendingDelete && event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) {
      screen.undoDelete()
      event.accepted = true
    } else if (event.text === "/" && !search.input.activeFocus) {
      search.input.forceActiveFocus()
      event.accepted = true
    } else if (screen.searching && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
      var count = screen.results ? screen.results.hits.length : 0
      screen.resultIndex = Math.max(0, Math.min(count - 1, screen.resultIndex + (event.key === Qt.Key_Down ? 1 : -1)))
      event.accepted = true
    } else if (screen.searching && event.key === Qt.Key_Return) {
      screen.openResult(screen.resultIndex)
      event.accepted = true
    } else if (!screen.searching && screen.day && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
      screen.cursor = Math.max(0, Math.min(screen.day.entries.length - 1, screen.cursor + (event.key === Qt.Key_Down ? 1 : -1)))
      entries.positionViewAtIndex(screen.cursor, ListView.Contain)
      event.accepted = true
    }
  }

  RowLayout {
    anchors.fill: parent
    spacing: 0

    // ---------------------------------------------------------------- rail
    // A first visit has nothing to look back on, so the page takes the width.
    Item {
      visible: !screen.firstTime || screen.searching
      Layout.preferredWidth: 252
      Layout.fillHeight: true

      SearchField {
        id: search
        x: 16; y: 16
        width: parent.width - 32
        placeholder: "Search your journal"
        onTextChanged: screen.query = text
        onEscaped: screen.focusKeys()
        onDown: screen.resultIndex = Math.min((screen.results ? screen.results.hits.length : 1) - 1, screen.resultIndex + 1)
        onUp: screen.resultIndex = Math.max(0, screen.resultIndex - 1)
        onAccepted: screen.openResult(screen.resultIndex)
      }

      JournalCalendar {
        anchors.top: search.bottom
        anchors.topMargin: 22
        x: 16
        width: parent.width - 32
        month: screen.month
        selected: screen.searching ? "" : screen.date
        today: screen.today
        counts: screen.counts
        highlighted: screen.searching && screen.results ? screen.results.days : []
        onPicked: function(date) { search.text = ""; screen.openDay(date) }
        onMonthShifted: function(delta) { screen.month = Dates.shiftMonth(screen.month, delta); screen.loadMonth() }
      }

      Rectangle {
        visible: screen.yearAgo !== null
        x: 16
        width: parent.width - 32
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        height: yearAgoText.implicitHeight + 30
        radius: 14
        color: yearMouse.containsMouse ? Theme.fill8 : Theme.fill4

        Column {
          id: yearAgoText
          x: 14; y: 14
          width: parent.width - 28
          spacing: 8
          Column {
            spacing: 1
            UiText { text: "A year ago today"; font.pixelSize: 12; weight: Font.DemiBold }
            UiText { text: screen.yearAgo ? Dates.full(screen.yearAgo.date) : ""; muted: true; font.pixelSize: 12 }
          }
          BookText {
            width: parent.width
            text: screen.yearAgo ? screen.yearAgo.entry.text : ""
            color: Theme.text
            font.family: Theme.book
            font.italic: true
            size: 15
            lineHeightMode: Text.FixedHeight
            lineHeight: 21
            wrapMode: Text.Wrap
            maximumLineCount: 4
            elide: Text.ElideRight
          }
        }
        MouseArea {
          id: yearMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (screen.yearAgo) screen.openDay(screen.yearAgo.date)
        }
        Accessible.role: Accessible.Button
        Accessible.name: "A year ago today: " + (screen.yearAgo ? screen.yearAgo.entry.text : "")
      }
    }

    Rectangle { visible: !screen.firstTime || screen.searching; Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.divider }

    // ---------------------------------------------------------------- page
    Item {
      id: page
      Layout.fillWidth: true
      Layout.fillHeight: true

      // First time: what the journal is, where it keeps things, one way in.
      Item {
        anchors.fill: parent
        visible: screen.firstTime && !screen.searching

        Column {
          width: Math.min(parent.width - 96, 580)
          anchors.centerIn: parent
          anchors.verticalCenterOffset: -30
          spacing: 0

          Row {
            spacing: 14
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 5
              Repeater {
                model: [20, 38, 56, 30]
                Rectangle { required property int modelData; anchors.verticalCenter: parent.verticalCenter; width: 6; height: modelData; radius: 3; color: Theme.accent }
              }
            }
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 5
              Rectangle { width: 4; height: 4; radius: 2; color: Theme.outline; anchors.verticalCenter: parent.verticalCenter }
              Rectangle { width: 4; height: 4; radius: 2; color: Theme.outline; anchors.verticalCenter: parent.verticalCenter }
            }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 7
              Repeater {
                model: [92, 80, 88, 52]
                Rectangle { required property int modelData; required property int index; width: modelData; height: 5; radius: 2.5; color: index < 2 ? Theme.text : Theme.outline }
              }
            }
          }

          Item { width: 1; height: 30 }
          BookText {
            text: "A journal you can talk to"
            color: Theme.text
            font.family: Theme.book
            size: 40
            weight: Font.Medium
            font.letterSpacing: -0.6
          }
          Item { width: 1; height: 18 }
          UiText {
            width: parent.width
            text: (screen.app.journalShortcut
                ? "Press " + screen.app.journalShortcut + " anywhere, say what's on your mind, and press it again. "
                : "Press Talk my first entry, say what's on your mind, and press Save. ")
              + "OmaFlow writes it down" + (screen.app.journalSettings.keep_recordings === false ? ". " : " and keeps the recording. ")
              + "It's for you, not for pasting into another app, and nothing leaves this machine."
              + (screen.app.journalShortcut ? "" : " Add a shortcut to start entries from any app.")
            muted: true
            font.pixelSize: 15
            wrapMode: Text.Wrap
            lineHeightMode: Text.FixedHeight
            lineHeight: 23
          }
          Item { width: 1; height: 28 }
          Rectangle {
            width: parent.width
            height: 62
            radius: Theme.radiusCard
            color: Theme.fill4
            Column {
              anchors.left: parent.left
              anchors.leftMargin: 18
              anchors.verticalCenter: parent.verticalCenter
              spacing: 3
              UiText { text: "Entries are saved as Markdown, one file per day, in"; muted: true; font.pixelSize: 12; weight: Font.DemiBold }
              UiText { text: String(screen.app.journalSettings.folder || ""); font.family: Theme.mono; font.pixelSize: 12 }
            }
            Pill { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; kind: "outline"; text: "Change"; size: 13; onClicked: settingsSheet.open = true }
          }
          Item { width: 1; height: 18 }
          Row {
            spacing: 12
            Pill {
              kind: "primary"
              text: "Talk my first entry"
              size: 14
              horizontalPadding: 18
              verticalPadding: 9
              leading: Component { Icon { name: "mic"; size: 15; color: Theme.onAccent } }
              enabled: screen.app.connected
              onClicked: screen.app.journalToggle()
            }
            Pill {
              anchors.verticalCenter: parent.verticalCenter
              kind: "fill"
              text: "Type instead"
              size: 14
              horizontalPadding: 16
              verticalPadding: 9
              onClicked: { screen.totalDays = 1; Qt.callLater(composer.focusInput) }
            }
            Pill {
              anchors.verticalCenter: parent.verticalCenter
              visible: !screen.app.journalShortcut
              kind: "link"
              text: "Add a shortcut"
              size: 14
              onClicked: screen.app.showWindow("settings/hotkeys")
            }
          }
        }
      }

      // One day.
      Item {
        anchors.fill: parent
        anchors.leftMargin: 22
        anchors.rightMargin: 20
        anchors.topMargin: 26
        anchors.bottomMargin: 20
        visible: !screen.firstTime && !screen.searching

        Item {
          id: titleRow
          anchors.left: parent.left
          anchors.right: parent.right
          height: 64
          // The title ends before the file and menu buttons; a long day name
          // gets a little smaller rather than running under them.
          BookText {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: titleActions.left
            anchors.rightMargin: 16
            anchors.top: parent.top
            height: 46
            wrapMode: Text.NoWrap
            fontSizeMode: Text.HorizontalFit
            minimumPixelSize: 24
            verticalAlignment: Text.AlignVCenter
            text: Dates.long(screen.date, screen.today)
            color: Theme.text
            font.family: Theme.book
            size: 36
            weight: Font.Medium
            font.letterSpacing: -0.54
            Accessible.role: Accessible.Heading
          }
          Row {
            id: titleActions
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.top: parent.top
            anchors.topMargin: 8
            spacing: 8
            Rectangle {
              visible: screen.day !== null && screen.day.exists
              height: 26
              width: fileRow.implicitWidth + 24
              radius: 13
              color: fileMouse.containsMouse ? Theme.fill8 : "transparent"
              border.width: 1
              border.color: Theme.divider
              anchors.verticalCenter: parent.verticalCenter
              Row {
                id: fileRow
                anchors.centerIn: parent
                spacing: 7
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "folder"; size: 13; color: Theme.secondary }
                UiText { anchors.verticalCenter: parent.verticalCenter; text: screen.date + ".md"; font.family: Theme.mono; font.pixelSize: 11; muted: true }
              }
              MouseArea { id: fileMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: screen.app.openInEditor(screen.day.file) }
              Accessible.role: Accessible.Button
              Accessible.name: "Open " + screen.date + ".md in your editor"
            }
            Rectangle {
              id: moreButton
              width: 30; height: 30; radius: 15
              color: moreMouse.containsMouse || menu.open ? Theme.fill8 : "transparent"
              border.width: 1
              border.color: Theme.divider
              Icon { anchors.centerIn: parent; name: "more"; size: 14; color: Theme.text }
              MouseArea { id: moreMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: menu.open = !menu.open }
              Accessible.role: Accessible.Button
              Accessible.name: "Journal options"
            }
          }
        }

        ListView {
          id: entries
          anchors.top: titleRow.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: composer.visible ? composer.top : parent.bottom
          anchors.bottomMargin: composer.visible ? 14 : 0
          clip: true
          spacing: 4
          boundsBehavior: Flickable.StopAtBounds
          model: screen.listed
          delegate: Loader {
            id: slot
            required property var modelData
            required property int index
            width: entries.width
            sourceComponent: modelData.deleted ? deletedRow : entryRow
            Component {
              id: entryRow
              JournalEntry {
                width: slot.width
                entry: slot.modelData
                date: screen.date
                today: screen.today
                playback: screen.app.journalPlayback
                nowMs: screen.app.nowMs
                editing: screen.editingId === String(slot.modelData.id)
                current: screen.cursor === slot.index
                onEditRequested: screen.editingId = String(slot.modelData.id)
                onCancelRequested: screen.editingId = ""
                onSaveRequested: function(text) {
                  screen.editingId = ""
                  screen.app.query(["journal", "edit", screen.date, slot.modelData.id, text], function(value, error) { screen.afterWrite(value, error, "Saved") })
                }
                onDeleteRequested: screen.deleteEntry(screen.date, slot.modelData, slot.index)
                onCopyRequested: { screen.app.copy(spoken && slot.modelData.raw_text ? slot.modelData.raw_text : slot.modelData.text); screen.flash("Copied", false) }
                onPlayRequested: function(offsetMs) { screen.app.journalPlay(screen.date, slot.modelData.id, offsetMs) }
                onStopRequested: screen.app.journalStopPlayback()
              }
            }
            Component {
              id: deletedRow
              JournalDeleted {
                width: slot.width
                entry: slot.modelData.entry
                date: screen.date
                onUndoRequested: screen.undoDelete()
              }
            }
          }
          onCountChanged: if (screen.isToday) Qt.callLater(function() { entries.positionViewAtEnd() })

          // An empty day asks one question, or says plainly that it is empty.
          Column {
            anchors.left: parent.left
            anchors.leftMargin: 72
            anchors.right: parent.right
            y: 18
            spacing: 8
            visible: screen.day !== null && screen.listed.length === 0
            BookText {
              width: parent.width
              text: screen.isToday && screen.app.journalSettings.empty_day_question ? screen.question
                : screen.isFuture ? "A note for yourself on " + Dates.full(screen.date) + "."
                : screen.isToday ? "Nothing yet today."
                : "Nothing was written on this day."
              color: (screen.isToday && screen.app.journalSettings.empty_day_question) || screen.isFuture ? Theme.text : Theme.secondary
              font.family: Theme.book
              font.italic: true
              size: 22
              wrapMode: Text.Wrap
            }
            UiText {
              visible: screen.isToday || screen.isFuture
              width: parent.width
              wrapMode: Text.Wrap
              text: screen.isFuture ? "Talk or type below. It stays sealed until that day, and OmaFlow tells you when it arrives." : "Talk or type below."
              muted: true
            }
          }
        }

        JournalComposer {
          id: composer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          visible: screen.isToday || screen.isFuture || (screen.app.journalTake && ["recording", "processing"].indexOf(screen.app.phase) >= 0)
          app: screen.app
          laterDay: screen.isFuture ? screen.date : ""
          onTyped: function(text) {
            screen.app.query(screen.isFuture ? ["journal", "add", text, screen.date] : ["journal", "add", text], function(value, error) {
              if (!error) composer.clearInput()
              screen.afterWrite(value, error, "")
            })
          }
        }

        Pill {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          visible: !composer.visible
          kind: "outline"
          text: "Back to today"
          size: 13
          onClicked: screen.openDay(screen.app.todayIso())
        }
      }

      // Search: the words across every day, newest first.
      Item {
        anchors.fill: parent
        anchors.leftMargin: 22
        anchors.rightMargin: 20
        anchors.topMargin: 26
        anchors.bottomMargin: 20
        visible: screen.searching

        Column {
          id: searchHead
          x: 16
          spacing: 6
          BookText {
            text: "“" + screen.query.trim() + "”"
            color: Theme.text
            font.family: Theme.book
            size: 36
            weight: Font.Medium
            font.letterSpacing: -0.54
            elide: Text.ElideRight
            width: page.width - 80
          }
          UiText {
            text: !screen.results ? "Searching…"
              : screen.results.hits.length === 0 ? "Not in your journal yet."
              : "Mentioned on " + screen.results.days.length + (screen.results.days.length === 1 ? " day" : " days")
                + (screen.results.truncated ? ", showing the newest 200" : "")
                + ". Up and Down to move, Enter opens the day."
            muted: true
          }
        }

        ListView {
          id: hits
          anchors.top: searchHead.bottom
          anchors.topMargin: 18
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          clip: true
          spacing: 2
          currentIndex: screen.resultIndex
          model: screen.results ? screen.results.hits : []
          onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
          delegate: Rectangle {
            required property var modelData
            required property int index
            width: hits.width
            height: Math.max(dateCol.implicitHeight, snippet.implicitHeight) + 28
            radius: Theme.radiusPanel
            color: index === screen.resultIndex ? Theme.fill4 : hitMouse.containsMouse ? Theme.alpha(Theme.fill4, 0.6) : "transparent"
            Column {
              id: dateCol
              x: 16; y: 16
              width: 92
              spacing: 1
              UiText { text: Dates.short(modelData.date, screen.today); weight: Font.DemiBold }
              UiText { text: modelData.time; muted: true; font.pixelSize: 12 }
            }
            BookText {
              id: snippet
              x: 16 + 92
              y: 12
              width: parent.width - x - 16
              textFormat: Text.StyledText
              text: highlight(modelData.snippet, modelData.matches)
              color: Theme.text
              font.family: Theme.book
              size: 17
              lineHeightMode: Text.FixedHeight
              lineHeight: 27
              wrapMode: Text.Wrap
              function escapeHtml(value) { return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
              function highlight(text, matches) {
                var chars = Array.from(String(text))
                var out = ""
                var at = 0
                var mark = Theme.accentText
                ;(matches || []).forEach(function(m) {
                  out += escapeHtml(chars.slice(at, m[0]).join(""))
                  out += "<font color=\"" + mark + "\"><b>" + escapeHtml(chars.slice(m[0], m[0] + m[1]).join("")) + "</b></font>"
                  at = m[0] + m[1]
                })
                return out + escapeHtml(chars.slice(at).join(""))
              }
            }
            MouseArea { id: hitMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: screen.openResult(index) }
            Accessible.role: Accessible.ListItem
            Accessible.name: Dates.short(modelData.date, screen.today) + " " + modelData.time + ": " + modelData.snippet
          }
        }
      }

      Toast {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 84
        message: screen.toast
        error: screen.toastError
      }
    }
  }

  PopupMenu {
    id: menu
    anchorItem: moreButton
    items: [
      { label: "Journal settings", action: "settings" },
      { label: "Open the folder", action: "folder" },
      { label: "Export as Markdown", action: "export" }
    ]
    onPicked: function(action) {
      if (action === "settings") settingsSheet.open = true
      else if (action === "folder") screen.app.openExternally(screen.app.journalSettings.folder_path || screen.app.journalSettings.folder)
      else screen.exportJournal()
    }
  }

  function exportJournal() {
    app.query(["journal", "export"], function(value, error) {
      if (value) flash("Exported to " + String(value.path).replace(/^.*\//, "") + " in " + String(value.path).replace(/\/[^\/]*$/, "").replace(/^.*\//, ""), false)
      else flash(error, true)
    })
  }

  JournalSettingsSheet {
    id: settingsSheet
    app: screen.app
    onClosed: open = false
    onExportRequested: screen.exportJournal()
  }
}
