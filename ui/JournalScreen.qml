import QtQuick
import QtQuick.Layouts
import "Dates.js" as Dates

// The journal: a calendar on the left, one day on the right, and a place at
// the bottom of the day to talk or type. It reads the day's Markdown file through
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
  property int recordings: -1
  // Why the day or the journal could not be read, or "".
  property string dayError: ""
  property string statsError: ""
  readonly property string loadError: dayError || statsError

  property string query: ""
  property var results: null
  // Why the last search could not run, or "".
  property string searchError: ""
  property int resultIndex: 0
  // A result opened: its day is on the page, and the results wait behind it.
  property bool viewingHit: false
  readonly property bool listingResults: searching && !viewingHit
  // The entry to bring into view once its day has loaded.
  property string focusId: ""

  property string editingId: ""
  // The words of an edit that could not be saved, kept while the day is
  // read again.
  property string editDraft: ""
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
  // A past day can still be written: the entry says when it was added.
  readonly property bool isPast: date < today
  readonly property bool firstTime: totalDays === 0 && loadError === "" && !(day && day.entries.length > 0)
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
  // Where a spoken entry goes, worked out as Settings, Privacy does it.
  function local(value) {
    return /^https?:\/\/(localhost|127(?:\.[0-9]{1,3}){3}|\[::1\])(?::[0-9]+)?(?:\/|$)/i.test(String(value).trim())
  }
  readonly property bool localSpeech: local(app.modelSettings.speech_endpoint || "")
  readonly property bool localCleanup: app.journalSettings.cleanup !== "medium" || !app.cleanupEnabled
    || local(app.modelSettings.cleanup_endpoint || "")
  readonly property string question: questions[Math.floor(Dates.parse(today).getTime() / 86400000) % questions.length]

  function reload() {
    today = app.todayIso()
    app.query(["journal", "day", date], function(value, error) {
      // An unreadable day shows why, never the day before under a new title.
      day = value
      dayError = value ? "" : error || "OmaFlow did not answer"
      if (value && focusId) showEntry(focusId)
      // The entry being edited is gone from the file: its words go to the
      // composer, so they can still be saved.
      if (value && editingId && !value.entries.some(function(entry) { return String(entry.id) === editingId })) {
        if (editDraft) {
          composer.setText(editDraft)
          flash("That entry is no longer in " + date + ".md. Your words are below, to save as a new entry.", true)
        }
        editingId = ""
        editDraft = ""
      }
    })
    loadMonth()
    app.query(["journal", "year-ago", date], function(value) { yearAgo = value })
    loadStats()
  }
  // A journal that cannot be read is not an empty one: the first-visit page
  // only shows once the folder is known to hold no days.
  function loadStats() {
    app.query(["journal", "stats"], function(value, error) {
      totalDays = value ? Number(value.days) : -1
      recordings = value && value.recordings !== undefined ? Number(value.recordings) : -1
      statsError = value ? "" : error || "OmaFlow did not answer"
    })
  }
  function showEntry(id) {
    focusId = ""
    var index = day.entries.findIndex(function(entry) { return String(entry.id) === String(id) })
    if (index < 0) return
    cursor = index
    // After the list has laid out, and after a reload's jump to the end.
    Qt.callLater(function() { entries.positionViewAtIndex(index, ListView.Center) })
  }
  function loadMonth() {
    app.query(["journal", "month", month], function(value) {
      var next = {}
      if (value && Array.isArray(value.days))
        value.days.forEach(function(d) { next[d.date] = d.entries })
      counts = next
    })
  }
  // Opens a day, today when none is given, and leaves any search.
  function openDay(iso) {
    search.text = ""
    query = ""
    showDay(iso || app.todayIso(), "")
  }
  function showDay(iso, entryId) {
    date = iso
    month = iso.slice(0, 7)
    editingId = ""
    cursor = -1
    focusId = entryId ? String(entryId) : ""
    reload()
  }
  function runSearch() {
    if (!searching) { results = null; searchError = ""; return }
    app.query(["journal", "search", query.trim()], function(value, error) {
      results = value
      searchError = value ? "" : error || "OmaFlow did not answer"
      resultIndex = 0
    })
  }
  function openResult(index) {
    if (!results || index < 0 || index >= results.hits.length) return
    var hit = results.hits[index]
    resultIndex = index
    viewingHit = true
    showDay(hit.date, hit.id)
    focusKeys()
  }
  function flash(message, error) {
    toast = message
    toastError = Boolean(error)
    // An error stays long enough to read, and while the pointer is on it.
    toastTimer.interval = error ? 8000 : 3200
    toastTimer.restart()
  }
  // The daemon's reason as a sentence. An entry that changed in the file
  // since the page read it: the page reads it again, so say to try again.
  function writeError(error, date) {
    var text = String(error).trim()
    if (/ is no longer in the file$/.test(text)) return "That entry changed in " + date + ".md. The page is up to date now, so try again."
    text = text.charAt(0).toUpperCase() + text.slice(1)
    return /[.!?]$/.test(text) ? text : text + "."
  }
  // One click deletes. The entry stays in its place, greyed out, with Undo
  // for ten seconds instead of a question first; then it is gone for good.
  function deleteEntry(date, entry, index) {
    editingId = ""
    // Only the last delete can come back: say so when another one ends it.
    var before = pendingDelete
    if (before && !(before.date === date && Number(before.id) === Number(entry.id)))
      flash("The " + (before.entry.written ? "note from " + Dates.full(before.entry.written) : "entry from " + before.entry.time) + " is deleted for good.", false)
    pendingDelete = { date: date, id: entry.id, index: index, entry: entry }
    deleteTimer.restart()
    app.query(["journal", "delete", date, entry.id], function(value, error) {
      if (error) { pendingDelete = null; deleteTimer.stop(); flash(writeError(error, date), true) }
      reload()
    })
  }
  function undoDelete() {
    var entry = pendingDelete
    if (!entry) return
    pendingDelete = null
    deleteTimer.stop()
    // Back on another day, nothing on this page changes: say where it went.
    var elsewhere = entry.date !== date
      ? "The " + (entry.entry.written ? "note from " + Dates.full(entry.entry.written) : "entry from " + entry.entry.time)
        + " is back on " + Dates.long(entry.date, today) + "." : ""
    app.query(["journal", "restore", entry.date, entry.id], function(value, error) { afterWrite(value, error, elsewhere, entry.date) })
  }
  function afterWrite(value, error, message, day) {
    if (error) flash(writeError(error, day || date), true)
    else if (message) flash(message, false)
    reload()
  }

  onActiveChanged: if (active) reload()
  onQueryChanged: { viewingHit = false; searchTimer.restart() }
  Component.onCompleted: if (active) reload()

  Connections {
    target: screen.app
    // A new entry landed in today's file, or in the day on the page. Refresh
    // it, but never pull you off another day or reload under an edit you
    // are making.
    function onJournalRevisionChanged() {
      if (!screen.active) return
      var saved = screen.app.journalSaved
      var here = saved && saved.date === screen.date
      if ((screen.date === screen.today || here) && screen.editingId === "") {
        if (here && !screen.isToday) screen.focusId = String(saved.id)
        screen.reload()
      } else { screen.loadMonth(); screen.loadStats() }
    }
    // Another folder, or the same days moved there: read the page again.
    function onJournalSettingsChanged() { if (screen.active && screen.editingId === "") screen.reload() }
  }
  Timer { id: searchTimer; interval: 160; onTriggered: screen.runSearch() }
  Timer { id: toastTimer; interval: 3200; onTriggered: if (journalToast.held) restart(); else screen.toast = "" }
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
    } else if ((event.modifiers & Qt.AltModifier) && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
      // A day back or ahead, like turning a page.
      screen.openDay(Dates.addDays(screen.date, event.key === Qt.Key_Left ? -1 : 1))
      event.accepted = true
    } else if (screen.viewingHit && event.key === Qt.Key_Escape) {
      screen.viewingHit = false
      event.accepted = true
    } else if (screen.listingResults && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
      var count = screen.results ? screen.results.hits.length : 0
      screen.resultIndex = Math.max(0, Math.min(count - 1, screen.resultIndex + (event.key === Qt.Key_Down ? 1 : -1)))
      event.accepted = true
    } else if (screen.listingResults && event.key === Qt.Key_Return) {
      screen.openResult(screen.resultIndex)
      event.accepted = true
    } else if (!screen.listingResults && screen.day && screen.day.entries.length > 0 && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
      screen.cursor = Math.max(0, Math.min(screen.day.entries.length - 1, screen.cursor + (event.key === Qt.Key_Down ? 1 : -1)))
      entries.positionViewAtIndex(screen.cursor, ListView.Contain)
      event.accepted = true
    } else if (!screen.listingResults && screen.cursor >= 0) {
      // The entry under the cursor, as its buttons would: Enter edits,
      // Delete deletes, Space plays or pauses.
      var slot = entries.itemAtIndex(screen.cursor)
      var row = slot && slot.item && !slot.modelData.deleted && !slot.item.sealed ? slot.item : null
      if (!row) return
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) row.editRequested()
      else if (event.key === Qt.Key_Delete) row.deleteRequested()
      else if (event.key === Qt.Key_Space && row.entry.audio) row.togglePlay()
      else return
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
        onUndoPressed: screen.undoDelete()
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
        selected: screen.listingResults ? "" : screen.date
        today: screen.today
        counts: screen.counts
        highlighted: screen.searching && screen.results ? screen.results.days : []
        onPicked: function(date) { screen.openDay(date) }
        onMonthShifted: function(delta) { screen.month = Dates.shiftMonth(screen.month, delta); screen.loadMonth() }
      }

      Rectangle {
        id: yearCard
        visible: screen.yearAgo !== null
        x: 16
        width: parent.width - 32
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        height: yearAgoText.implicitHeight + 30
        radius: 14
        color: yearMouse.containsMouse ? Theme.fill8 : Theme.fill4
        activeFocusOnTab: visible
        border.width: activeFocus ? 2 : 0
        border.color: Theme.accent
        readonly property string label: screen.isToday ? "A year ago today" : "A year before this day"
        function open() { if (screen.yearAgo) screen.openDay(screen.yearAgo.date) }
        Keys.onReturnPressed: open()
        Keys.onEnterPressed: open()
        Keys.onSpacePressed: open()

        Column {
          id: yearAgoText
          x: 14; y: 14
          width: parent.width - 28
          spacing: 8
          Column {
            spacing: 1
            UiText { text: yearCard.label; font.pixelSize: 12; weight: Font.DemiBold }
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
          onClicked: yearCard.open()
        }
        Accessible.role: Accessible.Button
        Accessible.name: label + ", " + (screen.yearAgo ? Dates.full(screen.yearAgo.date) + ": " + screen.yearAgo.entry.text : "")
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
                : "Press Talk, say what's on your mind, and press Stop. ")
              + "OmaFlow writes it down" + (screen.app.journalSettings.keep_recordings === false ? ". " : " and keeps the recording. ")
              + "It's for you, not for pasting into another app. "
              + (!screen.localSpeech ? "Your recordings go to the speech address in Settings, Models."
                : !screen.localCleanup ? "Your words go to the cleanup address in Settings, Models."
                : "Nothing leaves this computer.")
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
            Pill { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; kind: "outline"; text: "Change"; size: 13; onClicked: { settingsSheet.open = true; settingsSheet.editingFolder = true } }
          }
          Item { width: 1; height: 18 }
          Row {
            spacing: 12
            Pill {
              kind: "primary"
              text: "Talk"
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

      // The folder could not be read: say so, and that nothing was lost.
      Column {
        visible: screen.loadError !== "" && !screen.listingResults
        width: Math.min(parent.width - 96, 520)
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -30
        spacing: 22
        Column {
          width: parent.width
          spacing: 10
          UiText {
            width: parent.width
            text: "Can't read your journal in " + String(screen.app.journalSettings.folder || "") + ". Your entries are untouched."
            font.pixelSize: 16
            wrapMode: Text.Wrap
            lineHeightMode: Text.FixedHeight
            lineHeight: 24
          }
          UiText {
            width: parent.width
            text: "Check that the folder exists and is yours, or choose another in Journal settings."
            muted: true
            wrapMode: Text.Wrap
          }
          // What went wrong, word for word, for whoever fixes it.
          UiText {
            width: parent.width
            text: screen.loadError
            font.family: Theme.mono
            font.pixelSize: 11
            muted: true
            wrapMode: Text.Wrap
          }
        }
        Row {
          spacing: 12
          Pill { kind: "primary"; text: "Try again"; size: 14; horizontalPadding: 18; verticalPadding: 9; onClicked: screen.reload() }
          Pill { kind: "fill"; text: "Journal settings"; size: 14; horizontalPadding: 16; verticalPadding: 9; onClicked: settingsSheet.open = true }
        }
      }

      // One day.
      Item {
        anchors.fill: parent
        anchors.leftMargin: 22
        anchors.rightMargin: 20
        anchors.topMargin: 26
        anchors.bottomMargin: 20
        visible: !screen.firstTime && !screen.listingResults && screen.loadError === ""

        Item {
          id: titleRow
          anchors.left: parent.left
          anchors.right: parent.right
          // The day and its year always show in full. The way back sits on a
          // line of its own under the title, and so does the file where the
          // title would not fit beside it, as on a long day name at 760 px.
          // Measured at 36 px; the title may fit itself down to 24 px.
          readonly property bool chipBeside: titleSize.advanceWidth * 24 / 36 <= width - 16 - 16 - 16 - 30 - 8 - fileChip.width
          readonly property bool secondLine: backPills.visible || (fileChip.visible && !chipBeside)
          height: secondLine ? 64 + 32 : 64
          TextMetrics { id: titleSize; font: dayTitle.font; text: dayTitle.text }
          // The title ends before the file and menu buttons; a long day name
          // gets a little smaller rather than running under them.
          BookText {
            id: dayTitle
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: fileChip.visible && titleRow.chipBeside ? fileChip.left : moreButton.left
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
            id: backPills
            visible: !screen.isToday || screen.viewingHit
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.top: dayTitle.bottom
            anchors.topMargin: 2
            Pill {
              visible: !screen.isToday && !screen.viewingHit
              kind: "outline"
              text: "Back to today"
              size: 13
              onClicked: screen.openDay(screen.app.todayIso())
            }
            Pill {
              visible: screen.viewingHit
              kind: "outline"
              text: "Back to results"
              size: 13
              shortcut: "Esc"
              hint: "Esc"
              leading: Component { Icon { name: "left"; size: 9; color: Theme.text } }
              onClicked: screen.viewingHit = false
            }
          }
          Rectangle {
            id: fileChip
            visible: screen.day !== null && screen.day.exists
            x: titleRow.chipBeside ? moreButton.x - 8 - width : backPills.visible ? backPills.x + backPills.width + 8 : 16
            y: titleRow.chipBeside ? moreButton.y + (moreButton.height - height) / 2 : backPills.y + (backPills.height - height) / 2
            height: 26
            width: fileRow.implicitWidth + 24
            radius: 13
            color: fileMouse.containsMouse ? Theme.fill8 : "transparent"
            border.width: 1
            border.color: Theme.divider
            Row {
              id: fileRow
              anchors.centerIn: parent
              spacing: 7
              // No folder icon: the chip opens the file; ⋯ opens the folder.
              UiText { anchors.verticalCenter: parent.verticalCenter; text: screen.date + ".md"; font.family: Theme.mono; font.pixelSize: 11; muted: true }
            }
            MouseArea { id: fileMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: screen.app.openInEditor(screen.day.file) }
            activeFocusOnTab: visible
            // The keyboard ring, outside the shape like a Pill's.
            Rectangle { anchors.fill: parent; anchors.margins: -3; radius: height / 2; color: "transparent"; border.width: 2; border.color: Theme.accent; visible: fileChip.activeFocus }
            Keys.onReturnPressed: screen.app.openInEditor(screen.day.file)
            Keys.onEnterPressed: screen.app.openInEditor(screen.day.file)
            Keys.onSpacePressed: screen.app.openInEditor(screen.day.file)
            Accessible.role: Accessible.Button
            Accessible.name: "Open " + screen.date + ".md in your editor"
          }
          Rectangle {
            id: moreButton
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.top: parent.top
            anchors.topMargin: 8
            width: 30; height: 30; radius: 15
            color: moreMouse.containsMouse || menu.open ? Theme.fill8 : "transparent"
            border.width: 1
            border.color: Theme.divider
            Icon { anchors.centerIn: parent; name: "more"; size: 14; color: Theme.text }
            MouseArea { id: moreMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: menu.open = !menu.open }
            activeFocusOnTab: true
            Rectangle { anchors.fill: parent; anchors.margins: -3; radius: height / 2; color: "transparent"; border.width: 2; border.color: Theme.accent; visible: moreButton.activeFocus }
            Keys.onReturnPressed: menu.open = !menu.open
            Keys.onEnterPressed: menu.open = !menu.open
            Keys.onSpacePressed: menu.open = !menu.open
            Accessible.role: Accessible.Button
            Accessible.name: "Journal options"
          }
        }

        ListView {
          id: entries
          anchors.top: titleRow.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: composer.top
          anchors.bottomMargin: 14
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
                draft: editing ? screen.editDraft : ""
                current: screen.cursor === slot.index
                onEditRequested: { screen.editDraft = ""; screen.editingId = String(slot.modelData.id) }
                onCancelRequested: { screen.editingId = ""; screen.editDraft = ""; screen.focusKeys() }
                // The editor stays open until the words are written, so a
                // failed save keeps them, with why beside it, over the day
                // as the file has it now.
                onSaveRequested: function(text) {
                  screen.app.query(["journal", "edit", screen.date, slot.modelData.id, text], function(value, error) {
                    if (error) { screen.editDraft = text; screen.flash(screen.writeError(error, screen.date), true); screen.reload(); return }
                    screen.editingId = ""
                    screen.editDraft = ""
                    screen.focusKeys()
                    screen.afterWrite(value, error, "Saved")
                  })
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
              width: parent.width
              wrapMode: Text.Wrap
              text: screen.isFuture ? "Talk or type below. It stays sealed until that day, and OmaFlow tells you when it arrives."
                : screen.isPast ? "Talk or type below to add it now."
                : "Talk or type below. Pick a later day in the calendar to leave yourself a note."
              muted: true
            }
          }
        }

        JournalComposer {
          id: composer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          app: screen.app
          laterDay: screen.isFuture ? screen.date : ""
          pastDay: screen.isPast ? screen.date : ""
          onUndoPressed: screen.undoDelete()
          onTyped: function(text) {
            screen.app.query(screen.isToday ? ["journal", "add", text] : ["journal", "add", text, screen.date], function(value, error) {
              if (!error) composer.clearInput()
              // An entry added to a past day goes in by its time: show it there.
              if (value && value.entry && screen.isPast) screen.focusId = String(value.entry.id)
              screen.afterWrite(value, error, "")
            })
          }
        }
      }

      // Search: the words across every day, newest first.
      Item {
        anchors.fill: parent
        anchors.leftMargin: 22
        anchors.rightMargin: 20
        anchors.topMargin: 26
        anchors.bottomMargin: 20
        visible: screen.listingResults

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
            width: page.width - 80
            wrapMode: Text.Wrap
            text: screen.searchError ? "Can't search your journal in " + String(screen.app.journalSettings.folder || "") + "."
              : !screen.results ? "Searching…"
              : screen.results.hits.length === 0 ? "Not in your journal yet."
              : "Mentioned on " + screen.results.days.length + (screen.results.days.length === 1 ? " day" : " days")
                + (screen.results.truncated ? ", showing the newest 200 entries" : "")
                + ". Up and Down to move, Enter opens the entry."
            color: screen.searchError ? Theme.redText : Theme.secondary
          }
          // As for a folder that cannot be read: what went wrong, word for
          // word, and the way to another folder.
          UiText {
            visible: screen.searchError !== ""
            width: page.width - 80
            wrapMode: Text.Wrap
            text: screen.searchError
            font.family: Theme.mono
            font.pixelSize: 11
            muted: true
          }
          Item { visible: screen.searchError !== ""; width: 1; height: 8 }
          Pill { visible: screen.searchError !== ""; kind: "fill"; text: "Journal settings"; size: 14; horizontalPadding: 16; verticalPadding: 9; onClicked: settingsSheet.open = true }
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
            id: hit
            required property var modelData
            required property int index
            // A note written ahead to a day still to come keeps its words to
            // itself here too, as on its day.
            readonly property bool note: String(modelData.time).indexOf("Note from ") === 0
            readonly property bool sealed: note && modelData.date > screen.today
            readonly property string sealedText: "Sealed until " + Dates.full(modelData.date) + "."
            width: hits.width
            height: Math.max(dateCol.implicitHeight, snippet.implicitHeight) + 28
            radius: Theme.radiusPanel
            color: index === screen.resultIndex ? Theme.fill4 : hitMouse.containsMouse ? Theme.alpha(Theme.fill4, 0.6) : "transparent"
            Column {
              id: dateCol
              x: 16; y: 16
              width: 92
              spacing: 1
              // Another year goes on the time line, so the day keeps to its column.
              readonly property var label: /^(.*) ([0-9]{4})$/.exec(Dates.short(modelData.date, screen.today))
              UiText { width: parent.width; elide: Text.ElideRight; text: dateCol.label ? dateCol.label[1] : Dates.short(modelData.date, screen.today); weight: Font.DemiBold }
              UiText { width: parent.width; elide: Text.ElideRight; text: (dateCol.label ? dateCol.label[2] + ", " : "") + (hit.note ? "Note" : modelData.time); muted: true; font.pixelSize: 12 }
            }
            BookText {
              id: snippet
              x: 16 + 92
              y: 12
              width: parent.width - x - 16
              textFormat: hit.sealed ? Text.PlainText : Text.StyledText
              text: hit.sealed ? hit.sealedText : highlight(modelData.snippet, modelData.matches)
              color: hit.sealed ? Theme.secondary : Theme.text
              font.italic: hit.sealed
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
            Accessible.name: Dates.short(modelData.date, screen.today) + " " + (hit.note ? "note" : modelData.time) + ": "
              + (hit.sealed ? hit.sealedText : modelData.snippet)
          }
        }
      }

      Toast {
        id: journalToast
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
    name: "Journal options"
    items: [
      { label: "Journal settings", action: "settings" },
      { label: "Open the folder", action: "folder" }
    ]
    onPicked: function(action) {
      if (action === "settings") settingsSheet.open = true
      else if (action === "folder") screen.app.openExternally(screen.app.journalSettings.folder_path || screen.app.journalSettings.folder)
    }
  }

  function exportJournal() {
    app.query(["journal", "export"], function(value, error) {
      var path = value ? String(value.path) : ""
      var days = value ? Number(value.days) : 0
      settingsSheet.exportError = !value
      // Downloads is named; anywhere else, such as home when there is no
      // Downloads, gets the whole path so the file can be found.
      var folder = path.replace(/\/[^\/]*$/, "").replace(/^.*\//, "")
      settingsSheet.exportMessage = value
        ? "Saved " + days + (days === 1 ? " day" : " days") + " to "
          + (folder === "Downloads" ? path.replace(/^.*\//, "") + " in Downloads" : path)
        : "Couldn't export: " + writeError(error || "OmaFlow did not answer", "")
    })
  }

  JournalSettingsSheet {
    id: settingsSheet
    app: screen.app
    days: screen.totalDays
    recordings: screen.recordings
    // Not while the days move: the result would have nowhere to show.
    onClosed: if (!moving) open = false
    onExportRequested: screen.exportJournal()
  }
}
