import QtQuick
import QtQuick.Shapes
import "Dates.js" as Dates

// The card at the bottom of the screen while you talk and just after. It only
// takes the keyboard when you click into a to-do on it to edit: every state
// reads at a glance. A finished card closes with Esc. One you can act on
// (Open, Undo, a to-do to fix, an error to read) shows its Esc button in a ring
// that fills as its time runs out, and pointing at it stops the clock; a
// passing "Pasted" or "Nothing heard" just goes. A take in progress only ends through its own buttons or hotkey,
// because Esc is pressed in other apps all the time.
Item {
  id: overlay

  required property var app
  readonly property string phase: app.phase
  readonly property bool journal: app.journalTake
  readonly property bool todo: app.todoTake
  readonly property string mode: phase === "recording" ? (journal ? "journal" : todo ? "todo" : app.latched ? "locked" : "holding")
    : phase === "processing" ? "processing"
    : phase === "success" ? "success"
    : phase === "result" ? (app.errorText ? "copy-failed" : "copied")
    : phase === "notice" ? "notice"
    : phase === "error" ? "error"
    : phase === "journal-saved" ? "journal-saved"
    : phase === "todos-saved" ? "todos-saved"
    : "idle"
  // What the card shows. It keeps the last card, words and all, while that
  // fades out: the phase changes first, so `v` is caught before the rest of
  // the state moves on.
  property string shownMode: "idle"
  readonly property var live: ({
    errorText: app.errorText, feedback: app.feedback, feedbackError: app.feedbackError,
    pasteSent: app.pasteSent, pasteMode: app.pasteMode, journalSaved: app.journalSaved,
    todosSaved: app.todosSaved, todoList: app.todoList, journalTake: app.journalTake, todoTake: app.todoTake,
    canRetry: app.canRetry
  })
  property var v: live
  onLiveChanged: if (shown) v = live
  onShownChanged: if (shown) v = live
  readonly property bool shown: mode !== "idle"
  readonly property var recordingModes: ["holding", "locked", "journal", "todo"]
  // States that need a word of explanation get a two-line card; the rest are
  // one capsule.
  readonly property bool tall: shownMode === "error" || shownMode === "copy-failed"
    || (shownMode === "copied" && v.feedbackError) || shownMode === "todos-saved"
  readonly property color edge: shownMode === "error" || shownMode === "copy-failed" ? Theme.red
    : shownMode === "copied" && v.feedbackError ? Theme.yellow
    : Theme.divider

  implicitWidth: card.width
  implicitHeight: card.height
  visible: shown || card.opacity > 0

  // To-dos go to a list. Once there are lists, the pill and the card name
  // it, and clicking the name opens the lists above the card: while you
  // talk, picking one sends this capture there; on the card, it moves it.
  // The host adds `menuArea` to the window's input region.
  property var todoLists: []
  readonly property bool listed: todoLists.length > 0
  readonly property Item menuArea: listMenu
  readonly property string savedList: v.todosSaved && v.todosSaved.items && v.todosSaved.items.length > 0
    ? String(v.todosSaved.items[0].list || "") : ""
  readonly property string chipList: shownMode === "todos-saved" ? savedList : v.todoList
  function loadLists() {
    app.query(["todos", "list"], function(value) { overlay.todoLists = value && value.lists ? value.lists : [] })
  }
  function closeMenu() { listMenu.open = false }
  function toggleMenu(chip) {
    if (listMenu.open) { closeMenu(); return }
    var at = chip.mapToItem(overlay, 0, 0)
    listMenu.x = Math.max(0, at.x - 6)
    listMenu.open = true
  }
  function pickList(list) {
    var onCard = mode === "todos-saved"
    closeMenu()
    if (onCard) { if (list !== savedList) app.todoMoveCapture(list) }
    else app.todoSetList(list)
  }

  // ------------------------------------------------------------ the clock
  readonly property bool finished: ["success", "copied", "copy-failed", "notice", "error", "journal-saved", "todos-saved"].indexOf(mode) >= 0
  // Which to-do on the card is being edited, by its place in the list.
  property int editingIndex: -1
  // Esc ends an edit on the press and the card's Esc binding fires on the
  // release; the edit's hold outlives the key so the card stays.
  property bool editEnding: false
  Timer { id: editEnd; interval: 450; onTriggered: overlay.editEnding = false }
  readonly property bool pointed: cardHover.hovered || menuHover.hovered
  // What the card waits for: an edit, being pointed at or its menu, or nothing.
  readonly property string hold: !finished ? ""
    : editingIndex >= 0 || editEnding ? "edit"
    : pointed || listMenu.open ? "hover"
    : ""
  onHoldChanged: if (finished && app.cardTotalMs > 0) app.cardHold(hold)
  // The ring's fill, 0 to 1: how much of the card's time has gone.
  property real elapsed: 0
  function restartClock() {
    clock.stop()
    if (app.cardTotalMs <= 0 || app.cardClosesAt <= 0) { elapsed = 0; return }
    var left = Math.max(0, app.cardClosesAt - Date.now())
    elapsed = Math.max(0, Math.min(1, 1 - left / app.cardTotalMs))
    clock.duration = left
    clock.restart()
  }
  NumberAnimation { id: clock; target: overlay; property: "elapsed"; to: 1 }
  Connections {
    target: overlay.app
    function onCardClosesAtChanged() { overlay.restartClock() }
    function onCardTotalMsChanged() { overlay.restartClock() }
  }

  onModeChanged: {
    if (mode !== "idle") {
      var before = shownMode
      shownMode = mode
      // A take that grows (held, then locked) keeps its waveform steady;
      // anything else swaps its words in as the card reshapes.
      var steady = recordingModes.indexOf(before) >= 0 && recordingModes.indexOf(mode) >= 0
      if (before !== "idle" && card.opacity > 0 && !steady && Theme.motion) swap.restart()
    }
    listMenu.open = false
    editingIndex = -1
    if (mode === "todo" || mode === "todos-saved") loadLists()
    restartClock()
    // A new card under the pointer waits too.
    if (finished && hold !== "" && app.cardTotalMs > 0) app.cardHold(hold)
  }

  // Esc, in a ring that fills as the card's time runs out. Click it to close
  // now; a card that stays until closed shows the ring empty.
  component EscRing: Item {
    id: ring
    width: 28; height: 28
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: ringMouse.containsMouse ? Theme.fill18 : "transparent"
    }
    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: "transparent"
        strokeColor: Theme.alpha(Theme.text, 0.16)
        strokeWidth: 2
        PathAngleArc { centerX: 14; centerY: 14; radiusX: 12.5; radiusY: 12.5; startAngle: 0; sweepAngle: 360 }
      }
      ShapePath {
        fillColor: "transparent"
        strokeColor: Theme.secondary
        strokeWidth: 2
        capStyle: ShapePath.RoundCap
        PathAngleArc { centerX: 14; centerY: 14; radiusX: 12.5; radiusY: 12.5; startAngle: -90; sweepAngle: 360 * overlay.elapsed }
      }
    }
    UiText { anchors.centerIn: parent; text: "Esc"; font.pixelSize: 9; weight: Font.DemiBold; muted: !ringMouse.containsMouse }
    MouseArea { id: ringMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overlay.app.dismiss() }
    Accessible.role: Accessible.Button
    Accessible.name: "Close"
  }

  // The list a capture goes to: its dot and name, and a click opens the rest.
  component ListChip: Rectangle {
    id: chip
    property string list: ""
    height: 26
    width: chipRow.implicitWidth + 20
    radius: 13
    color: chipMouse.containsMouse || listMenu.open ? Theme.fill18 : Theme.fill8
    border.width: listMenu.open ? 1.5 : 0
    border.color: Theme.accent
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: 6
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 7; height: 7; radius: 3.5
        color: chip.list ? Theme.listColor(chip.list) : "transparent"
        border.width: chip.list ? 0 : 1.2
        border.color: Theme.outline
      }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: chip.list || "Inbox"; weight: Font.DemiBold }
      Icon { anchors.verticalCenter: parent.verticalCenter; name: "down"; size: 9; color: Theme.secondary }
    }
    MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overlay.toggleMenu(chip) }
    Accessible.role: Accessible.ComboBox
    Accessible.name: "List: " + (chip.list || "Inbox")
  }

  // The lists, opening upwards from the chip.
  Shadowed {
    id: listMenu
    property bool open: false
    HoverHandler { id: menuHover }
    visible: open
    y: -height - 8
    width: open ? 190 : 0
    height: open ? menuColumn.implicitHeight + 10 : 0
    radius: Theme.radiusCard + 2
    color: Theme.fill8
    shadowOpacity: 0.45
    Column {
      id: menuColumn
      x: 5; y: 5
      width: parent.width - 10
      Repeater {
        model: [""].concat(overlay.todoLists)
        Rectangle {
          required property string modelData
          width: menuColumn.width
          height: 32
          radius: 16
          color: itemMouse.containsMouse ? Theme.fill18 : "transparent"
          Rectangle {
            x: 12; anchors.verticalCenter: parent.verticalCenter
            width: 7; height: 7; radius: 3.5
            color: modelData ? Theme.listColor(modelData) : "transparent"
            border.width: modelData ? 0 : 1.2
            border.color: Theme.outline
          }
          UiText { x: 28; anchors.verticalCenter: parent.verticalCenter; text: modelData || "Inbox" }
          Icon { visible: modelData === overlay.chipList; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 11; color: Theme.text }
          MouseArea { id: itemMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overlay.pickList(modelData) }
          Accessible.role: Accessible.MenuItem
          Accessible.name: modelData || "Inbox"
        }
      }
    }
  }

  // The card rises into place when a take starts, reshapes as it goes from
  // listening to done, and fades when it closes. Its bottom edge never moves.
  Shadowed {
    id: card
    width: content.implicitWidth + (overlay.tall ? 36 : 28)
    height: overlay.tall ? content.implicitHeight + 28 : 42
    radius: overlay.tall ? Theme.radiusDialog : height / 2
    color: Theme.fill4
    borderColor: overlay.edge
    shadowOpacity: 0.45
    clipContent: true
    opacity: overlay.shown ? 1 : 0
    readonly property bool settled: opacity === 1
    transform: Translate { y: overlay.shown || !Theme.motion ? 0 : 8; Behavior on y { enabled: Theme.motion; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } } }
    Behavior on opacity { enabled: Theme.motion; NumberAnimation { duration: overlay.shown ? 160 : 140; easing.type: Easing.OutCubic } }
    Behavior on width { enabled: Theme.motion && card.settled && overlay.shown; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: Theme.motion && card.settled && overlay.shown; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on radius { enabled: Theme.motion && card.settled && overlay.shown; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    HoverHandler { id: cardHover }

    Item {
      id: content
      anchors.centerIn: parent
      SequentialAnimation {
        id: swap
        // The words come in once the card has nearly reached its new shape.
        PropertyAction { target: content; property: "opacity"; value: 0 }
        PauseAnimation { duration: 120 }
        NumberAnimation { target: content; property: "opacity"; to: 1; duration: 130; easing.type: Easing.OutCubic }
      }
      implicitWidth: loader.item ? loader.item.implicitWidth : 0
      implicitHeight: loader.item ? loader.item.implicitHeight : 0
      width: implicitWidth
      height: implicitHeight
      Loader {
        id: loader
        sourceComponent: overlay.shownMode === "holding" ? holding
          : overlay.shownMode === "locked" ? locked
          : overlay.shownMode === "journal" ? journalTake
          : overlay.shownMode === "todo" ? todoTake
          : overlay.shownMode === "processing" ? processing
          : overlay.shownMode === "success" ? success
          : overlay.shownMode === "copied" ? copied
          : overlay.shownMode === "copy-failed" ? copyFailed
          : overlay.shownMode === "notice" ? notice
          : overlay.shownMode === "error" ? failed
          : overlay.shownMode === "journal-saved" ? saved
          : overlay.shownMode === "todos-saved" ? todosAdded
          : null
      }
    }
  }

  // Every take that is listening starts the same way: the moving voice.
  // Holding a key shows just that; a locked take or a journal entry adds
  // what it needs after it, so the card grows instead of changing.
  component Live: Waveform {
    width: 70; height: 20; live: true; barWidth: 3; gap: 3
    peaks: overlay.app.waveHistory
    color: Theme.text
  }

  Component {
    id: holding
    Row { Live {} }
  }

  Component {
    id: locked
    Row {
      spacing: 10
      Live { anchors.verticalCenter: parent.verticalCenter }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.app.clock(overlay.app.recordingSeconds); muted: true; font.features: { "tnum": 1 } }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Stop"; verticalPadding: 4; onClicked: overlay.app.stopRecording() }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "ghost"; text: "Cancel"; verticalPadding: 4; onClicked: overlay.app.cancel() }
    }
  }

  Component {
    id: journalTake
    Row {
      spacing: 10
      Live { anchors.verticalCenter: parent.verticalCenter }
      // The one thing that differs from a locked dictation: the words go to
      // the journal, not into the app you are in.
      UiText { anchors.verticalCenter: parent.verticalCenter; text: "Journal " + overlay.app.clock(overlay.app.recordingSeconds); muted: true; font.features: { "tnum": 1 } }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Stop"; verticalPadding: 4; hint: overlay.app.journalShortcut ? "Stop and save the entry. " + overlay.app.journalShortcut + " does the same." : "Stop and save the entry."; onClicked: overlay.app.journalToggle() }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "ghost"; text: "Cancel"; verticalPadding: 4; hint: "Throw the entry away"; onClicked: overlay.app.journalDiscard() }
    }
  }

  Component {
    id: todoTake
    Row {
      spacing: 10
      Live { anchors.verticalCenter: parent.verticalCenter }
      // As with the journal: the same card, and where it goes.
      UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.listed ? "To-do for" : "To-do"; muted: true }
      ListChip { anchors.verticalCenter: parent.verticalCenter; visible: overlay.listed; list: overlay.v.todoList }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.app.clock(overlay.app.recordingSeconds); muted: true; font.features: { "tnum": 1 } }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Stop"; verticalPadding: 4; hint: overlay.app.todoShortcut ? "Stop and add the to-dos. " + overlay.app.todoShortcut + " does the same." : "Stop and add the to-dos."; onClicked: overlay.app.todoToggle() }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "ghost"; text: "Cancel"; verticalPadding: 4; hint: "Throw it away"; onClicked: overlay.app.todoDiscard() }
    }
  }

  Component {
    id: processing
    Row {
      spacing: 10
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        Repeater {
          model: 3
          Rectangle {
            required property int index
            width: 5; height: 5; radius: 2.5
            color: Theme.text
            opacity: 0.35
            SequentialAnimation on opacity {
              loops: Animation.Infinite
              PauseAnimation { duration: index * 160 }
              NumberAnimation { to: 1; duration: 260 }
              NumberAnimation { to: 0.35; duration: 260 }
              PauseAnimation { duration: (2 - index) * 160 }
            }
          }
        }
      }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.v.journalTake ? "Writing it down" : overlay.v.todoTake ? "Adding to-dos" : overlay.app.cleanupLevel === "medium" ? "Transcribing and cleaning up" : "Transcribing" }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "ghost"; text: "Cancel"; verticalPadding: 4; onClicked: overlay.app.cancel() }
    }
  }

  Component {
    id: success
    Row {
      spacing: 9
      Icon { anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 13; color: Theme.greenText }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: "Pasted"; weight: Font.DemiBold }
    }
  }

  Component {
    id: copied
    Column {
      spacing: 6
      Row {
        spacing: 9
        Icon { anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 13; color: overlay.v.feedbackError ? Theme.yellowText : Theme.greenText }
        UiText {
          anchors.verticalCenter: parent.verticalCenter
          text: overlay.v.pasteSent ? "Pasted" : overlay.v.pasteMode === "clipboard" ? "On your clipboard" : "Copied, press Ctrl+V"
          weight: Font.DemiBold
        }
        UiText {
          anchors.verticalCenter: parent.verticalCenter
          visible: !overlay.v.pasteSent && overlay.v.pasteMode !== "clipboard"
          text: "the paste did not reach the window"
          muted: true
        }
        EscRing { anchors.verticalCenter: parent.verticalCenter }
      }
      UiText {
        visible: overlay.v.feedbackError && overlay.v.feedback.length > 0
        width: Math.min(implicitWidth, 520)
        text: overlay.v.feedback
        color: Theme.yellowText
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }
  }

  Component {
    id: copyFailed
    Column {
      spacing: 6
      width: Math.min(560, Math.max(first.implicitWidth + 40, 360))
      // What happened on the left, Esc in the top right corner.
      Item {
        width: parent.width
        height: 28
        Row {
          id: first
          anchors.verticalCenter: parent.verticalCenter
          spacing: 9
          Icon { anchors.verticalCenter: parent.verticalCenter; name: "warning"; size: 15; color: Theme.redText }
          UiText { anchors.verticalCenter: parent.verticalCenter; text: "Not copied"; weight: Font.DemiBold }
          Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Copy again"; verticalPadding: 4; onClicked: overlay.app.copyAgain() }
        }
        EscRing { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
      }
      UiText { width: parent.width; text: "Your words are safe in History. " + overlay.v.errorText; muted: true; font.pixelSize: 12; wrapMode: Text.Wrap }
    }
  }

  Component {
    id: notice
    UiText { text: "Nothing heard"; muted: true }
  }

  Component {
    id: failed
    Column {
      spacing: 6
      width: Math.min(560, Math.max(head.implicitWidth + 40, 360))
      Item {
        width: parent.width
        height: 28
        Row {
          id: head
          anchors.verticalCenter: parent.verticalCenter
          spacing: 9
          Icon { anchors.verticalCenter: parent.verticalCenter; name: "warning"; size: 15; color: Theme.redText }
          UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.v.journalTake ? "The entry was not saved" : overlay.v.todoTake ? "The to-dos were not added" : "Dictation failed"; weight: Font.DemiBold }
          // The recording is kept: send it again instead of saying it again.
          Pill { anchors.verticalCenter: parent.verticalCenter; visible: overlay.v.canRetry; kind: "primary"; text: "Try again"; verticalPadding: 4; hint: "Transcribe the same recording again"; onClicked: overlay.app.retry() }
        }
        EscRing { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
      }
      UiText { width: parent.width; text: overlay.v.errorText; muted: true; font.pixelSize: 12; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
    }
  }

  Component {
    id: saved
    Row {
      spacing: 9
      Icon { anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 13; color: Theme.greenText }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: "Added to today's journal"; weight: Font.DemiBold }
      UiText {
        anchors.verticalCenter: parent.verticalCenter
        visible: overlay.v.journalSaved !== null
        text: overlay.v.journalSaved
          ? overlay.app.clock(overlay.v.journalSaved.duration_ms / 1000) + ", " + overlay.v.journalSaved.words + (overlay.v.journalSaved.words === 1 ? " word" : " words")
          : ""
        muted: true
      }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "primary"; text: "Open"; verticalPadding: 4; onClicked: overlay.app.showWindow("journal") }
      EscRing { anchors.verticalCenter: parent.verticalCenter }
    }
  }

  // What was added, so a wrong split is caught right here: how many, where
  // they went, and each to-do, which a click edits in place and × takes out.
  // Undo takes all of them back out.
  Component {
    id: todosAdded
    Column {
      id: added
      readonly property var items: overlay.v.todosSaved ? overlay.v.todosSaved.items || [] : []
      readonly property int shown: 6
      spacing: 8
      width: Math.min(540, Math.max(head.implicitWidth + 40, 420))
      // What happened on the left, Esc in the top right corner.
      Item {
        width: parent.width
        height: 28
        Row {
          id: head
          anchors.verticalCenter: parent.verticalCenter
          spacing: 9
          Icon { anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 13; color: overlay.v.feedbackError ? Theme.yellowText : Theme.greenText }
          UiText {
            anchors.verticalCenter: parent.verticalCenter
            text: (added.items.length === 1 ? "To-do " : added.items.length + " to-dos ")
              + (overlay.v.todosSaved && overlay.v.todosSaved.moved ? "moved" : "added") + (overlay.listed ? " to" : "")
            weight: Font.DemiBold
          }
          ListChip { anchors.verticalCenter: parent.verticalCenter; visible: overlay.listed; list: overlay.savedList }
          Pill { anchors.verticalCenter: parent.verticalCenter; kind: "primary"; text: "Open"; verticalPadding: 4; onClicked: overlay.app.showWindow("todos") }
          Pill { anchors.verticalCenter: parent.verticalCenter; kind: "ghost"; text: "Undo"; verticalPadding: 4; hint: "Take these to-dos back out"; onClicked: overlay.app.todoUndo() }
        }
        EscRing { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
      }
      Column {
        width: parent.width
        Repeater {
          model: added.items.slice(0, added.shown)
          TodoLine { width: added.width }
        }
        UiText {
          visible: added.items.length > added.shown
          leftPadding: 24
          text: "and " + (added.items.length - added.shown) + " more"
          muted: true
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: overlay.app.showWindow("todos") }
        }
      }
      UiText {
        visible: overlay.v.feedbackError && overlay.v.feedback.length > 0
        width: parent.width
        text: overlay.v.feedback
        color: Theme.yellowText
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }
  }

  // One added to-do: click the words to fix them, Enter keeps the change,
  // Esc drops it, × takes the to-do out.
  component TodoLine: Item {
    id: line
    required property var modelData
    readonly property bool editing: overlay.editingIndex === modelData.index
    height: Math.max(30, (line.editing ? editor.contentHeight : words.implicitHeight) + 10)
    HoverHandler { id: lineHover }
    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -8; anchors.rightMargin: -8
      radius: 8
      color: line.editing ? Theme.fill8 : lineHover.hovered ? Theme.fill4 : "transparent"
    }
    Rectangle {
      x: 1; y: 9
      width: 12; height: 12; radius: 6
      color: "transparent"
      border.width: 1.3
      border.color: Theme.outline
    }
    UiText {
      id: words
      visible: !line.editing
      x: 24; y: 5
      width: dueText.x - x - 10
      text: line.modelData.text
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.IBeamCursor
        onClicked: overlay.editingIndex = line.modelData.index
      }
      Accessible.role: Accessible.Button
      Accessible.name: "Edit " + line.modelData.text
    }
    // Wraps like the words it replaces, so a long to-do stays readable.
    TextEdit {
      id: editor
      visible: line.editing
      x: 24; y: 5
      width: dueText.x - x - 10
      wrapMode: TextEdit.Wrap
      color: Theme.text
      selectionColor: Theme.alpha(Theme.accent, 0.4)
      font.family: Theme.sans
      font.pixelSize: words.font.pixelSize
      selectByMouse: true
      property bool done: false
      readonly property bool windowActive: Window.active
      onVisibleChanged: if (visible) { done = false; text = line.modelData.text; cursorPosition = text.length; forceActiveFocus() }
      function finish(keep) {
        if (done) return
        done = true
        var next = text.trim()
        if (keep && next.length > 0 && next !== line.modelData.text) overlay.app.todoCardEdit(line.modelData, next)
        overlay.editingIndex = -1
        focus = false
      }
      Keys.onReturnPressed: finish(true)
      Keys.onEnterPressed: finish(true)
      Keys.onEscapePressed: { overlay.editEnding = true; editEnd.restart(); finish(false) }
      // Clicking anywhere else, in this card or another window, keeps it.
      onActiveFocusChanged: if (!activeFocus && line.editing) finish(true)
      onWindowActiveChanged: if (!windowActive && line.editing) finish(true)
      Accessible.name: "Edit the to-do"
    }
    UiText {
      id: dueText
      anchors.right: remove.left
      anchors.rightMargin: 6
      y: 5
      text: line.modelData.due ? Dates.dueAt(String(line.modelData.due), line.modelData.time || "", overlay.app.todayIso()) : ""
      muted: true
    }
    Rectangle {
      id: remove
      anchors.right: parent.right
      y: 3
      width: 24; height: 24; radius: 12
      opacity: lineHover.hovered && !line.editing ? 1 : 0
      color: removeMouse.containsMouse ? Theme.fill18 : "transparent"
      Icon { anchors.centerIn: parent; name: "close"; size: 9; color: Theme.secondary }
      MouseArea { id: removeMouse; anchors.fill: parent; enabled: parent.opacity > 0; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overlay.app.todoCardRemove(line.modelData) }
      Accessible.role: Accessible.Button
      Accessible.name: "Take out " + line.modelData.text
    }
  }
}
