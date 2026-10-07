// The finished cards: the Esc ring counts down and closes, pointing at a card
// stops its clock, and the to-dos card edits and takes out its to-dos in place.
// The cards name the day a note went to and the key that pastes, a missed
// paste closes like the clipboard card, a download shows how far, Open goes
// where the words went, a card that names a settings page opens it, and a
// recording only the card holds is only thrown away on purpose; one saved in
// History closes like any card and is deleted from History. Words only the
// card holds wait the same way, Discard on a long take asks first, and a word
// said while a take records shows on its card.
//   qmltestrunner -input tools/overlay_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
import "preview/Fixtures.js" as Fixtures

Item {
  id: root
  width: 720; height: 400
  property var sent: []
  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    host: QtObject {
      function spawn(argv, callback) {
        var args = argv.slice(1)
        root.sent.push(args.join(" "))
        var reply = args[0] === "todos" ? JSON.stringify({ lists: Fixtures.LISTS, todos: [] }) : "{}"
        if (callback) Qt.callLater(function() { callback(reply, "", 0) })
      }
      function copy(text) {}
      function showWindow(page) { root.sent.push("show " + page) }
    }
  }
  OverlayCard { id: card; app: app; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 60 }

  function show(mode) { app.applyState(JSON.stringify(Fixtures.state(mode, Fixtures.NOW))) }
  function commands() { return root.sent.filter(function(line) { return line.indexOf("todos list") < 0 }) }
  function find(item, test) {
    if (item.visible && test(item)) return item
    for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i], test); if (f) return f }
    return null
  }
  function text(value) { return find(card, function(item) { return item.text === value }) }
  function ring() { return find(card, function(item) { return item.Accessible.name === "Close the card" }) }
  function status() { return find(card, function(item) { return item.Accessible.role === Accessible.StatusBar }).Accessible.name }

  TestCase {
    name: "Overlay"
    when: windowShown
    function init() {
      // A fresh capture, as after a take.
      show("overlay-processing-todos"); wait(20)
      show("overlay-todos-saved")
      wait(350)  // past the card's reshape, as a person would be
      mouseMove(root, 5, 5)
      root.sent = []
    }

    function test_the_ring_fills_as_the_time_runs_out() {
      verify(card.elapsed > 0.25 && card.elapsed < 0.6, "about a third gone: " + card.elapsed)
      var before = card.elapsed
      wait(300)
      verify(card.elapsed > before, "and it keeps filling")
    }
    function test_the_ring_closes_the_card() {
      mouseClick(ring())
      compare(commands(), ["dismiss"])
    }
    function test_cards_you_can_act_on_have_the_ring() {
      ["overlay-result", "overlay-error", "overlay-journal-saved", "overlay-notice"].forEach(function(mode) {
        show(mode); wait(20)
        verify(ring() !== null, mode)
      })
      // Nothing to act on: they just go.
      show("overlay-success"); wait(20)
      verify(ring() === null, "overlay-success")
      var state = Fixtures.state("overlay-notice", Fixtures.NOW)
      state.feedback = "No words came through. Try again a little closer to the microphone."
      app.applyState(JSON.stringify(state)); wait(20)
      verify(ring() === null, "a notice with nothing to open")
    }
    function test_pointing_at_the_card_stops_the_clock() {
      mouseMove(text("Rotate the deploy key"))
      tryCompare(card, "hold", "hover")
      compare(commands(), ["card-hold"])
      mouseMove(root, 5, 5)
      tryCompare(card, "hold", "")
      compare(commands(), ["card-hold", "card-resume"])
    }
    function test_a_to_do_is_edited_in_place() {
      var item = text("Rotate the deploy key")
      mouseClick(item)
      compare(card.hold, "edit", "Esc cannot close the card mid-edit")
      waitForRendering(card)
      keyClick(Qt.Key_Space); keyClick(Qt.Key_N); keyClick(Qt.Key_O); keyClick(Qt.Key_W)
      keyClick(Qt.Key_Return)
      compare(card.editingIndex, -1)
      verify(commands().indexOf("todo-card-edit " + Fixtures.SAVED[2].index + " Rotate the deploy key Rotate the deploy key now") >= 0, commands().join(" | "))
    }
    function test_esc_drops_an_edit_and_keeps_the_card() {
      mouseClick(text("Rotate the deploy key"))
      waitForRendering(card)
      keyClick(Qt.Key_X)
      keyClick(Qt.Key_Escape)
      compare(card.editingIndex, -1)
      compare(card.hold, "edit", "held a moment longer, past the Esc binding")
      tryVerify(function() { return card.hold !== "edit" }, 1000)
      verify(commands().every(function(line) { return line.indexOf("todo-card-edit") < 0 }), "nothing changed")
    }
    function test_x_takes_one_to_do_out() {
      var item = text("Rotate the deploy key")
      mouseMove(item)
      var remove = find(card, function(i) { return i.Accessible.name === "Take out Rotate the deploy key" && i.opacity > 0 })
      verify(remove !== null)
      mouseClick(remove)
      verify(commands().indexOf("todo-card-remove " + Fixtures.SAVED[2].index + " Rotate the deploy key") >= 0, commands().join(" | "))
    }
    function test_a_kept_recording_can_be_tried_again() {
      show("overlay-error-kept"); wait(350)
      mouseClick(text("Try again"))
      compare(commands(), ["retry"])
      show("overlay-error"); wait(350)
      verify(text("Try again") === null, "nothing kept, nothing to try again")
    }
    function test_a_kept_recording_is_only_thrown_away_on_purpose() {
      show("overlay-error-kept"); wait(350)
      verify(ring() === null, "Esc leaves this card alone, so it shows no Esc ring")
      verify(text("Your recording is kept.") === null && text("Transcription stalled and was stopped. Your recording is kept until you start another.") !== null)
      var discard = find(card, function(item) { return item.Accessible.name === "Discard the recording" })
      verify(discard !== null)
      mouseClick(discard)
      compare(commands(), ["discard"])
    }
    function test_a_recording_saved_in_history_closes_like_any_card() {
      show("overlay-error-saved"); wait(350)
      verify(text("Transcription stalled and was stopped. Your recording is saved in History.") !== null)
      compare(status(), "Dictation failed. Transcription stalled and was stopped. Your recording is saved in History.")
      verify(text("Discard") === null, "deleting it from History happens in History, beside its Undo")
      mouseClick(text("Try again"))
      mouseClick(ring())
      compare(commands(), ["retry", "dismiss"])
    }
    function test_a_journal_take_for_another_day_names_the_day() {
      show("overlay-journal-for-later"); app.micDetected = true; wait(350)
      // The day and the clock are apart, so the clock does not read as a time.
      verify(text("Note for") !== null && text("Fri 2 Oct") !== null && text("0:09") !== null)
      compare(status(), "Recording a note for Fri 2 Oct, 0:09")
      show("overlay-journal-for-past"); app.micDetected = true; wait(350)
      verify(text("Journal for") !== null && text("Fri 18 Sep") !== null && text("0:09") !== null, "where it goes, as the other days say")
      compare(status(), "Recording a journal entry for Fri 18 Sep, 0:09")
      show("overlay-journal"); wait(350)
      verify(text("Journal") !== null && text("0:37") !== null, "today's entry says only Journal")
    }
    function test_discard_ignores_the_click_that_stopped_the_take() {
      show("overlay-locked"); wait(350)
      show("overlay-processing"); wait(100)
      mouseClick(text("Discard"))
      compare(commands(), [], "a second click on Stop lands here and is ignored")
      wait(400)
      mouseClick(text("Discard"))
      compare(commands(), ["cancel"])
    }
    function test_discard_stays_where_it_was_when_the_take_stops() {
      ;["overlay-locked", "overlay-journal", "overlay-todo"].forEach(function(mode) {
        show(mode); wait(350)
        var before = text("Discard").mapToItem(root, 0, 0)
        show(mode === "overlay-journal" ? "overlay-processing-journal" : mode === "overlay-todo" ? "overlay-processing-todos" : "overlay-processing")
        wait(350)
        var after = text("Discard").mapToItem(root, 0, 0)
        fuzzyCompare(after.x, before.x, 1, mode + ": not onto Stop's old spot")
        fuzzyCompare(after.y, before.y, 1, mode)
      })
      // With no take before it, the card is only as wide as its words.
      show("overlay-error"); wait(350)
      show("overlay-processing"); wait(350)
      compare(card.takeWidth, 0)
    }
    function test_open_goes_where_the_words_went() {
      show("overlay-journal-saved"); wait(350)
      mouseClick(text("Open"))
      show("overlay-journal-note"); wait(350)
      mouseClick(text("Open"))
      show("overlay-todos-saved"); wait(350)
      mouseClick(text("Open"))
      var state = Fixtures.state("overlay-todos-saved", Fixtures.NOW)
      state.todos_saved = { items: [{ index: 0, text: "Buy oat milk", done: false, list: "" }], moved: false }
      app.applyState(JSON.stringify(state)); wait(350)
      mouseClick(text("Open"))
      compare(commands(), ["show journal/2026-09-25", "show journal/2026-10-02", "show todos/list:Infra", "show todos/list:"])
    }
    function test_a_silent_microphone_is_named_while_you_talk() {
      show("overlay-nomic"); wait(350)
      verify(text("No sound from the microphone") !== null, "four seconds and nothing heard")
      app.micDetected = true; wait(20)
      verify(text("No sound from the microphone") === null)
      app.micDetected = false; wait(20)
      verify(text("No sound from the microphone") === null, "a pause after speaking is not a dead microphone")
      show("overlay-processing"); wait(20)
      show("overlay-nomic"); wait(350)
      verify(text("No sound from the microphone") !== null, "a new take starts listening again")
      show("overlay-notice"); wait(350)
      verify(text("Nothing heard. Check the microphone.") !== null)
    }
    function test_a_missing_model_offers_the_fix() {
      show("overlay-error-model"); wait(350)
      verify(text("Nothing was recorded. Parakeet TDT 0.6B v3 (714 MB) is the usual choice.") !== null)
      mouseClick(text("Choose a model"))
      compare(commands(), ["show settings/models"])
      show("overlay-error"); wait(350)
      verify(text("Choose a model") === null)
    }
    function test_a_downloading_model_asks_you_to_wait() {
      var state = Fixtures.state("overlay-error-downloading", Fixtures.NOW)
      state.can_retry = true
      app.applyState(JSON.stringify(state)); wait(350)
      verify(text("The speech model is still downloading") !== null)
      verify(text("Hold AltGr+Menu again when Parakeet TDT 0.6B v3 finishes.") !== null)
      verify(text("62%") !== null, "how far, beside the title")
      verify(text("Try again") === null, "it would only fail the same way")
      verify(text("Choose a model") === null)
      compare(card.edge, Theme.yellow, "a wait, not a failure")
      // The progress follows the download; the daemon's words stay put.
      state.model_downloads["nvidia/parakeet-tdt-0.6b-v3"].percent = 71
      app.applyState(JSON.stringify(state)); wait(20)
      verify(text("71%") !== null && text("62%") === null, "it moves")
      compare(status(), "The speech model is still downloading, 71%. " + state.error)
      // The download ends while the kept recording waits: now it can go.
      state.model_downloads = {}
      app.applyState(JSON.stringify(state)); wait(20)
      verify(text("71%") === null, "no progress left to show")
      mouseClick(text("Try again"))
      compare(commands(), ["retry"])
    }
    function test_a_notice_says_what_the_daemon_sent() {
      var sent = Fixtures.state("overlay-notice-update", Fixtures.NOW).feedback
      show("overlay-notice-update"); wait(350)
      verify(text(sent) !== null)
      compare(status(), sent)
      verify(text("Nothing heard. Check the microphone.") === null)
      show("overlay-notice"); wait(350)
      verify(text("Nothing heard. Check the microphone.") !== null, "nothing sent: the usual words")
    }
    function test_a_card_that_names_a_settings_page_opens_it() {
      show("overlay-notice"); wait(350)
      mouseClick(text("Audio settings"))
      show("overlay-warning"); wait(350)
      mouseClick(text("Cleanup settings"))
      show("overlay-journal-warning"); wait(350)
      mouseClick(text("Cleanup settings"))
      var state = Fixtures.state("overlay-notice", Fixtures.NOW)
      state.feedback = "An update did not finish, so dictation is paused. Open OmaFlow and choose Try again in Settings, Advanced, Updates and app."
      app.applyState(JSON.stringify(state)); wait(20)
      mouseClick(text("Updates and app"))
      show("overlay-error-mic"); wait(350)
      verify(text("OmaFlow could not reach the microphone.") !== null, "the button says where to check")
      verify(text("OmaFlow could not reach the microphone. Check the microphone in Settings, Audio.") === null)
      compare(status(), "Dictation failed. OmaFlow could not reach the microphone.")
      mouseClick(text("Audio settings"))
      compare(commands(), ["show settings/audio", "show settings/cleanup", "show settings/cleanup", "show settings/updates", "show settings/audio"])
      // A warning about something else has nothing to open.
      ;["overlay-error", "overlay-journal-saved", "overlay-success"].forEach(function(mode) {
        show(mode); wait(20)
        verify(text("Cleanup settings") === null && text("Audio settings") === null, mode)
      })
    }
    function test_the_button_stands_in_for_the_words_that_name_its_page() {
      show("overlay-warning"); wait(350)
      verify(text("Cleanup did not answer, so this is the raw text.") !== null)
      verify(text(Fixtures.state("overlay-warning", Fixtures.NOW).feedback) === null)
      compare(status(), "Pasted. Cleanup did not answer, so this is the raw text.")
      verify(text("Cleanup settings") !== null)
    }
    function test_a_journal_entry_saved_without_cleanup_says_so() {
      var warning = "Cleanup did not answer, so this was saved lightly tidied."
      show("overlay-journal-warning"); wait(350)
      verify(card.tall)
      compare(card.edge, Theme.yellow)
      var line = text(warning)
      verify(line !== null)
      verify(ring().mapToItem(card, 0, 0).y < line.mapToItem(card, 0, 0).y, "Esc above the warning")
      compare(status(), "Added to today's journal. " + warning)
      show("overlay-journal-saved"); wait(350)
      verify(!card.tall && text(warning) === null, "no warning, one capsule")
    }
    function test_the_ring_sits_top_right_on_a_tall_pasted_card() {
      show("overlay-warning"); wait(350)
      var r = ring()
      verify(r !== null)
      var head = r.parent
      compare(r.x + r.width, head.width, "at the right edge")
      verify(r.mapToItem(card, 0, 0).y < text("Cleanup did not answer, so this is the raw text.").mapToItem(card, 0, 0).y, "above the warning")
    }
    function test_the_card_says_what_it_shows() {
      compare(status(), "3 to-dos added to Infra")
      show("overlay-locked"); app.micDetected = true; wait(350)
      compare(status(), "Recording, 0:42")
      show("overlay-success"); wait(350)
      compare(status(), "Pasted")
    }
    function test_a_note_for_a_later_day_names_the_day() {
      show("overlay-journal-note"); wait(350)
      verify(text("Note added for Friday, 2 October") !== null)
      verify(text("23 words, 0:09") !== null, "the figures start with the words, not a time")
      show("overlay-journal-saved"); wait(350)
      verify(text("Added to today's journal") !== null)
    }
    function test_copied_names_the_key_that_pastes_in_that_window() {
      var state = Fixtures.state("overlay-result", Fixtures.NOW)
      app.applyState(JSON.stringify(state)); wait(350)
      verify(text("Press Ctrl+V to paste") !== null, "Ctrl+V until the daemon says otherwise")
      verify(text("It's copied. The paste did not reach the window.") !== null)
      state.paste_key = { modifiers: ["shift"], key: "Insert" }
      app.applyState(JSON.stringify(state)); wait(20)
      verify(text("Press Shift+Insert to paste") !== null, "a terminal")
      state.paste_mode = "custom"
      state.paste_key = { modifiers: ["ctrl", "shift"], key: "F8" }
      app.applyState(JSON.stringify(state)); wait(20)
      verify(text("Press Ctrl+Shift+F8 to paste") !== null, "a custom chord")
    }
    function test_a_missed_paste_closes_like_the_clipboard_card() {
      ;["overlay-result", "overlay-clipboard"].forEach(function(mode) {
        show(mode); wait(350)
        verify(card.elapsed > 0.25 && card.elapsed < 0.6, mode + " counts down: " + card.elapsed)
      })
      show("overlay-result"); wait(350)
      root.sent = []
      mouseMove(text("Press Ctrl+V to paste"))
      tryCompare(card, "hold", "hover")
      compare(commands(), ["card-hold"], "pointing at it stops the clock")
    }
    function test_more_than_six_say_how_many_more() {
      var state = Fixtures.state("overlay-todos-saved", Fixtures.NOW)
      var many = []
      for (var i = 0; i < 9; i++) many.push({ index: i, text: "Task " + (i + 1), done: false, list: "Infra" })
      state.todos_saved = { items: many, moved: false }
      app.applyState(JSON.stringify(state)); wait(350)
      verify(text("Task 6") !== null && text("Task 7") === null)
      mouseClick(text("and 3 more"))
      compare(commands(), ["show todos/list:Infra"])
    }
    function test_after_a_move_the_button_says_it_takes_them_out() {
      verify(text("Undo") !== null)
      var state = Fixtures.state("overlay-todos-saved", Fixtures.NOW)
      state.todos_saved = { items: Fixtures.SAVED.map(function(item) { return Object.assign({}, item, { list: "Dev" }) }), moved: true }
      app.applyState(JSON.stringify(state)); wait(20)
      compare(card.addedTitle, "3 to-dos moved to")
      verify(text("Undo") === null, "Undo would read as moving them back")
      mouseClick(text("Take out"))
      compare(commands(), ["todo-undo"])
    }
    function test_after_an_edit_or_a_take_out_the_button_says_it_takes_them_out() {
      mouseClick(text("Rotate the deploy key"))
      waitForRendering(card)
      keyClick(Qt.Key_X); keyClick(Qt.Key_Return)
      verify(text("Undo") === null && text("Take out") !== null, "Undo would read as putting the edit back")
      show("overlay-processing-todos"); wait(20)
      show("overlay-todos-saved"); wait(350)
      verify(text("Undo") !== null, "a new capture starts fresh")
      mouseMove(text("Rotate the deploy key"))
      mouseClick(find(card, function(i) { return i.Accessible.name === "Take out Rotate the deploy key" && i.opacity > 0 }))
      verify(text("Take out") !== null, "after one went with ×")
      // The daemon says so too, so a card shown again still knows.
      show("overlay-processing-todos"); wait(20)
      show("overlay-todos-saved-changed"); wait(350)
      verify(text("Take out") !== null)
    }
    function test_a_cleanup_warning_on_to_dos_marks_the_card() {
      show("overlay-todos-saved-warning"); wait(350)
      compare(card.edge, Theme.yellow, "as on the pasted and journal cards")
      verify(text("Cleanup was unavailable, so these were split by sentence. Check them above.") !== null)
      show("overlay-todos-saved"); wait(350)
      compare(card.edge, Theme.divider)
    }
    function test_words_only_the_card_holds_wait_for_discard() {
      show("overlay-copy-failed"); wait(350)
      verify(ring() !== null, "safe in History: Esc may close it")
      show("overlay-copy-failed-nohistory"); wait(350)
      verify(ring() === null, "History is off: Esc leaves it alone")
      mouseClick(text("Copy again"))
      mouseClick(find(card, function(item) { return item.Accessible.name === "Discard the words" }))
      compare(commands(), ["copy", "discard"])
    }
    function test_discard_on_a_long_take_asks_first() {
      show("overlay-locked"); wait(350)
      mouseClick(text("Discard"))
      compare(commands(), [], "42 seconds is a lot to lose to a slip")
      verify(text("Discard 0:42?") !== null)
      mouseClick(text("Discard 0:42?"))
      compare(commands(), ["cancel"])
      // It stops asking after a moment.
      show("overlay-journal"); wait(350)
      mouseClick(text("Discard"))
      verify(text("Discard 0:37?") !== null)
      wait(3200)
      verify(text("Discard") !== null && text("Discard 0:37?") === null)
      compare(commands(), ["cancel"])
      // A short take goes in one click.
      show("overlay-todo"); wait(350)
      mouseClick(text("Discard"))
      compare(commands(), ["cancel", "todo-discard"])
    }
    function test_a_word_said_while_recording_shows_on_the_card() {
      show("overlay-locked"); app.micDetected = true; wait(350)
      var state = Fixtures.state("overlay-locked", Fixtures.NOW)
      state.feedback = "Finish the recording first, then start the journal entry."
      state.feedback_serial = 41
      app.applyState(JSON.stringify(state)); wait(20)
      verify(text(state.feedback) !== null)
      compare(status(), "Recording, 0:42. " + state.feedback)
      wait(4100)
      verify(text(state.feedback) === null, "it goes after a few seconds")
    }
    function test_a_finished_download_is_good_news() {
      show("overlay-error-ready"); wait(350)
      verify(text("The speech model is ready") !== null)
      compare(card.edge, Theme.divider, "not a failure")
      mouseClick(text("Try again"))
      compare(commands(), ["retry"])
    }
    function test_a_capture_that_was_not_written_opens_its_page() {
      show("overlay-error-journal-save"); wait(350)
      verify(text("The entry was not saved") !== null)
      mouseClick(text("Open"))
      show("overlay-error-todos-save"); wait(350)
      verify(text("The to-dos were not added") !== null)
      mouseClick(text("Open"))
      show("overlay-error"); wait(350)
      verify(text("Open") === null)
      compare(commands(), ["show journal", "show todos"])
    }
    function test_a_list_menu_left_open_lets_the_card_go() {
      tryVerify(function() { return card.todoLists.length > 0 })
      var chip = find(card, function(item) { return item.Accessible.role === Accessible.ComboBox })
      mouseMove(chip)
      mouseClick(chip)
      verify(card.menuArea.open)
      compare(card.hold, "hover")
      // Crossing over to the menu keeps it.
      mouseMove(card.menuArea, card.menuArea.width / 2, 20)
      wait(1000)
      verify(card.menuArea.open)
      mouseMove(root, 5, 5)
      tryCompare(card.menuArea, "open", false, 2000)
      tryCompare(card, "hold", "")
    }
  }
}
