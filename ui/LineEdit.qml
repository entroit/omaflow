import QtQuick

// One line to type in, which Field, SearchField and the other one-line
// fields are built on. It is a TextEdit, never a TextInput or TextField: in
// Qt 6.11 and 6.12 an editable TextInput reads the whole clipboard on every
// change, pasting or not, to decide whether it could paste, and that read
// has no size or time limit (see PasteGuard.qml). TextEdit only checks the
// formats. So this does what TextInput did for itself: Enter accepts instead
// of breaking the line, long text scrolls sideways to keep the cursor in
// view, and a password shows as dots.
FocusScope {
  id: line

  required property var app
  property alias text: edit.text
  property string placeholderText: ""
  property color placeholderTextColor: Theme.secondary
  property color color: Theme.text
  property color selectionColor: Theme.alpha(Theme.accent, 0.4)
  property color selectedTextColor: Theme.text
  property font font: Qt.font({ family: Theme.sans, pixelSize: 13 })
  // As a Controls TextField has them.
  property real padding: 4
  property real leftPadding: padding
  property real rightPadding: padding
  property real topPadding: padding
  property real bottomPadding: padding
  property int verticalAlignment: TextEdit.AlignVCenter
  property int maximumLength: 32767
  property bool selectByMouse: true
  // Dots in a monospace font, so each sits on its letter for the cursor and
  // the selection. Never cut, copied, put in the primary selection or read
  // out to a screen reader.
  property bool password: false
  // Behind the field, filling it.
  property Item background: null
  readonly property alias length: edit.length
  property alias cursorPosition: edit.cursorPosition
  readonly property alias selectionStart: edit.selectionStart
  readonly property alias selectionEnd: edit.selectionEnd
  readonly property alias selectedText: edit.selectedText
  readonly property alias canUndo: edit.canUndo
  // A field that ends its edit when it loses the keyboard waits while its
  // right-click menu has it.
  readonly property bool menuOpen: paste.menuOpen
  // The text item itself, for tests.
  readonly property alias editor: edit
  // Enter, as TextInput has it; and Enter or leaving the field.
  signal accepted()
  signal editingFinished()

  function selectAll() { edit.selectAll() }
  function select(start, end) { edit.select(start, end) }
  function deselect() { edit.deselect() }
  function undo() { edit.undo() }

  implicitWidth: background && background.implicitWidth > 0 ? background.implicitWidth
    : Math.max(edit.contentWidth, placeholder.implicitWidth) + leftPadding + rightPadding
  implicitHeight: Math.max(background ? background.implicitHeight : 0,
                           edit.contentHeight + topPadding + bottomPadding,
                           placeholder.implicitHeight + topPadding + bottomPadding)
  Accessible.ignored: true

  onBackgroundChanged: if (background) {
    background.parent = line
    background.z = -1
    background.anchors.fill = line
  }

  // A press beside the text, in the padding, as one on it.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.IBeamCursor
    onPressed: function(mouse) {
      var at = mapToItem(edit, mouse.x, mouse.y)
      if (mouse.button === Qt.LeftButton) line.pressAt(at.x, at.y, mouse.modifiers)
      else paste.press(mouse.button, at.x, at.y)
    }
    onPositionChanged: function(mouse) {
      if (pressedButtons & Qt.LeftButton) { var at = mapToItem(edit, mouse.x, mouse.y); line.dragTo(at.x, at.y) }
    }
    onDoubleClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) { var at = mapToItem(edit, mouse.x, mouse.y); line.doubleAt(at.x, at.y) }
    }
    onReleased: function(mouse) { if (mouse.button === Qt.MiddleButton) paste.paste(true) }
  }

  Text {
    id: placeholder
    x: line.leftPadding
    y: line.topPadding
    width: line.width - line.leftPadding - line.rightPadding
    height: line.height - line.topPadding - line.bottomPadding
    visible: edit.length === 0 && edit.preeditText.length === 0
    text: line.placeholderText
    font: line.font
    color: line.placeholderTextColor
    verticalAlignment: line.verticalAlignment
    elide: Text.ElideRight
    textFormat: Text.PlainText
    renderType: edit.renderType
  }

  // The text, cut off at the padding as TextInput does, and scrolled. One
  // pixel more on the right for the cursor at the end.
  Item {
    id: view
    readonly property real area: Math.max(0, line.width - line.leftPadding - line.rightPadding)
    x: line.leftPadding
    width: area + 1
    height: line.height
    clip: true
    property int scroll: 0
    onAreaChanged: follow()

    // As TextInput scrolls: no further than keeps the cursor in view, and
    // no gap after the end of a long line.
    function follow() {
      var at = edit.cursorRectangle.x
      var used = Math.max(edit.contentWidth, at)
      var to = scroll
      if (used <= area) to = 0
      else if (at - to >= area) to = at - area
      else if (at < to) to = at
      else if (used - to < area) to = used - area
      scroll = Math.trunc(to)
    }

    TextEdit {
      id: edit
      x: -view.scroll
      width: Math.max(view.width, contentWidth)
      height: view.height
      topPadding: line.topPadding
      bottomPadding: line.bottomPadding
      focus: true
      activeFocusOnTab: true
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.NoWrap
      verticalAlignment: line.verticalAlignment
      font: line.password ? Qt.font({ family: Theme.mono, pixelSize: line.font.pixelSize }) : line.font
      color: line.password ? "transparent" : line.color
      selectionColor: line.selectionColor
      selectedTextColor: line.password ? "transparent" : line.selectedTextColor
      // TextEdit's own cursor is drawn in the text colour, which a password
      // hides.
      cursorDelegate: line.password ? maskCursor : null
      selectByMouse: line.selectByMouse && !line.password
      // What TextInput tells an input method about a password.
      inputMethodHints: line.password ? Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhSensitiveData : Qt.ImhNone
      // For PasteGuard.
      readonly property bool masked: line.password
      readonly property int maximumLength: line.maximumLength

      onCursorRectangleChanged: view.follow()
      onContentWidthChanged: view.follow()
      onTextChanged: line.tidy()
      Component.onCompleted: if (!canUndo && cursorPosition === 0 && selectionEnd === 0) cursorPosition = length
      onActiveFocusChanged: if (!activeFocus) line.editingFinished()
      // Keys on a LineEdit see a key before the text does, as on a
      // TextField. One neither takes passes them again on its way up.
      Keys.forwardTo: [line]
      Keys.onPressed: function(event) { line.key(event) }

      Accessible.name: line.Accessible.name
      Accessible.description: line.Accessible.description
      // A screen reader would read out the real text: the dots stand in.
      Accessible.ignored: line.password

      // Pasted through PasteGuard, never read from the clipboard by Qt.
      PasteGuard { id: paste; app: line.app; singleLine: true }

      // A password is selected here rather than by TextEdit, which would put
      // the selection in the primary selection for any app to paste.
      MouseArea {
        anchors.fill: parent
        z: 5
        enabled: line.password
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.IBeamCursor
        onPressed: function(mouse) { line.pressAt(mouse.x, mouse.y, mouse.modifiers) }
        onPositionChanged: function(mouse) { line.dragTo(mouse.x, mouse.y) }
        onDoubleClicked: function(mouse) { line.doubleAt(mouse.x, mouse.y) }
      }

      Text {
        visible: line.password
        height: parent.height
        topPadding: edit.topPadding
        bottomPadding: edit.bottomPadding
        verticalAlignment: edit.verticalAlignment
        font: edit.font
        color: line.color
        renderType: edit.renderType
        textFormat: Text.PlainText
        text: "•".repeat(edit.length + edit.preeditText.length)
        Accessible.ignored: !line.password
        Accessible.role: Accessible.EditableText
        Accessible.name: line.Accessible.name
        Accessible.description: line.Accessible.description
        Accessible.passwordEdit: true
        Accessible.focusable: true
        Accessible.focused: edit.activeFocus
      }
    }
  }

  Component {
    id: maskCursor
    Item {
      width: 1
      Rectangle { anchors.fill: parent; color: line.color; visible: edit.cursorVisible && blink.on }
    }
  }
  Timer {
    id: blink
    property bool on: true
    interval: Math.max(1, Qt.styleHints.cursorFlashTime / 2)
    repeat: true
    running: line.password && edit.cursorVisible && edit.activeFocus && Qt.styleHints.cursorFlashTime > 0
    onTriggered: on = !on
    onRunningChanged: on = true
  }
  Connections {
    target: edit
    enabled: line.password
    function onCursorPositionChanged() { blink.on = true; if (blink.running) blink.restart() }
  }

  // ------------------------------------------------------------------ keys
  property int anchorAt: 0
  function anchor() { return edit.cursorPosition === edit.selectionStart ? edit.selectionEnd : edit.selectionStart }

  function key(event) {
    if (paste.key(event)) return
    var control = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      line.accepted()
      line.editingFinished()
      return
    }
    // Tab moves on, as in TextInput, rather than typing a tab.
    if ((event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) && !control) {
      event.accepted = true
      var forward = event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)
      var next = edit.nextItemInFocusChain(forward)
      if (next && next !== edit) next.forceActiveFocus(forward ? Qt.TabFocusReason : Qt.BacktabFocusReason)
      return
    }
    var typed = event.text.length > 0 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
      && !(control && !(event.modifiers & Qt.AltModifier))
    if (typed && edit.length - (edit.selectionEnd - edit.selectionStart) >= maximumLength) {
      event.accepted = true
      return
    }
    if (password) passwordKey(event)
  }

  // Every key that would select, copy or cut, handled here instead. A word
  // is the whole password, as TextInput has it, so the dots give nothing
  // away.
  function passwordKey(event) {
    var at = edit.cursorPosition, end = edit.length
    var selected = edit.selectionEnd > edit.selectionStart
    function matches(keys) { return keys.some(function(k) { return event.matches(k) }) }
    var to = -1, keep = false
    if (matches([StandardKey.Copy, StandardKey.Cut, StandardKey.SelectNextLine, StandardKey.SelectPreviousLine,
                 StandardKey.SelectNextPage, StandardKey.SelectPreviousPage])
        || event.key === Qt.Key_Direction_L || event.key === Qt.Key_Direction_R) {
      // Nothing.
    } else if (event.matches(StandardKey.SelectAll)) {
      edit.selectAll()
    } else if (event.matches(StandardKey.SelectNextChar)) {
      to = Math.min(end, at + 1); keep = true
    } else if (event.matches(StandardKey.SelectPreviousChar)) {
      to = Math.max(0, at - 1); keep = true
    } else if (matches([StandardKey.SelectNextWord, StandardKey.SelectEndOfLine, StandardKey.SelectEndOfBlock, StandardKey.SelectEndOfDocument])) {
      to = end; keep = true
    } else if (matches([StandardKey.SelectPreviousWord, StandardKey.SelectStartOfLine, StandardKey.SelectStartOfBlock, StandardKey.SelectStartOfDocument])) {
      to = 0; keep = true
    } else if (event.matches(StandardKey.MoveToNextWord)) {
      to = end
    } else if (event.matches(StandardKey.MoveToPreviousWord)) {
      to = 0
    } else if (event.matches(StandardKey.DeleteEndOfWord)) {
      if (selected) edit.remove(edit.selectionStart, edit.selectionEnd)
      else edit.remove(at, end)
    } else if (event.matches(StandardKey.DeleteStartOfWord)) {
      if (selected) edit.remove(edit.selectionStart, edit.selectionEnd)
      else edit.remove(0, at)
    } else {
      // Undo with a selection would keep it, and TextEdit hands a kept
      // selection to the primary selection.
      if (selected && (event.matches(StandardKey.Undo) || event.matches(StandardKey.Redo))) edit.cursorPosition = at
      return
    }
    event.accepted = true
    if (to < 0) return
    if (keep) edit.select(anchor(), to)
    else edit.cursorPosition = to
  }

  // ----------------------------------------------------------------- mouse
  // At X, Y in the text: in the padding, or anywhere for a password.
  function pressAt(x, y, modifiers) {
    var at = edit.positionAt(x, y)
    edit.forceActiveFocus()
    if ((modifiers & Qt.ShiftModifier) && selectByMouse) edit.select(anchor(), at)
    else { edit.cursorPosition = at; anchorAt = at }
  }
  function dragTo(x, y) {
    if (selectByMouse) edit.select(anchorAt, edit.positionAt(x, y))
  }
  function doubleAt(x, y) {
    if (!selectByMouse) return
    if (password) { edit.selectAll(); return }
    edit.cursorPosition = edit.positionAt(x, y)
    edit.selectWord()
  }

  // ------------------------------------------------------------------ text
  // One line, however it came: set from outside, or an input method's line
  // break. Set from outside, the cursor goes to the end, as in TextInput, so
  // typing adds to it.
  property bool tidying: false
  function tidy() {
    if (tidying) return
    tidying = true
    var set = !edit.canUndo
    var breaks = /\r\n|[\r\n\u2028\u2029]/
    if (set) {
      var whole = edit.text.replace(/\r\n|[\r\n\u2028\u2029]/g, " ").slice(0, maximumLength)
      if (whole !== edit.text) edit.text = whole
      if (edit.length > 0) edit.cursorPosition = edit.length
    } else {
      for (var found = breaks.exec(edit.text); found; found = breaks.exec(edit.text)) {
        edit.remove(found.index, found.index + found[0].length)
        edit.insert(found.index, " ")
      }
      var over = edit.length - maximumLength
      if (over > 0) {
        var at = edit.cursorPosition
        if (at >= over) edit.remove(at - over, at)
        else edit.remove(maximumLength, edit.length)
      }
    }
    tidying = false
  }
}
