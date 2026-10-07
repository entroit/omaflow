// The window's frame and the colours every screen draws with: words read on
// every fill in light and dark themes, the header says what blocks dictation
// and links to the fix, Start and Restart wait while they run, the update dot
// opens the update, a toast stays while you reach for its Undo, History
// keeps its keys and scrolls a long dictation, Settings follow the keyboard
// and say when nothing is saved, and the Updates page names a failed update,
// what its button does and when it last looked.
//   qmltestrunner -input tools/window_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
import "preview/Fixtures.js" as Fixtures

Item {
  id: root
  width: 880; height: 720
  property var sent: []
  property var pending: []
  property var shown: []

  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    host: QtObject {
      // Replies wait in `pending` until a test answers them.
      function spawn(argv, callback) {
        root.sent.push(argv.slice(1).join(" "))
        if (callback) root.pending.push(callback)
      }
      function copy(text) {}
      function showWindow(page) { root.shown.push(page) }
      function hideWindow() {}
    }
  }
  MainView { id: view; anchors.fill: parent; app: app }

  function show(mode) { app.applyState(JSON.stringify(Fixtures.state(mode, Fixtures.NOW))) }
  function answer(code) {
    var callbacks = root.pending
    root.pending = []
    callbacks.forEach(function(callback) { callback("", "", code) })
  }
  function find(item, test) {
    if (item.visible && test(item)) return item
    for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i], test); if (f) return f }
    return null
  }
  // A few shipped themes: light, dark, and ones whose accent is mid-grey.
  readonly property var themes: [
    "mode = \"light\"\nbackground = \"#eff1f5\"\nforeground = \"#4c4f69\"\naccent = \"#1e66f5\"\nred = \"#d20f39\"\nyellow = \"#df8e1d\"\ngreen = \"#40a02b\"",
    "background = \"#faf4ed\"\nforeground = \"#575279\"\naccent = \"#56949f\"\nred = \"#b4637a\"\nyellow = \"#ea9d34\"\ngreen = \"#286983\"",
    "background = \"#222222\"\nforeground = \"#c2c2b0\"\naccent = \"#78824b\"\nred = \"#685742\"\nyellow = \"#b36d43\"\ngreen = \"#5f875f\"",
    "background = \"#1a1b26\"\nforeground = \"#a9b1d6\"\naccent = \"#7aa2f7\"\nred = \"#f7768e\"\nyellow = \"#e0af68\"\ngreen = \"#9ece6a\""
  ]

  TestCase {
    name: "Window"
    when: windowShown

    function init() {
      root.sent = []
      root.pending = []
      root.shown = []
      show("history")
    }

    function test_words_read_on_every_fill() {
      for (var i = 0; i < root.themes.length; i++) {
        Theme.load(root.themes[i])
        var label = "theme " + i
        verify(Theme.contrast(Theme.onAccent, Theme.accent) >= 4.5, label + ": words on a primary button")
        var colours = { secondary: Theme.secondary, accentText: Theme.accentText, redText: Theme.redText,
          yellowText: Theme.yellowText, greenText: Theme.greenText }
        for (var name in colours) {
          verify(Theme.contrast(colours[name], Theme.background) >= 4.5, label + ": " + name + " on the background")
          verify(Theme.contrast(colours[name], Theme.fill18) >= 4.5, label + ": " + name + " on a selected row")
        }
        verify(Theme.contrast(Theme.secondary, Theme.fill22) >= 4.5, label + ": a shortcut on a hovered button")
      }
      // A light theme keeps its warning amber and its success green instead
      // of greying them toward its text colour.
      Theme.load(root.themes[0])
      verify(Theme.yellowText.r > Theme.yellowText.b + 0.25, "yellow stays amber: " + Theme.yellowText)
      verify(Theme.greenText.g > Theme.greenText.r + 0.15 && Theme.greenText.g > Theme.greenText.b + 0.15, "green stays green: " + Theme.greenText)
      Theme.load(root.themes[3])
    }

    function test_the_header_names_what_stopped() {
      app.binaryFound = true
      var state = Fixtures.state("history", Fixtures.NOW)
      state.published_at_ms = 1
      app.applyState(JSON.stringify(state))
      compare(app.statusText, "OmaFlow stopped")
      compare(app.statusAction, "start")
      state.phase = "recording"
      app.applyState(JSON.stringify(state))
      compare(app.phase, "idle", "a state file left mid-take does not keep recording")
    }

    function test_start_waits_while_it_runs() {
      app.connected = false
      app.start()
      compare(app.statusText, "Starting OmaFlow")
      app.start()
      compare(root.sent.filter(function(line) { return line === "launch" }).length, 1, "a second click does not start it twice")
      root.answer(1)
      compare(app.pendingAction, "")
      compare(app.statusText, "OmaFlow stopped")
      compare(view.toast, "OmaFlow did not start. Run omaflow launch in a terminal to see why.", "the failure has a next step")
    }

    function test_restart_says_so_while_it_runs() {
      show("history-stopped")
      app.restartSpeech()
      compare(app.statusText, "Restarting the speech model")
      root.answer(0)
      compare(app.statusText, "Speech model stopped")
    }

    function test_a_half_done_update_pauses_dictation_in_the_header() {
      app.updateTransaction = { state: "interrupted", blocksDictation: true, targetVersion: "0.20.0", message: "The update stopped partway through." }
      compare(app.statusText, "Dictation paused by an update")
      compare(app.statusTone, "red")
      compare(app.statusAction, "updates")
      // One that stopped before installing anything leaves dictation alone.
      app.updateTransaction = { state: "interrupted", targetVersion: "0.20.0", message: "The update stopped before it installed anything." }
      compare(app.statusText, "Ready, hold F9")
      verify(app.updateAttention)
      app.updateTransaction = ({})
    }

    function test_the_header_follows_the_model_setup() {
      show("settings-models-missing")
      compare(app.statusText, "Download the speech model")
      compare(app.statusAction, "models")
      show("settings-models-downloading")
      compare(app.statusText, "Ready, hold F9", "another model downloading does not stop dictation")
      show("history-firstdownload")
      compare(app.statusText, "Downloading the speech model", "the first model downloading is said as such")
      compare(app.statusAction, "models", "the line opens the download's progress")
      var state = Fixtures.state("history", Fixtures.NOW)
      state.phase = "recording"; state.todo_take = true
      app.applyState(JSON.stringify(state))
      compare(app.statusText, "Recording to-dos")
    }

    function test_the_update_dot_opens_the_update() {
      var brand = root.find(view, function(item) { return item.hasOwnProperty("link") && item.hasOwnProperty("hint") })
      verify(brand !== null)
      verify(!brand.link, "no dot, no link")
      app.updateOffer = { checkedAtMs: Fixtures.NOW, target: { commit: "abc123", version: "0.20.0", summary: "", changes: [] } }
      verify(brand.link)
      compare(brand.Accessible.name, "Update ready. Opens Settings, Advanced, Updates and app")
      var mark = root.find(brand, function(item) { return item.hasOwnProperty("badgeColor") })
      compare(String(mark.badgeColor), String(Theme.yellow), "a state colour, not the accent of the mark")
      mouseClick(brand)
      compare(view.page, "settings")
      compare(view.settingsPage, "updates")
      app.updateTransaction = { state: "rolled-back", targetVersion: "0.20.0", message: "The update did not finish." }
      compare(brand.Accessible.name, "An update did not finish. Opens Settings, Advanced, Updates and app")
      compare(String(mark.badgeColor), String(Theme.red))
      app.updateOffer = ({})
      app.updateTransaction = ({})
      view.show("history")
    }

    function test_the_status_never_runs_into_the_tabs() {
      show("history-stopped")
      root.width = 760
      var tabs = root.find(view, function(item) { return item.hasOwnProperty("text") && item.text === "Settings" && item.hasOwnProperty("kind") })
      var status = root.find(view, function(item) { return item.hasOwnProperty("text") && item.text === "Speech model stopped" && !item.hasOwnProperty("kind") })
      verify(tabs !== null && status !== null)
      var tabEnd = tabs.mapToItem(view, tabs.width, 0).x
      var statusStart = status.mapToItem(view, 0, 0).x
      verify(statusStart - tabEnd >= 24, "the status starts after the tabs: " + tabEnd + " < " + statusStart)
      compare(status.width, status.implicitWidth, "and keeps its words")
      root.width = 880
    }

    function test_undo_reaches_history_from_an_empty_search() {
      app.applyState(JSON.stringify(Fixtures.state("history-undo", Fixtures.NOW)))
      var search = root.find(view, function(item) { return item.hasOwnProperty("undoPressed") })
      verify(search !== null)
      root.sent = []
      search.undoPressed()
      compare(root.sent, ["history-undo"])
      compare(view.toast, "")
    }

    function editor() { return root.find(view, function(item) { return item.Accessible.name === "Dictation text, editable" }) }
    function history() { return root.find(view, function(item) { return item.hasOwnProperty("runMain") }) }

    function test_a_hidden_editor_hands_the_keys_back() {
      var field = editor()
      field.forceActiveFocus()
      history().view = "raw"
      verify(!field.activeFocus, "Raw hides the editor and takes its focus with it")
      var before = history().selectedIndex
      keyClick("j")
      compare(history().selectedIndex, before + 1, "j moves to the next dictation")
      history().select(0)
    }

    function test_tab_leaves_the_dictation_text() {
      var field = editor()
      var words = field.text
      field.forceActiveFocus()
      keyClick(Qt.Key_Tab)
      compare(field.text, words, "no tab typed into the dictation")
      verify(!field.activeFocus, "focus moves on to the actions")
      compare(root.Window.activeFocusItem.text, "Paste again")
      history().focusKeys()
    }

    function test_a_long_dictation_scrolls_to_its_actions() {
      show("history-long")
      var flick = root.find(view, function(item) { return item.hasOwnProperty("reveal") && item.hasOwnProperty("contentY") && item.width < 600 })
      verify(flick !== null)
      tryVerify(function() { return flick.contentHeight > flick.height }, 1000, "the dictation is taller than the window")
      flick.contentY = flick.contentHeight - flick.height
      var remove = root.find(flick, function(item) { return item.hasOwnProperty("kind") && item.text === "Delete" })
      var y = remove.mapToItem(flick, 0, 0).y
      verify(y >= 0 && y + remove.height <= flick.height, "Delete can be reached: " + y)
    }

    function test_dragging_in_a_long_dictation_selects_words() {
      show("history-long")
      var field = editor()
      tryVerify(function() { return field.height > 400 })
      mousePress(field, 5, 10)
      mouseMove(field, 200, 60)
      mouseMove(field, 300, 90)
      mouseRelease(field, 300, 90)
      verify(field.selectedText.length > 20, "a drag selects instead of scrolling: " + field.selectedText.length)
      field.deselect()
      history().focusKeys()
    }

    function test_cleanup_off_has_one_text() {
      show("history-cleanupoff")
      verify(root.find(view, function(item) { return item.Accessible.name === "Which text to show" }) === null, "no Cleaned, Raw and Changes for the same words")
      verify(root.find(view, function(item) { return item.hasOwnProperty("kind") && item.text === "Copy" }) !== null)
      show("history")
      verify(root.find(view, function(item) { return item.Accessible.name === "Which text to show" }) !== null)
    }

    function test_enter_in_the_search_pastes_the_match() {
      var search = root.find(view, function(item) { return item.hasOwnProperty("undoPressed") })
      search.input.forceActiveFocus()
      search.text = "Jonas"
      keyClick(Qt.Key_Return)
      tryVerify(function() { return root.sent.indexOf("history-paste 2") >= 0 }, 1000, "Enter pastes what the search found: " + root.sent)
      search.text = ""
    }

    function test_nothing_kept_while_stopped_says_to_start() {
      var state = Fixtures.state("history-stoppedempty", Fixtures.NOW)
      state.published_at_ms = 1
      app.applyState(JSON.stringify(state))
      verify(root.find(view, function(item) { return String(item.text || "").indexOf("Once OmaFlow is running, hold F9") === 0 }) !== null)
    }

    function test_settings_say_they_are_not_saved_while_stopped() {
      var state = Fixtures.state("settings-basics", Fixtures.NOW)
      state.published_at_ms = 1
      app.applyState(JSON.stringify(state))
      view.show("settings/basics")
      var line = root.find(view, function(item) { return item.text === "OmaFlow is stopped, so changes here are not saved. Start it from the top of the window." })
      verify(line !== null)
      var change = root.find(view, function(item) { return item.hasOwnProperty("kind") && item.Accessible.name === "Change the dictation keys" })
      verify(change !== null && !change.enabled, "the controls wait for OmaFlow")
      view.show("settings/updates")
      verify(root.find(view, function(item) { return item.text === line.text }) === null, "updates work without it")
      view.show("history")
    }

    function test_advanced_only_opens_its_list() {
      view.show("settings/basics")
      var advanced = root.find(view, function(item) { return item.hasOwnProperty("expander") && item.expander })
      mouseClick(advanced)
      compare(view.settingsPage, "basics", "the page you were on stays")
      verify(advanced.expanded)
      mouseClick(advanced)
      view.show("history")
    }

    function test_settings_follow_the_keyboard_below_the_fold() {
      view.show("settings/privacy")
      wait(50)
      var flick = root.find(view, function(item) { return item.hasOwnProperty("reveal") && item.hasOwnProperty("contentY") && item.width > 600 })
      var erase = root.find(view, function(item) { return item.hasOwnProperty("kind") && item.text === "Delete saved dictations…" })
      verify(flick !== null && erase !== null)
      erase.forceActiveFocus()
      var y = erase.mapToItem(flick, 0, 0).y
      verify(y >= 0 && y + erase.height <= flick.height, "the focused button is in view: " + y)
      view.show("settings/basics")
      wait(50)
      compare(flick.contentY, 0, "a new page starts at its top")
      view.show("history")
    }

    function test_a_toast_stays_while_you_reach_for_undo() {
      var state = Fixtures.state("history-undo", Fixtures.NOW)
      app.applyState(JSON.stringify(state))
      compare(view.toast, "Dictation deleted")
      var toast = null
      tryVerify(function() { toast = root.find(view, function(item) { return item.hasOwnProperty("held") }); return toast !== null })
      mouseMove(toast, toast.width / 2, toast.height / 2)
      tryVerify(function() { return toast.held })
      wait(app.noticeVisibleMs + 200)
      compare(view.toast, "Dictation deleted", "still there under the pointer")
      mouseMove(view, 10, 300)
      tryVerify(function() { return !toast.held })
      tryCompare(view, "toast", "", app.noticeVisibleMs + 1000)
    }
  }

  // The Updates page on its own, fed the states the updater writes.
  App { id: updatesApp; clockOverride: Fixtures.NOW; nowMs: Fixtures.NOW }
  SettingsUpdates { id: updates; y: 720; width: 640; app: updatesApp }

  TestCase {
    name: "Updates page"
    when: windowShown

    function init() {
      updatesApp.applyState(JSON.stringify(Fixtures.state("settings-updates", Fixtures.NOW)))
      updatesApp.updateOffer = ({})
      updatesApp.updateTransaction = ({})
    }
    function text(content) {
      return root.find(updates, function(item) { return item.hasOwnProperty("text") && String(item.text) === content && !item.hasOwnProperty("kind") })
    }
    function pill(content) {
      return root.find(updates, function(item) { return item.hasOwnProperty("kind") && item.text === content })
    }

    function test_up_to_date_says_when_it_looked() {
      updatesApp.updateOffer = { checkedAtMs: Fixtures.NOW - 60000 }
      verify(text("OmaFlow is up to date") !== null)
      var at = new Date(Fixtures.NOW - 60000)
      verify(text("Checked today at " + String(at.getHours()).padStart(2, "0") + ":" + String(at.getMinutes()).padStart(2, "0") + ".") !== null)
    }

    function test_a_failed_update_keeps_its_reason_readable() {
      updatesApp.updateOffer = { checkedAtMs: Fixtures.NOW, target: { commit: "abc123", version: "0.20.0", summary: "News.", changes: [] } }
      updatesApp.updateTransaction = { state: "needs-recovery", targetCommit: "abc123", targetVersion: "0.20.0",
        message: "The update did not finish. Your previous version could not be put back." }
      verify(text("The update to 0.20.0 did not finish") !== null, "a short headline")
      verify(text("Your previous version could not be put back. Dictation is paused until you choose Put back the previous version.") !== null, "the reason in full, and what it blocks")
      verify(pill("Put back the previous version") !== null, "the button says it brings the old version back")
      verify(pill("Try again") === null)
      // The daemon's own "Choose …" gives way to the page's one sentence.
      updatesApp.updateTransaction = { state: "needs-recovery", targetCommit: "abc123", targetVersion: "0.20.0", originalRelease: { version: "0.19.0" },
        message: "The update did not finish and 0.19.0 could not be put back, so dictation is paused. Could not restart OmaFlow. Choose Put back 0.19.0 to try again." }
      verify(text("The update did not finish and 0.19.0 could not be put back, so dictation is paused. Could not restart OmaFlow. Choose Put back 0.19.0 to dictate again.") !== null)
      // Stopped partway: the version to go back to, by name.
      updatesApp.updateTransaction = { state: "interrupted", blocksDictation: true, targetCommit: "abc123", targetVersion: "0.20.0",
        originalRelease: { version: "0.19.0" }, message: "The update stopped partway through." }
      verify(text("The update stopped partway through. Put back 0.19.0 to dictate again, then update.") !== null)
      verify(pill("Put back 0.19.0") !== null)
      // Stopped before installing anything: Try again installs, as it says.
      updatesApp.updateTransaction = { state: "interrupted", targetCommit: "abc123", targetVersion: "0.20.0",
        message: "The update stopped before it installed anything. Your current version still works. Try again to install it." }
      verify(pill("Try again") !== null)
      verify(pill("Check now") !== null, "checking again repairs an unreadable progress file")
    }

    function test_a_changed_folder_can_be_checked_again() {
      updatesApp.updateOffer = { checkedAtMs: Fixtures.NOW, externalCheckoutWarning: "The plugin folder has changes. Review them with git status before updating.",
        target: { commit: "abc123", version: "0.20.0", summary: "", changes: [] } }
      verify(pill("Check now") !== null)
      verify(text("The OmaFlow folder changed outside OmaFlow") !== null, "named as everywhere else")
      verify(text("Updates are paused. Review the changes with git, then choose Check now.") !== null, "with the next step")
    }

    function test_a_check_keeps_its_label_while_it_runs() {
      updatesApp.updateOffer = { checkedAtMs: Fixtures.NOW }
      updatesApp.updateChecking = true
      var check = pill("Check now")
      verify(check !== null && !check.enabled, "same words, and a second click waits")
      verify(text("Checking…") !== null)
      updatesApp.updateChecking = false
    }

    function test_partly_updated_shows_the_repair_without_release_notes() {
      updatesApp.updateOffer = { checkedAtMs: Fixtures.NOW, target: { commit: "abc123", version: "0.20.0", summary: "", changes: ["Reminders for to-dos with a time."] } }
      verify(text("Reminders for to-dos with a time.") !== null)
      updatesApp.stateVersion = 3
      verify(text("Reminders for to-dos with a time.") === null)
      verify(pill("Finish update") !== null, "the repair is one button")
      updatesApp.stateVersion = 4
    }
  }
}
