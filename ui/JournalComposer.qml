import QtQuick
import QtQuick.Controls as Controls

// The bottom of today's page, and of the to-do list: talk or type. A spoken
// take records with the same card as any dictation; here, Talk turns into
// Stop while you speak.
Item {
  id: composer

  required property var app
  property bool canWrite: true
  // A later day: what is said or typed here is a note for that day.
  property string laterDay: ""
  // On the to-do page: what is said or typed becomes to-dos.
  property bool todo: false
  // To-dos: where Talk sends them, { list, due }, and the words that say so.
  property var todoTarget: null
  property string placeholder: ""
  property string hintText: ""
  readonly property string shortcut: todo ? app.todoShortcut : app.journalShortcut
  function toggle(laterDay) { if (todo) app.todoToggle(talking ? null : todoTarget); else app.journalToggle(laterDay) }
  signal typed(string text)

  readonly property bool mine: todo ? app.todoTake : app.journalTake
  readonly property bool talking: app.phase === "recording" && mine
  readonly property bool writing: app.phase === "processing" && mine
  function focusInput() { input.forceActiveFocus() }
  Component { id: micIcon; Icon { name: "mic"; size: 15; color: Theme.onAccent } }
  function clearInput() { input.text = "" }

  implicitHeight: 50

  // ------------------------------------------------------------ talk or type
  Shadowed {
    anchors.fill: parent
    color: Theme.fill4
    shadowOpacity: 0.35

    Pill {
      id: talk
      anchors.left: parent.left
      anchors.leftMargin: 7
      anchors.verticalCenter: parent.verticalCenter
      kind: "primary"
      text: composer.talking && pressed && startedHere ? "Let go to save"
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
          composer.toggle(composer.laterDay)
        } else if (!pressed && startedHere) {
          // Held: letting go saves.
          if (Date.now() - downAt >= 400) composer.toggle("")
          // The click that follows this release belongs to the press that
          // started the entry; forget it after, even if the pointer left.
          Qt.callLater(function() { talk.startedHere = false })
        }
      }
      onClicked: if (!startedHere) composer.toggle(composer.talking ? "" : composer.laterDay)
    }

    Controls.TextField {
      id: input
      anchors.left: talk.right
      anchors.leftMargin: 8
      anchors.right: trailing.left
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      background: null
      color: Theme.text
      placeholderText: composer.talking ? (composer.todo ? "Listening. Name one thing after another." : "Listening. Stop saves it.")
        : composer.writing ? (composer.todo ? "Adding them to the list" : "Writing it down")
        : composer.todo ? (composer.placeholder || "or type a to-do")
        : composer.laterDay ? "or type a note to yourself" : "or start typing"
      placeholderTextColor: Theme.secondary
      selectionColor: Theme.alpha(Theme.accent, 0.4)
      font.family: input.text.length > 0 && !composer.todo ? Theme.book : Theme.sans
      font.pixelSize: input.text.length > 0 && !composer.todo ? 17 : 14
      enabled: composer.canWrite && !composer.talking && !composer.writing
      selectByMouse: true
      // Cleared only once the entry is saved, so a failed save keeps your words.
      onAccepted: if (text.trim().length > 0) composer.typed(text.trim())
      Keys.onEscapePressed: { text = ""; focus = false }
      Accessible.name: composer.todo ? "Type a to-do" : "Type a journal entry"
    }

    Item {
      id: trailing
      anchors.right: parent.right
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      width: input.text.trim().length > 0 ? save.width : composer.shortcut ? hint.width : addShortcut.width
      height: 32

      UiText {
        id: hint
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text.trim().length === 0 && text.length > 0
        text: !composer.shortcut ? "" : composer.hintText || composer.shortcut + " works from any app"
        muted: true
      }
      // No journal shortcut yet: offer to add one, so entries can start
      // from any app.
      Pill {
        id: addShortcut
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text.trim().length === 0 && !composer.shortcut
        kind: "link"
        text: "Add a shortcut"
        size: 13
        hint: composer.todo ? "Add to-dos from any app" : "Start journal entries from any app"
        onClicked: composer.app.showWindow("settings/hotkeys")
      }
      Pill {
        id: save
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text.trim().length > 0
        kind: "fill"
        text: composer.todo ? "Add" : "Save"
        size: 13
        trailing: Component { Icon { name: "return"; size: 12; color: Theme.text } }
        onClicked: input.accepted()
      }
    }
  }
}
