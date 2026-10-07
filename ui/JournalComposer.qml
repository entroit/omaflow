import QtQuick
import QtQuick.Controls as Controls
import "Dates.js" as Dates

// The bottom of a journal day, and of the to-do list: talk or type. A spoken
// take records with the same card as any dictation; here, Talk turns into
// Stop while you speak.
Item {
  id: composer

  required property var app
  property bool canWrite: true
  // A later day: what is said or typed here is a note for that day.
  property string laterDay: ""
  // A past day: what is said or typed here is added to that day.
  property string pastDay: ""
  readonly property string targetDay: laterDay || pastDay
  // On the to-do page: what is said or typed becomes to-dos.
  property bool todo: false
  // To-dos: where Talk sends them, { list, due }, and the words that say so.
  property var todoTarget: null
  property string placeholder: ""
  // To-dos: what the field says while you talk, such as where they go.
  property string listeningText: "Name one thing after another."
  property string hintText: ""
  // What the button beside typed words says, like "Add to Infra".
  property string addLabel: todo ? "Add" : "Save"
  readonly property string shortcut: todo ? app.todoShortcut : app.journalShortcut
  function toggle(laterDay) {
    if (todo) app.todoToggle(talking ? null : todoTarget)
    else app.journalToggle(laterDay)
  }
  signal typed(string text)
  // Ctrl+Z in the field with nothing of its own to undo: the page's Undo,
  // such as for an entry or a to-do just deleted.
  signal undoPressed()

  readonly property bool mine: todo ? app.todoTake : app.journalTake
  readonly property bool talking: app.phase === "recording" && mine
  readonly property bool writing: app.phase === "processing" && mine
  function focusInput() { input.forceActiveFocus() }
  Component { id: micIcon; Icon { name: "mic"; size: 15; color: Theme.onAccent } }
  function clearInput() { input.text = "" }
  function setText(text) { input.text = text; input.cursorPosition = input.length }

  // One line high, growing with each new line up to about six.
  implicitHeight: Math.max(50, Math.min(input.implicitHeight, 160) + 8)

  // ------------------------------------------------------------ talk or type
  Shadowed {
    anchors.fill: parent
    radius: 25
    color: Theme.fill4
    shadowOpacity: 0.35

    Pill {
      id: talk
      anchors.left: parent.left
      anchors.leftMargin: 7
      // Stays on the last line as the words grow.
      anchors.bottom: parent.bottom
      anchors.bottomMargin: (50 - height) / 2
      kind: "primary"
      text: composer.talking && pressed && startedHere ? (composer.todo ? "Let go to add" : "Let go to save")
        : composer.talking ? "Stop" : composer.writing ? (composer.todo ? "Adding" : "Writing") : "Talk"
      size: 13
      horizontalPadding: 14
      verticalPadding: 8
      leading: composer.talking || composer.writing ? null : micIcon
      hint: composer.talking ? (composer.todo ? "Stop and add the to-dos" : "Stop and save the entry")
        : composer.todo ? "Click to talk hands-free, or hold while you list them and let go to add"
        : "Click to talk hands-free, or hold while you talk and let go to save"
      // Its own press stays enabled while the entry starts: the state arrives
      // a field at a time, and a disabled button would drop the hold.
      enabled: startedHere || (composer.canWrite && composer.app.connected && !composer.writing
        && (composer.talking || composer.app.phase !== "recording"))
      // Click: a hands-free entry, saved with Stop. Hold: talk while it is
      // down, and letting go saves it, like the dictation key.
      property real downAt: 0
      property bool startedHere: false
      onPressedChanged: {
        if (pressed && !composer.talking && !composer.writing) {
          startedHere = true
          downAt = Date.now()
          composer.toggle(composer.targetDay)
        } else if (!pressed && startedHere) {
          // Held: letting go saves.
          if (Date.now() - downAt >= 400) composer.toggle("")
          // The click that follows this release belongs to the press that
          // started the entry; forget it after, even if the pointer left.
          Qt.callLater(function() { talk.startedHere = false })
        }
      }
      onClicked: if (!startedHere) composer.toggle(composer.talking ? "" : composer.targetDay)
    }

    // Enter saves; Shift+Enter starts a new line, a paragraph in the
    // journal and another to-do on the to-do page.
    Controls.ScrollView {
      id: scroller
      anchors.left: talk.right
      anchors.leftMargin: 8
      anchors.right: trailing.left
      anchors.rightMargin: 8
      anchors.top: parent.top
      anchors.topMargin: 4
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 4
      Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

      Controls.TextArea {
        id: input
        background: null
        color: Theme.text
        topPadding: (42 - contentLineHeight) / 2
        bottomPadding: topPadding
        leftPadding: 6
        rightPadding: 6
        wrapMode: TextEdit.Wrap
        readonly property real contentLineHeight: fontMetrics.height
        FontMetrics { id: fontMetrics; font: input.font }
        placeholderText: composer.talking
          ? "Listening, " + Dates.clock(composer.app.recordingSeconds * 1000) + (composer.todo ? ". " + composer.listeningText
            : composer.app.takeDate ? ". Stop adds it to " + Dates.long(composer.app.takeDate, composer.app.todayIso()) + "."
            : ". Stop saves it.")
          : composer.writing ? (composer.todo ? "Adding them to the list" : "Your entry appears above in a moment")
          : composer.todo ? (composer.placeholder || "or type a to-do")
          : composer.laterDay ? "or type a note to yourself"
          : composer.pastDay ? "or type what happened that day" : "or start typing"
        placeholderTextColor: Theme.secondary
        selectionColor: Theme.alpha(Theme.accent, 0.4)
        selectedTextColor: Theme.text
        font.family: input.text.length > 0 && !composer.todo ? Theme.book : Theme.sans
        font.pixelSize: input.text.length > 0 && !composer.todo ? 17 : 14
        enabled: composer.canWrite && !composer.talking && !composer.writing
        selectByMouse: true
        // Cleared only once the entry is saved, so a failed save keeps your words.
        function accept() { if (text.trim().length > 0) composer.typed(text.trim()) }
        Keys.onPressed: function(event) {
          if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
            accept()
            event.accepted = true
          } else if (event.key === Qt.Key_Z && event.modifiers === Qt.ControlModifier && !canUndo) {
            composer.undoPressed()
            event.accepted = true
          }
        }
        // Esc only leaves the field; the draft waits there for you.
        Keys.onEscapePressed: focus = false
        Accessible.name: composer.todo ? "Type a to-do" : "Type a journal entry"
      }
    }

    Item {
      id: trailing
      anchors.right: parent.right
      anchors.rightMargin: 8
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 9
      width: input.text.trim().length > 0 ? (newLine.visible ? newLine.width + 12 : 0) + save.width
        : composer.shortcut ? (hint.visible ? hint.width : 0) : addShortcut.visible ? addShortcut.width : 0
      height: 32

      // The hint gives way to what typing here does: where it would cut the
      // placeholder short, a shorter one shows, or none.
      readonly property string shortHint: composer.shortcut ? composer.shortcut + " works from any app" : ""
      readonly property real room: composer.width - talk.width - placeholderSize.advanceWidth - 60
      TextMetrics { id: placeholderSize; font: input.font; text: input.placeholderText }
      TextMetrics { id: hintSize; font: hint.font; text: composer.hintText }
      TextMetrics { id: shortHintSize; font: hint.font; text: trailing.shortHint }
      UiText {
        id: hint
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text.trim().length === 0 && text.length > 0
        text: composer.hintText && hintSize.advanceWidth < trailing.room ? composer.hintText
          : shortHintSize.advanceWidth < trailing.room ? trailing.shortHint : ""
        muted: true
      }
      // No journal shortcut yet: offer to add one, so entries can start
      // from any app.
      Pill {
        id: addShortcut
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // Not while talking or writing: the entry is already under way here.
        visible: input.text.trim().length === 0 && !composer.shortcut && !composer.talking && !composer.writing
        kind: "link"
        text: "Add a shortcut"
        size: 13
        hint: composer.todo ? "Add to-dos from any app" : "Start journal entries from any app"
        onClicked: composer.app.showWindow("settings/hotkeys")
      }
      UiText {
        id: newLine
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        // Only where it leaves the words room.
        visible: input.text.trim().length > 0 && composer.width - talk.width - save.width - implicitWidth > 300
        text: composer.todo ? "Shift+Enter for another to-do" : "Shift+Enter for a new line"
        muted: true
        font.pixelSize: 12
      }
      Pill {
        id: save
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text.trim().length > 0
        kind: "fill"
        text: composer.addLabel
        size: 13
        trailing: Component { Icon { name: "return"; size: 12; color: Theme.text } }
        onClicked: input.accept()
      }
    }
  }
}
