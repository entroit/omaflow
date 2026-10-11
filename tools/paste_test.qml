// Pasting into the window's fields: the shell never reads the clipboard
// itself, so Ctrl+V, Shift+Insert, the middle button and the right-click menu
// all ask `omaflow clipboard-text` and put in what it prints. A one-line field
// gets line breaks as spaces, a read-only field takes nothing, a selection is
// replaced, a paste is undone with Ctrl+Z, and a failure says why. And
// LineEdit, the one-line field built on TextEdit so Qt never reads the
// clipboard for it, does what TextField did: Enter accepts, a line never
// breaks, long text scrolls to the cursor, a password shows as dots and is
// never copied, and the placeholder shows while it is empty.
//   qmltestrunner -input tools/paste_test.qml (run by ui_smoke.py)
import QtQuick
import QtQuick.Controls as Controls
import QtTest
import "../ui"

Item {
  id: root
  width: 640; height: 480
  property var sent: []
  // What the next `omaflow clipboard-text` prints, and how it ends.
  property string clipboard: "pasted"
  property string primary: "chosen"
  property string failure: ""
  // Held instead of answered at once, to answer after the field has gone.
  property bool hold: false
  property var held: null
  property var toasts: []
  readonly property var fakeApp: app
  App {
    id: app
    host: QtObject {
      function spawn(argv, callback) {
        root.sent.push(argv.join(" "))
        var reply = argv.indexOf("--primary") >= 0 ? root.primary : root.clipboard
        if (root.hold) root.held = function() { callback(reply, "", 0) }
        else if (root.failure) callback("", "omaflow: " + root.failure + "\n", 1)
        else callback(reply, "", 0)
      }
      function copy(text) {}
    }
    onToast: function(message, error) { root.toasts.push((error ? "error: " : "") + message) }
  }

  property var lineEvents: []
  LineEdit {
    id: line
    width: 300; height: 36
    app: app
    placeholderText: "Type here"
    onAccepted: root.lineEvents.push("accepted")
    onEditingFinished: root.lineEvents.push("finished")
  }
  LineEdit { id: after; x: 320; width: 200; height: 36; app: app }
  // Reads back what Copy and Cut put on the clipboard; offscreen, Qt's
  // clipboard is only this process's.
  TextEdit { id: probe; x: 320; y: 60; width: 200; height: 30 }
  Controls.TextArea {
    id: area
    y: 60; width: 300; height: 120
    Keys.onPressed: function(event) { if (areaPaste.key(event)) return }
    Controls.ContextMenu.menu: null
    Controls.ContextMenu.onRequested: function(at) { areaPaste.openMenu(at) }
    PasteGuard { id: areaPaste; app: app }
  }
  TextEdit {
    id: plain
    y: 200; width: 300; height: 60
    Keys.onPressed: function(event) { if (plainPaste.key(event)) return }
    PasteGuard { id: plainPaste; app: app; offersMenu: false }
  }
  Field { id: field; y: 280; width: 300; app: app; maximumLength: 10 }
  SearchField { id: search; y: 360; width: 300; app: app }
  property var rowEnded: []
  TodoRow {
    id: todoRow
    y: 420; width: 600
    app: app
    todo: ({ index: 0, text: "Buy milk", done: false })
    onSaveRequested: function(text) { root.rowEnded.push("save " + text) }
    onCancelRequested: root.rowEnded.push("cancel")
  }
  Component {
    id: doomed
    Controls.TextArea {
      width: 200; height: 40
      Keys.onPressed: function(event) { if (doomedPaste.key(event)) return }
      // Inside a component, a bare `app` would name the guard's own.
      PasteGuard { id: doomedPaste; app: root.fakeApp }
    }
  }

  // The text item itself: a LineEdit's TextEdit, or the field.
  function editorOf(f) { return f.editor || f }
  // The cursor, where it is drawn in F.
  function cursorX(f) { var r = f.editor.cursorRectangle; return f.editor.mapToItem(f, r.x, r.y).x }
  // Its one pixel in view: at the end of a long line it stands at the edge,
  // as in TextInput.
  function shown(f) { var x = cursorX(f); return x >= f.leftPadding && x < f.width - f.rightPadding + 1 }
  // A LineEdit's dots.
  function dots(f) {
    for (var i = 0; i < f.editor.children.length; i++) if (f.editor.children[i].text !== undefined) return f.editor.children[i]
    return null
  }
  function placeholderOf(f) {
    for (var i = 0; i < f.children.length; i++) if (f.children[i].text === f.placeholderText) return f.children[i]
    return null
  }

  // The open text menu's panel, if any: it lives over the whole window.
  function openPanel() {
    function find(item) {
      if (item.Accessible.role === Accessible.PopupMenu && item.visible && item.Accessible.name === "Edit text") return item
      for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i]); if (f) return f }
      return null
    }
    return find(root.Window.window.contentItem)
  }
  function offered() {
    var panel = openPanel()
    return panel ? panel.parent.items.filter(function(i) { return i.label }).map(function(i) { return i.label }) : []
  }
  function choice(label) {
    function find(item) {
      if (item.Accessible.role === Accessible.MenuItem && item.Accessible.name === label && item.visible) return item
      for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i]); if (f) return f }
      return null
    }
    return find(root.Window.window.contentItem)
  }

  TestCase {
    name: "Paste"
    when: windowShown

    // Right-click F at X, Y, and wait for the menu to be laid out and to
    // have the keyboard.
    function rightClick(f, x, y) {
      mouseClick(f, x, y, Qt.RightButton)
      tryVerify(function() { return root.openPanel() !== null && !f.activeFocus })
      waitForRendering(root)
    }

    function init() {
      root.rowEnded = []
      root.sent = []; root.toasts = []; root.failure = ""; root.hold = false; root.held = null
      root.clipboard = "pasted"; root.primary = "chosen"
      for (var f of [line, area, plain]) { editorOf(f).readOnly = false; f.text = "" }
      field.text = ""; search.text = ""
      line.password = false; line.maximumLength = 32767; root.lineEvents = []
      var panel = root.openPanel()
      if (panel) panel.parent.open = false
    }

    function test_ctrl_v_asks_the_command_and_inserts_at_the_cursor() {
      line.text = "ab"
      line.forceActiveFocus()
      line.cursorPosition = 1
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(root.sent, ["omaflow clipboard-text"])
      compare(line.text, "apastedb")
      compare(line.cursorPosition, 7)
    }

    function test_shift_insert_pastes_the_same_way() {
      area.forceActiveFocus()
      keyClick(Qt.Key_Insert, Qt.ShiftModifier)
      compare(root.sent, ["omaflow clipboard-text"])
      compare(area.text, "pasted")
    }

    function test_a_paste_replaces_the_selection_and_undoes() {
      for (var f of [line, area]) {
        f.text = "keep this"
        f.forceActiveFocus()
        f.select(5, 9)
        keyClick(Qt.Key_V, Qt.ControlModifier)
        compare(f.text, "keep pasted", f)
        compare(f.selectedText, "", f)
        compare(f.cursorPosition, 11, f)
        // A TextEdit keeps the removal and the insert as two steps, as QML
        // gives it no way to group them.
        f.undo()
        compare(f.text, "keep ", f)
        f.undo()
        compare(f.text, "keep this", f)
      }
    }

    function test_a_single_line_field_gets_spaces_for_line_breaks() {
      root.clipboard = "one\ntwo\r\nthree\rfour"
      line.forceActiveFocus()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(line.text, "one two three four")
      verify(!areaPaste.singleLine)
      area.forceActiveFocus()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(area.text, "one\ntwo\nthree\nfour")
      compare(area.lineCount, 4)
      // A to-do is one line in its file, so its editor says so.
      plainPaste.singleLine = true
      plain.forceActiveFocus()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(plain.text, "one two three four")
      plainPaste.singleLine = false
    }

    function test_text_is_not_read_as_markup() {
      root.clipboard = "<b>bold</b> &amp;"
      area.forceActiveFocus()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(area.text, "<b>bold</b> &amp;")
    }

    function test_a_read_only_field_takes_nothing() {
      for (var f of [line, area, plain]) {
        f.text = "fixed"
        editorOf(f).readOnly = true
        f.forceActiveFocus()
        keyClick(Qt.Key_V, Qt.ControlModifier)
        mouseClick(f, 10, 10, Qt.MiddleButton)
        mouseClick(f, 1, 10, Qt.MiddleButton)
        compare(f.text, "fixed", f)
      }
      compare(root.sent, [])
    }

    function test_the_field_limit_still_holds() {
      root.clipboard = "a long pasted line"
      field.input.forceActiveFocus()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(field.text, "a long pas")
    }

    function test_the_middle_button_pastes_the_primary_selection_where_it_is_pressed() {
      line.text = "abcdef"
      line.cursorPosition = 6
      var x = line.editor.positionToRectangle(3).x + 1
      mouseClick(line.editor, x, line.height / 2, Qt.MiddleButton)
      compare(root.sent, ["omaflow clipboard-text --primary"])
      compare(line.text, "abcchosendef")
      verify(line.activeFocus)
      // Beside the text, in the padding, too: at the start.
      mouseClick(line, 1, line.height / 2, Qt.MiddleButton)
      compare(line.text, "chosenabcchosendef")
      area.text = "first\nsecond"
      var at = area.positionToRectangle(6)
      mouseClick(area, at.x + 1, at.y + at.height / 2, Qt.MiddleButton)
      compare(area.text, "first\nchosensecond")
      mouseClick(plain, 5, 5, Qt.MiddleButton)
      compare(plain.text, "chosen")
    }

    function test_the_left_button_still_reaches_the_field() {
      line.text = "abcdef"
      line.cursorPosition = 0
      mouseClick(line.editor, line.editor.positionToRectangle(4).x + 1, line.height / 2, Qt.LeftButton)
      verify(line.activeFocus)
      compare(line.cursorPosition, 4)
      mouseDoubleClickSequence(line.editor, line.editor.positionToRectangle(2).x + 1, line.height / 2, Qt.LeftButton)
      compare(line.selectedText, "abcdef")
      // The padding is the field too.
      line.focus = false
      mouseClick(line, line.width - 1, line.height / 2, Qt.LeftButton)
      verify(line.activeFocus)
      compare(line.cursorPosition, 6)
      compare(root.sent, [])
    }

    function test_a_failure_says_why() {
      root.failure = "the clipboard holds too much text to paste"
      line.text = "ab"
      line.forceActiveFocus()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(line.text, "ab")
      compare(root.toasts, ["error: The clipboard holds too much text to paste."])
    }

    function test_a_field_gone_before_the_answer_takes_nothing() {
      var gone = doomed.createObject(root, { y: 420 })
      gone.forceActiveFocus()
      root.hold = true
      keyClick(Qt.Key_V, Qt.ControlModifier)
      verify(root.held !== null)
      gone.destroy()
      wait(0)
      root.held()
      compare(root.toasts, [])
    }

    function test_right_click_opens_the_menu_which_pastes_through_the_command() {
      line.text = "keep this"
      line.forceActiveFocus()
      line.select(5, 9)
      rightClick(line, 20, line.height / 2)
      compare(root.offered(), ["Cut", "Copy", "Paste", "Select all"])
      // At the pointer.
      var panel = root.openPanel()
      var corner = line.mapToItem(panel.parent, 20, line.height / 2)
      compare(panel.x, corner.x)
      compare(panel.y, corner.y)
      mouseClick(root.choice("Paste"))
      compare(root.sent, ["omaflow clipboard-text"])
      compare(line.text, "keep pasted")
      verify(line.activeFocus)
      verify(!line.menuOpen)
    }

    function test_the_menu_cuts_copies_and_selects_all() {
      area.text = "one two"
      area.forceActiveFocus()
      area.select(4, 7)
      // The menu has the keyboard; the selection waits for it.
      rightClick(area, 10, 10)
      verify(areaPaste.menuOpen)
      mouseClick(root.choice("Cut"))
      compare(area.text, "one ")
      rightClick(area, 10, 10)
      compare(root.offered(), ["Paste", "Select all"])
      mouseClick(root.choice("Select all"))
      compare(area.selectedText, "one ")
      // Esc closes it and keeps the selection.
      rightClick(area, 10, 10)
      keyClick(Qt.Key_Escape)
      verify(!areaPaste.menuOpen)
      verify(area.activeFocus)
      compare(area.selectedText, "one ")
      compare(root.sent, [])
    }

    function test_a_read_only_menu_only_copies_and_selects() {
      line.text = "fixed"
      line.editor.readOnly = true
      line.forceActiveFocus()
      line.select(0, 3)
      rightClick(line, 10, line.height / 2)
      compare(root.offered(), ["Copy", "Select all"])
      keyClick(Qt.Key_Escape)
    }

    function test_a_password_is_not_offered_to_cut_or_copy() {
      field.password = true
      field.text = "secret"
      field.input.forceActiveFocus()
      field.input.selectAll()
      rightClick(field.input, 10, 10)
      compare(root.offered(), ["Paste", "Select all"])
      keyClick(Qt.Key_Escape)
      field.password = false
    }


    function test_a_to_do_being_edited_stays_open_under_its_menu() {
      todoRow.editing = true
      function find(item) {
        if (item.Accessible.name === "Edit “Buy milk”") return item
        for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i]); if (f) return f }
        return null
      }
      var editor = find(todoRow)
      verify(editor !== null)
      tryVerify(function() { return editor.activeFocus })
      rightClick(editor, 20, 10)
      mouseClick(root.choice("Paste"))
      compare(editor.text, "Buy milkpasted")
      verify(editor.activeFocus)
      compare(root.rowEnded, [])
      keyClick(Qt.Key_Escape)
      compare(root.rowEnded, ["cancel"])
      todoRow.editing = false
    }

    function test_the_shared_fields_paste_through_the_command() {
      search.input.forceActiveFocus()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(search.text, "pasted")
      field.input.forceActiveFocus()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(field.text, "pasted")
      compare(root.sent, ["omaflow clipboard-text", "omaflow clipboard-text"])
    }

    // ------------------------------------------------------------- LineEdit
    function test_enter_accepts_and_never_breaks_the_line() {
      line.text = "ab"
      line.forceActiveFocus()
      keyClick(Qt.Key_Return)
      keyClick(Qt.Key_Enter)
      keyClick(Qt.Key_Return, Qt.ShiftModifier)
      compare(line.text, "ab")
      compare(root.lineEvents, ["accepted", "finished", "accepted", "finished", "accepted", "finished"])
      // Set from outside, a line break is a space, and the cursor goes to
      // the end, as in TextInput, so typing adds to it.
      line.text = "one\ntwo\r\nthree\u2028four"
      compare(line.text, "one two three four")
      compare(line.cursorPosition, line.text.length)
      keyClick(Qt.Key_X)
      compare(line.text, "one two three fourx")
      compare(line.editor.lineCount, 1)
    }

    function test_tab_moves_on_instead_of_typing_a_tab() {
      line.text = "ab"
      line.forceActiveFocus()
      keyClick(Qt.Key_Tab)
      compare(line.text, "ab")
      verify(after.activeFocus, "the next field")
      keyClick(Qt.Key_Backtab, Qt.ShiftModifier)
      verify(line.activeFocus)
      compare(root.lineEvents, ["finished"], "leaving the field finishes the edit")
    }

    function test_long_text_scrolls_to_keep_the_cursor_in_view() {
      line.text = "The quick brown fox jumps over the lazy dog and then keeps on running for a while"
      verify(line.editor.contentWidth > line.width * 1.5)
      line.forceActiveFocus()
      verify(shown(line), "at the end")
      keyClick(Qt.Key_Home)
      compare(line.cursorPosition, 0)
      verify(shown(line), "back at the start")
      compare(cursorX(line), line.leftPadding)
      keyClick(Qt.Key_End)
      verify(shown(line), "at the end again")
      for (var i = 0; i < 30; i++) keyClick(Qt.Key_Left)
      verify(shown(line), "moving left")
      for (i = 0; i < 30; i++) keyClick(Qt.Key_Right, Qt.ShiftModifier)
      verify(shown(line), "selecting right")
      compare(line.selectedText.length, 30)
      // A drag past the edge selects on, scrolling with it.
      keyClick(Qt.Key_Home)
      var y = line.height / 2
      mousePress(line.editor, 10, y)
      for (var x = 40; x <= line.width + 120; x += 40) mouseMove(line, x, y)
      mouseRelease(line, line.width + 120, y)
      verify(line.selectedText.length > 40, line.selectedText)
      verify(shown(line), "the drag keeps the cursor in view")
      // Text past the padding is cut off there, as TextInput does.
      verify(line.editor.parent.clip)
      compare(line.editor.parent.x, line.leftPadding)
      // Deleting from the end leaves no gap after it.
      keyClick(Qt.Key_End)
      keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace)
      verify(cursorX(line) >= line.width - line.rightPadding - 1 && shown(line))
    }

    function test_the_placeholder_shows_while_empty() {
      var hint = placeholderOf(line)
      verify(hint !== null)
      verify(hint.visible)
      compare(String(hint.color), String(Theme.secondary))
      compare(hint.x, line.leftPadding)
      line.text = "a"
      verify(!hint.visible)
      line.text = ""
      line.forceActiveFocus()
      verify(hint.visible, "and while focused")
    }

    function test_the_length_limit_holds_when_typing() {
      line.maximumLength = 3
      line.forceActiveFocus()
      for (var k of [Qt.Key_A, Qt.Key_B, Qt.Key_C, Qt.Key_D, Qt.Key_E]) keyClick(k)
      compare(line.text, "abc")
      line.selectAll()
      keyClick(Qt.Key_X)
      compare(line.text, "x", "a selection makes room")
      line.text = "abcdef"
      compare(line.text, "abc", "set from outside too")
    }

    function test_a_password_shows_dots_and_is_never_copied() {
      probe.text = "before"
      probe.selectAll()
      probe.copy()
      line.password = true
      line.forceActiveFocus()
      for (var k of [Qt.Key_S, Qt.Key_E, Qt.Key_C, Qt.Key_R, Qt.Key_E, Qt.Key_T]) keyClick(k)
      compare(line.text, "secret")
      // The real letters are drawn in no colour, selected or not; dots in
      // the text colour stand over them, one per letter.
      compare(line.editor.color.a, 0)
      compare(line.editor.selectedTextColor.a, 0)
      var mask = dots(line)
      compare(mask.text, "••••••")
      verify(mask.visible)
      compare(mask.color, line.color)
      compare(mask.font.family, line.editor.font.family)
      // Monospaced, so each dot sits on its letter, where the cursor and the
      // selection are.
      var advance = mask.contentWidth / 6
      for (var i = 0; i <= 6; i++) fuzzyCompare(line.editor.positionToRectangle(i).x, i * advance, 0.5)
      // The cursor is drawn though the text is not.
      verify(line.editor.cursorDelegate !== null)
      // Copy and Cut do nothing, by key or menu.
      line.selectAll()
      keyClick(Qt.Key_C, Qt.ControlModifier)
      keyClick(Qt.Key_X, Qt.ControlModifier)
      keyClick(Qt.Key_Insert, Qt.ControlModifier)
      keyClick(Qt.Key_Delete, Qt.ShiftModifier)
      compare(line.text, "secret")
      rightClick(line, 20, line.height / 2)
      compare(root.offered(), ["Paste", "Select all"])
      keyClick(Qt.Key_Escape)
      probe.text = ""
      probe.paste()
      compare(probe.text, "before", "the clipboard is as it was")
      // The keyboard still selects, by letter, and a word is the whole
      // password so the dots give nothing away.
      line.cursorPosition = 6
      keyClick(Qt.Key_Left, Qt.ShiftModifier)
      keyClick(Qt.Key_Left, Qt.ShiftModifier)
      compare(line.selectedText, "et")
      keyClick(Qt.Key_Left, Qt.ShiftModifier | Qt.ControlModifier)
      compare(line.selectedText, "secret")
      compare(line.cursorPosition, 0)
      keyClick(Qt.Key_Right, Qt.ControlModifier)
      compare(line.cursorPosition, 6)
      keyClick(Qt.Key_Backspace, Qt.ControlModifier)
      compare(line.text, "")
      // A mouse drag selects.
      line.text = "abcdef"
      var y = line.height / 2
      mousePress(line.editor, line.editor.positionToRectangle(1).x + 1, y)
      mouseMove(line.editor, line.editor.positionToRectangle(4).x + 1, y)
      mouseRelease(line.editor, line.editor.positionToRectangle(4).x + 1, y)
      compare(line.selectedText, "bcd")
      // A screen reader hears dots, not the password.
      verify(line.editor.Accessible.ignored)
      compare(mask.Accessible.role, Accessible.EditableText)
      verify(mask.Accessible.passwordEdit)
      // Pasting still works, through the guard.
      line.selectAll()
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(line.text, "pasted")
      compare(mask.text, "••••••")
      compare(root.sent, ["omaflow clipboard-text"])
      line.password = false
      verify(!mask.visible)
      compare(line.editor.color, line.color)
    }

    function test_search_keys_reach_the_search() {
      var seen = []
      function note(what) { return function() { seen.push(what) } }
      search.down.connect(note("down")); search.up.connect(note("up")); search.escaped.connect(note("escaped"))
      search.undoPressed.connect(note("undo")); search.accepted.connect(note("accepted"))
      search.input.forceActiveFocus()
      keyClick(Qt.Key_A)
      keyClick(Qt.Key_Down); keyClick(Qt.Key_Up)
      keyClick(Qt.Key_Z, Qt.ControlModifier)
      compare(search.text, "", "Ctrl+Z undoes the typing first")
      keyClick(Qt.Key_Z, Qt.ControlModifier)
      keyClick(Qt.Key_Return)
      keyClick(Qt.Key_B)
      keyClick(Qt.Key_Escape)
      compare(search.text, "", "Esc clears first")
      keyClick(Qt.Key_Escape)
      compare(seen, ["down", "up", "undo", "accepted", "escaped"])
      verify(!search.input.activeFocus)
    }
  }
}
