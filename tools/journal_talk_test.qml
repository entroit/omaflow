// The journal's Talk button: a click starts a hands-free entry that Stop
// saves; holding it records until you let go. Esc in the typing field leaves
// it and keeps the draft; Enter saves and Shift+Enter starts a new line. And
// the journal page: an unreadable folder is not a first visit, a search
// result opens on its entry with the results kept behind it, a past day can
// still be written, a new folder asks before it moves your days, and Enter,
// Delete and Space work the entry under the cursor. A failed edit or search
// says why and keeps your words.
//   qmltestrunner -input tools/journal_talk_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
import "preview/Fixtures.js" as Fixtures

Item {
  id: root
  width: 900; height: 700
  property var sent: []
  // What `omaflow journal …` answers, by subcommand; the rest answer nothing.
  property var replies: ({})
  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    host: QtObject {
      function spawn(argv, callback) {
        root.sent.push(argv.slice(1).join(" "))
        var reply = argv[1] === "journal" && root.replies[argv[2]] !== undefined ? JSON.stringify(root.replies[argv[2]]) : ""
        callback(reply, "", 0)
      }
      function copy(text) {}
    }
    Component.onCompleted: applyState(JSON.stringify(Fixtures.state("journal", Fixtures.NOW)))
  }
  JournalComposer { id: composer; width: 660; app: app }
  property var typedText: []
  Connections { target: composer; function onTyped(text) { root.typedText.push(text) } }
  JournalScreen { id: journal; y: 120; width: 880; height: 560; app: app }
  JournalSettingsSheet { id: sheet; app: app; days: 16 }
  property var pickedDays: []
  JournalCalendar {
    id: calendar
    x: 680; width: 220
    month: "2026-09"; today: Fixtures.TODAY; selected: "2026-09-29"
    counts: ({ "2026-09-24": 1, "2026-09-25": 3 })
    onPicked: function(date) { root.pickedDays.push(date) }
    onMonthShifted: function(delta) { month = delta > 0 ? "2026-10" : "2026-09" }
  }
  Component { id: entryComponent; JournalEntry {} }
  function named(item, name) {
    if (item.Accessible.name === name) return item
    for (var i = 0; i < item.children.length; i++) { var f = named(item.children[i], name); if (f) return f }
    return null
  }
  function talk() {
    function find(item) {
      if (item.text === "Talk" || item.text === "Stop" || item.text === "Let go to save") return item
      for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i]); if (f) return f }
      return null
    }
    return find(composer)
  }
  function field() {
    function find(item) {
      if (item.Accessible.name === "Type a journal entry") return item
      for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i]); if (f) return f }
      return null
    }
    return find(composer)
  }
  function find(item, test) {
    if (test(item)) return item
    for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i], test); if (f) return f }
    return null
  }
  function shown(item, text) {
    return find(item, function(node) { return node.text === text && node.visible })
  }
  // `takeDate`: the other day the daemon says the entry goes to.
  function recording(on, takeDate) {
    var state = Fixtures.state(on ? "journal-talking" : "journal", Fixtures.NOW)
    if (takeDate) state.take_date = takeDate
    app.applyState(JSON.stringify(state))
  }

  TestCase {
    name: "JournalTalk"
    when: windowShown
    function test_click_starts_hands_free_and_stop_saves() {
      root.sent = []
      mouseClick(talk())
      compare(root.sent, ["journal-toggle"], "one click, one hands-free start")
      recording(true)
      compare(field().placeholderText, "Listening, 0:37. Stop saves it.")
      wait(20)
      mouseClick(talk())
      compare(root.sent, ["journal-toggle", "journal-toggle"], "Stop saves")
      recording(false)
    }
    function test_esc_leaves_the_field_and_keeps_the_draft() {
      composer.focusInput()
      keyClick(Qt.Key_H); keyClick(Qt.Key_I)
      compare(field().text, "hi")
      keyClick(Qt.Key_Escape)
      verify(!field().activeFocus, "Esc leaves the field")
      compare(field().text, "hi", "and the draft is still there")
      composer.clearInput()
    }
    function test_hold_records_until_let_go() {
      root.sent = []
      var button = talk()
      mousePress(button)
      compare(root.sent, ["journal-toggle"])
      recording(true)
      wait(450)
      compare(talk().text, "Let go to save")
      mouseRelease(talk())
      compare(root.sent, ["journal-toggle", "journal-toggle"], "letting go saves, and nothing starts again")
      recording(false)
      wait(20)
      mouseClick(talk())
      compare(root.sent.length, 3, "the next click starts a new entry")
    }
      function test_enter_saves_and_shift_enter_starts_a_new_line() {
      root.typedText = []
      var base = composer.height
      composer.focusInput()
      keyClick(Qt.Key_A)
      keyClick(Qt.Key_Return, Qt.ShiftModifier)
      keyClick(Qt.Key_B)
      compare(field().text, "a\nb", "Shift+Enter is a new line")
      compare(root.typedText.length, 0, "and saves nothing")
      verify(composer.height > base, "the field grows with the words")
      keyClick(Qt.Key_Return)
      compare(root.typedText, ["a\nb"], "Enter saves both lines as one entry")
      composer.clearInput()
      compare(composer.height, base)
    }
    function test_button_names_what_typing_does() {
      composer.focusInput()
      keyClick(Qt.Key_H)
      verify(named(composer, "Save"), "the journal saves")
      composer.addLabel = "Add to Infra"
      verify(named(composer, "Add to Infra"), "a caller can say where it goes")
      composer.addLabel = "Save"
      composer.clearInput()
    }
    function test_calendar_counts_entries_in_words() {
      verify(named(calendar, "Thursday, 24 September 2026, 1 entry"))
      verify(named(calendar, "Friday, 25 September 2026, today, 3 entries"))
    }
    function test_calendar_days_work_from_the_keyboard() {
      root.pickedDays = []
      var day = named(calendar, "Tuesday, 29 September 2026")
      verify(day.activeFocusOnTab, "Tab lands on the chosen day")
      day.forceActiveFocus()
      keyClick(Qt.Key_Right)
      verify(named(calendar, "Wednesday, 30 September 2026").activeFocus, "Right moves a day")
      keyClick(Qt.Key_Right)
      compare(calendar.month, "2026-10", "and on into the next month")
      verify(named(calendar, "Thursday, 1 October 2026").activeFocus)
      keyClick(Qt.Key_Return)
      compare(root.pickedDays, ["2026-10-01"], "Return opens the day")
      calendar.month = "2026-09"
    }
    function test_unreadable_journal_is_not_a_first_visit() {
      root.replies = { day: { error: "Permission denied" }, stats: { error: "Permission denied" }, month: { month: "2026-09", days: [] } }
      journal.openDay(Fixtures.TODAY)
      compare(journal.day, null, "no other day's entries under the title")
      compare(journal.totalDays, -1)
      verify(!journal.firstTime, "not the first-visit page")
      verify(journal.loadError.indexOf("Permission denied") >= 0)
      verify(shown(journal, "Can't read your journal in ~/Documents/Journal. Your entries are untouched."))
      verify(shown(journal, "Check that the folder exists and is yours, or choose another in Journal settings."))
      verify(shown(journal, "Permission denied"), "and the error word for word")
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH }
      journal.reload()
      compare(journal.loadError, "", "Try again reads it once it can")
    }
    function test_a_past_day_can_still_be_written() {
      var empty = { date: "2026-09-18", title: "", file: "", exists: false, entries: [] }
      root.replies = { day: empty, stats: { days: 16 }, month: Fixtures.MONTH }
      journal.openDay("2026-09-18")
      verify(shown(journal, "Nothing was written on this day."))
      verify(shown(journal, "Talk or type below to add it now."))
      var input = find(journal, function(node) { return node.Accessible.name === "Type a journal entry" })
      verify(input.visible, "the composer is there")
      compare(input.placeholderText, "or type what happened that day")
      root.sent = []
      waitForRendering(journal)
      mouseClick(shown(journal, "Talk"))
      compare(root.sent, ["journal-toggle 2026-09-18"], "Talk adds to that day")
      recording(true, "2026-09-18")
      compare(input.placeholderText, "Listening, 0:37. Stop adds it to Friday, 18 September.", "and says so while you talk")
      recording(false)
      root.sent = []
      root.replies = { add: { date: "2026-09-18", entry: { id: 7 } }, day: empty, stats: { days: 16 }, month: Fixtures.MONTH }
      input.text = "Rain all day."
      input.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(root.sent[0], "journal add Rain all day. 2026-09-18", "and so does typing")
      verify(shown(journal, "Back to today"), "the way back stays")
      journal.openDay("2026-09-30")
      verify(shown(journal, "Back to today"), "from a later day too")
      journal.openDay("")
    }
    function test_a_new_folder_asks_before_it_moves_the_days() {
      root.sent = []
      root.replies = { "move-folder": { error: "2 days already exist in ~/Notes: 2026-09-24, 2026-09-25. Nothing was moved." } }
      sheet.open = true
      tryVerify(function() { return sheet.opacity === 1 })
      sheet.editingFolder = true
      sheet.useFolder("~/Notes")
      verify(shown(sheet, "Move your 16 days to ~/Notes?"), "the consequence first")
      compare(root.sent, [], "and nothing moves until you say")
      waitForRendering(sheet)
      mouseClick(shown(sheet, "Move them"))
      compare(root.sent, ["journal move-folder ~/Notes"])
      verify(shown(sheet, "2 days already exist in ~/Notes: 2026-09-24, 2026-09-25. Nothing was moved."))
      verify(sheet.movingTo === "~/Notes", "a clash keeps the question open")
      compare(shown(sheet, "Move them").kind, "primary", "moving stays the way on, once the clash is fixed")
      compare(shown(sheet, "Don't move them").kind, "fill")
      compare(shown(sheet, "Done"), null, "and no Done to drop the question")

      root.sent = []
      root.replies = { "move-folder": { days: 16, folder: "~/Notes" } }
      waitForRendering(sheet)
      mouseClick(shown(sheet, "Move them"))
      compare(root.sent[0], "journal move-folder ~/Notes")
      compare(root.sent[1], "configure journal_folder \"~/Notes\"", "then the daemon gets the folder")
      verify(shown(sheet, "Moved 16 days to ~/Notes."))

      root.sent = []
      sheet.editingFolder = true
      sheet.useFolder("~/Elsewhere")
      waitForRendering(sheet)
      mouseClick(shown(sheet, "Don't move them"))
      compare(root.sent[0], "configure journal_folder \"~/Elsewhere\"", "nothing moves")
      verify(shown(sheet, "Your 16 days stay in ~/Documents/Journal."))
      verify(shown(sheet, "Done"), "Done is back once the folder step is over")
      sheet.open = false
      tryVerify(function() { return !sheet.visible })
    }
    function test_a_move_waits_for_the_entry_being_recorded() {
      sheet.open = true
      tryVerify(function() { return sheet.opacity === 1 })
      sheet.editingFolder = true
      sheet.useFolder("~/Notes")
      try {
        recording(true)
        verify(shown(sheet, "Finish the entry you are recording first."))
        compare(shown(sheet, "Move them").enabled, false)
        compare(shown(sheet, "Don't move them").enabled, false, "the entry would land in one folder or the other")
        var state = Fixtures.state("journal-talking", Fixtures.NOW)
        state.phase = "processing"
        app.applyState(JSON.stringify(state))
        verify(shown(sheet, "Wait until the entry is written down."), "and while it is written down")
        compare(shown(sheet, "Move them").enabled, false)
      } finally {
        recording(false)
      }
      verify(shown(sheet, "If you don't move them, they stay in ~/Documents/Journal."))
      compare(shown(sheet, "Move them").enabled, true)
      sheet.open = false
      tryVerify(function() { return !sheet.visible })
    }
    function test_a_move_that_leaves_copies_behind_names_them() {
      root.replies = { "move-folder": { days: 16, folder: "~/Notes", left_behind: ["2026-09-24.md", "2026-09-25.md"] } }
      sheet.open = true
      sheet.editingFolder = true
      sheet.useFolder("~/Notes")
      sheet.moveDays()
      compare(sheet.folderMessage, "Moved 16 days to ~/Notes. These could not be removed from ~/Documents/Journal: 2026-09-24.md, 2026-09-25.md."
        + " Delete them there yourself once you've checked the new folder.")
      verify(!sheet.folderError, "the days moved")
      sheet.open = false
      tryVerify(function() { return !sheet.visible })
    }
    function test_the_keyboard_works_the_entry_under_the_cursor() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH }
      journal.openDay(Fixtures.TODAY)
      waitForRendering(journal)
      var id = String(Fixtures.DAY.entries[0].id)
      journal.focusKeys()
      keyClick(Qt.Key_Down)
      compare(journal.cursor, 0)
      keyClick(Qt.Key_Return)
      compare(journal.editingId, id, "Enter edits")
      var editor = find(journal, function(node) { return node.Accessible.name === "Edit entry from 07:42" && node.cursorPosition !== undefined })
      tryVerify(function() { return editor.activeFocus })
      keyClick(Qt.Key_Escape)
      compare(journal.editingId, "", "Esc cancels")
      keyClick(Qt.Key_Return)
      tryVerify(function() { return editor.activeFocus })
      keyClick(Qt.Key_Return, Qt.ShiftModifier)
      keyClick(Qt.Key_A)
      compare(journal.editingId, id, "Shift+Enter is a new line")
      root.sent = []
      keyClick(Qt.Key_Return)
      compare(root.sent[0], "journal edit " + Fixtures.TODAY + " " + id + " " + Fixtures.DAY.entries[0].text + "\na", "Enter saves")
      compare(journal.editingId, "")
      root.sent = []
      keyClick(Qt.Key_Space)
      compare(root.sent, ["journal-play " + Fixtures.TODAY + " " + id + " 0"], "Space plays")
      root.sent = []
      keyClick(Qt.Key_Delete)
      compare(root.sent[0], "journal delete " + Fixtures.TODAY + " " + id, "Delete deletes")
      journal.pendingDelete = null
      journal.cursor = -1
    }
    function test_a_failed_edit_keeps_the_words() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH, edit: { error: "That entry is no longer in the file" } }
      journal.openDay(Fixtures.TODAY)
      var id = String(Fixtures.DAY.entries[0].id)
      journal.editingId = id
      var editor = find(journal, function(node) { return node.Accessible.name === "Edit entry from 07:42" && node.cursorPosition !== undefined })
      tryVerify(function() { return editor.activeFocus })
      keyClick(Qt.Key_B)
      keyClick(Qt.Key_Return)
      compare(journal.editingId, id, "the editor stays open")
      compare(journal.toast, "That entry changed in " + Fixtures.TODAY + ".md. The page is up to date now, so try again.")
      // The day is read again, and the rebuilt editor still has your words.
      tryVerify(function() {
        editor = find(journal, function(node) { return node.Accessible.name === "Edit entry from 07:42" && node.cursorPosition !== undefined })
        return editor && editor.activeFocus && editor.text.slice(-1) === "b"
      }, 1000, "with the words you wrote")
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH }
      keyClick(Qt.Key_Return)
      compare(journal.editingId, "", "a save that works closes it")
    }
    function test_an_edit_whose_entry_is_gone_keeps_the_words_below() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH, edit: { error: "That entry is no longer in the file" } }
      journal.openDay(Fixtures.TODAY)
      journal.editingId = String(Fixtures.DAY.entries[0].id)
      var editor = find(journal, function(node) { return node.Accessible.name === "Edit entry from 07:42" && node.cursorPosition !== undefined })
      tryVerify(function() { return editor.activeFocus })
      var gone = JSON.parse(JSON.stringify(Fixtures.DAY))
      gone.entries.shift()
      root.replies = { day: gone, stats: { days: 16 }, month: Fixtures.MONTH, edit: { error: "That entry is no longer in the file" } }
      editor.text = "Slept well after all."
      keyClick(Qt.Key_Return)
      compare(journal.editingId, "", "the editor has nothing left to edit")
      var input = find(journal, function(node) { return node.Accessible.name === "Type a journal entry" })
      compare(input.text, "Slept well after all.", "so the words wait in the composer")
      compare(journal.toast, "That entry is no longer in " + Fixtures.TODAY + ".md. Your words are below, to save as a new entry.")
      input.text = ""
      journal.toast = ""
    }
    function test_a_failed_search_says_why() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH, search: { error: "Permission denied (os error 13)" } }
      journal.query = "workshop"
      journal.runSearch()
      verify(shown(journal, "Can't search your journal in ~/Documents/Journal."), "not Searching… for ever")
      verify(shown(journal, "Permission denied (os error 13)"), "with the reason word for word")
      verify(shown(journal, "Journal settings"), "and the way to another folder")
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH, search: Fixtures.SEARCH }
      journal.runSearch()
      compare(journal.searchError, "")
      journal.openDay("")
    }
    function test_search_keeps_a_sealed_note_to_itself() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH, search: Fixtures.SEARCH_NOTE }
      journal.query = "Mira"
      journal.runSearch()
      waitForRendering(journal)
      verify(shown(journal, "Sealed until Friday, 2 October 2026."), "a note for a later day says when it opens")
      compare(find(journal, function(node) { return node.visible && String(node.text).indexOf("first week without the studio") >= 0 }), null, "and not what it says")
      verify(find(journal, function(node) { return node.visible && String(node.text).indexOf("say yes to the workshop?") >= 0 }), "a note whose day has come shows")
      verify(named(journal, "Fri 2 Oct note: Sealed until Friday, 2 October 2026."), "assistive tech hears the same")
      compare(find(journal, function(node) { return node.visible && String(node.text).indexOf("Note from") === 0 }), null, "a note's time line says Note")
      journal.openDay("")
    }
    function test_closing_a_sheet_gives_the_keyboard_back() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH }
      journal.openDay(Fixtures.TODAY)
      var more = named(journal, "Journal options")
      more.forceActiveFocus()
      var own = find(journal, function(node) { return String(node).indexOf("JournalSettingsSheet") === 0 })
      own.open = true
      verify(!more.activeFocus)
      keyClick(Qt.Key_Escape)
      verify(!own.open)
      verify(more.activeFocus, "the keyboard is back where it was")
    }
    function test_undo_on_another_day_says_where_the_entry_went() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH }
      journal.openDay(Fixtures.TODAY)
      journal.deleteEntry(Fixtures.TODAY, Fixtures.DAY.entries[0], 0)
      journal.openDay("2026-09-18")
      journal.toast = ""
      journal.undoDelete()
      compare(journal.toast, "The entry from 07:42 is back on Friday, 25 September.")
      journal.toast = ""
      journal.openDay("")
    }
    function test_a_second_delete_says_the_first_is_gone() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH }
      journal.openDay(Fixtures.TODAY)
      journal.toast = ""
      journal.deleteEntry(Fixtures.TODAY, Fixtures.DAY.entries[0], 0)
      compare(journal.toast, "", "the first delete waits with Undo")
      journal.deleteEntry(Fixtures.TODAY, Fixtures.DAY.entries[1], 1)
      compare(journal.toast, "The entry from 07:42 is deleted for good.")
      journal.pendingDelete = null
      journal.toast = ""
    }
    function test_ctrl_z_in_the_empty_composer_undoes_the_delete() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH }
      journal.openDay(Fixtures.TODAY)
      journal.deleteEntry(Fixtures.TODAY, Fixtures.DAY.entries[0], 0)
      var input = find(journal, function(node) { return node.Accessible.name === "Type a journal entry" })
      input.forceActiveFocus()
      root.sent = []
      keyClick(Qt.Key_Z, Qt.ControlModifier)
      compare(root.sent[0], "journal restore " + Fixtures.TODAY + " " + Fixtures.DAY.entries[0].id, "the field has nothing to undo, so the entry comes back")
      compare(journal.pendingDelete, null)
    }
    function test_a_failed_export_can_be_tried_again() {
      root.replies = { export: { error: "Downloads is not writable" } }
      var own = find(journal, function(node) { return String(node).indexOf("JournalSettingsSheet") === 0 })
      own.open = true
      tryVerify(function() { return own.opacity === 1 })
      journal.exportJournal()
      verify(shown(own, "Couldn't export: Downloads is not writable."), "what failed")
      verify(shown(own, "Export as one file"), "and the button stays, to try again")
      own.open = false
      tryVerify(function() { return !own.visible })
    }
    function test_an_entry_says_when_its_recording_was_not_kept() {
      var spoken = Object.assign({}, Fixtures.DAY.entries[1], { audio: false })
      var row = entryComponent.createObject(root, { entry: spoken, date: Fixtures.TODAY, width: 600 })
      verify(shown(row, "Recording not kept"))
      row.current = true
      var asSpoken = named(row, "Show entry from 12:15 as spoken")
      verify(asSpoken.Accessible.checkable)
      compare(asSpoken.Accessible.checked, false)
      row.spoken = true
      compare(asSpoken.Accessible.checked, true, "the state reaches assistive tech")
      row.destroy()
    }
    function test_add_a_shortcut_steps_aside_while_talking() {
      verify(shown(composer, "Add a shortcut"))
      recording(true)
      compare(shown(composer, "Add a shortcut"), null)
      recording(false)
    }
    function test_search_result_opens_its_entry_and_keeps_the_results() {
      root.replies = { day: Fixtures.DAY, stats: { days: 16 }, month: Fixtures.MONTH }
      journal.query = "workshop"
      journal.results = Fixtures.SEARCH
      journal.openResult(0)
      verify(journal.viewingHit)
      compare(journal.query, "workshop", "the search stays")
      compare(journal.cursor, 1, "the matching entry is the current one")
      verify(!journal.listingResults)
      journal.viewingHit = false
      verify(journal.listingResults, "Back to results")
      journal.openDay("")
      compare(journal.query, "", "opening a day leaves the search")
      compare(journal.date, Fixtures.TODAY)
      journal.focusKeys()
      keyClick(Qt.Key_Left, Qt.AltModifier)
      compare(journal.date, "2026-09-24", "Alt+Left turns back a day")
      keyClick(Qt.Key_Right, Qt.AltModifier)
      compare(journal.date, Fixtures.TODAY)
    }
  }
}
