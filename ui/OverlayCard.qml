import QtQuick
import QtQuick.Shapes
import "Dates.js" as Dates

// The card at the bottom of the screen while you talk and just after. It only
// takes the keyboard when you click into a to-do on it to edit: every state
// reads at a glance. A finished card closes with Esc. One you can act on
// (Open, Undo, a to-do to fix, an error to read) shows its Esc button in a ring
// that fills as its time runs out, and pointing at it stops the clock; a
// passing "Pasted" just goes. A take in progress only ends
// through its own buttons or hotkey, because Esc is pressed in other apps all
// the time. A failed take whose recording only the card holds waits the same
// way, until Try again or Discard, and so do words the clipboard did not take
// while History is off; one saved in History closes like any card, and is
// deleted from History, where its Undo is.
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
    pasteSent: app.pasteSent, pasteMode: app.pasteMode, pasteKey: app.pasteKey, journalSaved: app.journalSaved,
    todosSaved: app.todosSaved, todoList: app.todoList, journalTake: app.journalTake, todoTake: app.todoTake,
    canRetry: app.canRetry, keptInHistory: app.keptInHistory, errorAction: app.errorAction
  })
  // Only the card holds the failed take's recording, so Esc leaves it alone.
  readonly property bool holdsRecording: v.canRetry && !v.keptInHistory
  // Or the only copy of the words: not copied, and History is off.
  readonly property bool holdsWords: shownMode === "copy-failed" && app.historyLimit === 0
  // A journal take for another day names it: "Note for Fri 2 Oct", or
  // "Journal for Fri 18 Sep" for a past day.
  readonly property string takeDay: !app.takeDate ? "" : Dates.short(app.takeDate, app.todayIso())
  readonly property bool takeLater: takeDay !== "" && app.takeDate > app.todayIso()
  property var v: live
  onLiveChanged: if (shown) v = live
  onShownChanged: if (shown) v = live
  readonly property bool shown: mode !== "idle"
  readonly property var recordingModes: ["holding", "locked", "journal", "todo"]
  // States that need a word of explanation get a two-line card; the rest are
  // one capsule.
  // A pasted dictation, a journal entry or to-dos that kept going without
  // cleanup carry a warning, which needs the room too.
  readonly property bool warned: (shownMode === "copied" || shownMode === "journal-saved" || shownMode === "todos-saved") && v.feedbackError
  readonly property bool tall: shownMode === "error" || shownMode === "copy-failed"
    || warned || shownMode === "todos-saved" || shownMode === "notice" && longNotice
  // A model still downloading is a wait, not a failure: yellow, as in the
  // window's header.
  readonly property bool waiting: shownMode === "error" && v.errorAction === "downloading"
  // That download finished while the card kept the recording: good news.
  readonly property bool ready: shownMode === "error" && v.errorAction === "ready"
  // How far that download is, read from the download itself so it moves, or
  // -1 once it has stopped.
  readonly property int downloadPercent: waiting && app.speechDownload
    ? Math.max(0, Math.min(100, Math.round(Number(app.speechDownload.percent) || 0))) : -1
  readonly property color edge: waiting || warned ? Theme.yellow
    : shownMode === "error" && !ready || shownMode === "copy-failed" ? Theme.red
    : Theme.divider

  // The headline of each card, shared by what it shows and the name a screen
  // reader announces for it.
  readonly property string processingText: v.journalTake ? "Writing it down" : v.todoTake ? "Adding to-dos"
    : app.cleanupLevel === "medium" ? "Transcribing and cleaning up" : "Transcribing"
  readonly property bool pasteMissed: !v.pasteSent && v.pasteMode !== "clipboard"
  readonly property string copiedTitle: v.pasteSent ? "Pasted" : v.pasteMode === "clipboard" ? "On your clipboard"
    : "Press " + app.pasteLabel(v.pasteKey) + " to paste"
  readonly property string noticeText: "Nothing heard. Check the microphone."
  // A short word from the daemon with nothing else to show, or the usual one.
  readonly property string noticeShown: withoutPointer(v.feedback) || noticeText
  // A card whose words send you to a settings page has a button that opens
  // it, so you need not remember the page and find it later.
  readonly property var settingsLabels: ({ audio: "Audio settings", cleanup: "Cleanup settings", updates: "Updates and app" })
  function settingsPage(words) {
    var named = /Settings, (?:Advanced, )?(Audio|Cleanup|Updates)/.exec(words || "")
    return named ? named[1].toLowerCase() : ""
  }
  // A last sentence that only sends you to the page, such as "Check Settings,
  // Cleanup." or "Check the microphone in Settings, Audio.", is what the
  // button under it says, so the card leaves it out.
  function withoutPointer(words) {
    return String(words || "").replace(/\s*Check (?:the microphone in )?Settings, (?:Advanced, )?(?:Audio|Cleanup|Updates and app)\.$/, "")
  }
  readonly property string noticePage: v.feedback ? settingsPage(v.feedback) : "audio"
  // A notice too long for one capsule wraps on a two-line card.
  TextMetrics { id: noticeMetrics; font.family: Theme.sans; font.pixelSize: 13; text: overlay.noticeShown }
  readonly property bool longNotice: noticeMetrics.advanceWidth > 420
  readonly property string errorTitle: v.errorAction === "choose_model" ? "Choose a speech model"
    : v.errorAction === "downloading" ? "The speech model is still downloading"
    : v.errorAction === "ready" ? "The speech model is ready"
    : v.journalTake ? "The entry was not saved" : v.todoTake ? "The to-dos were not added" : "Dictation failed"
  // The failure's words, less the page its button opens. A path such as
  // ~/Documents/Journal wraps as a whole, not after "~/".
  readonly property string errorShown: (v.errorAction ? v.errorText : withoutPointer(v.errorText)).replace(/\/(?=\S)/g, "/\u2060")
  readonly property string savedDate: v.journalSaved ? String(v.journalSaved.date) : ""
  // A note for a later day names that day, and so does a take that ran past
  // midnight.
  readonly property string savedTitle: !savedDate || savedDate === app.todayIso() ? "Added to today's journal"
    : savedDate > app.todayIso() ? "Note added for " + Dates.long(savedDate, app.todayIso())
    : "Added to the journal for " + Dates.long(savedDate, app.todayIso())
  readonly property int addedCount: v.todosSaved && v.todosSaved.items ? v.todosSaved.items.length : 0
  readonly property string addedTitle: (addedCount === 1 ? "To-do " : addedCount + " to-dos ")
    + (v.todosSaved && v.todosSaved.moved ? "moved" : "added") + (listed ? " to" : "")
  // A to-do fixed or taken out on this card. Undo would then read as putting
  // that one step back, so the button says what it does: takes the rest out.
  property bool todosChanged: false
  readonly property bool undoTakesOut: todosChanged || !!(v.todosSaved && (v.todosSaved.moved || v.todosSaved.changed))
  function editTodo(todo, text) { todosChanged = true; app.todoCardEdit(todo, text) }
  function removeTodo(todo) { todosChanged = true; app.todoCardRemove(todo) }
  // A capture that could not be written names the folder setting; Open goes
  // to the page whose options hold it.
  readonly property string failedPlace: shownMode !== "error" ? ""
    : /Journal settings/.test(v.errorText) ? "journal" : /Reminders and folder/.test(v.errorText) ? "todos" : ""
  readonly property string statusName: {
    var clock = app.clock(app.recordingSeconds)
    var silent = noSignal && !said ? ". No sound from the microphone" : ""
    var busy = said ? ". " + said : ""
    switch (shownMode) {
    case "holding": case "locked": return "Recording, " + clock + silent + busy
    case "journal": return (!takeDay ? "Recording a journal entry"
        : takeLater ? "Recording a note for " + takeDay
        : "Recording a journal entry for " + takeDay) + ", " + clock + silent + busy
    case "todo": return "Recording to-dos" + (listed ? " for " + (v.todoList || "Inbox") : "") + ", " + clock + silent + busy
    case "processing": return processingText
    case "success": return "Pasted"
    case "copied": return copiedTitle + (pasteMissed ? ". It's copied. The paste did not reach the window." : "")
      + (v.feedbackError && v.feedback ? ". " + withoutPointer(v.feedback) : "")
    case "copy-failed": return "Not copied. " + v.errorText
    case "notice": return noticeShown
    case "error": return errorTitle + (downloadPercent >= 0 ? ", " + downloadPercent + "%" : "") + ". " + errorShown
    case "journal-saved": return savedTitle + (v.feedbackError && v.feedback ? ". " + withoutPointer(v.feedback) : "")
    case "todos-saved": return addedTitle + (listed ? " " + (savedList || "Inbox") : "") + (v.feedbackError && v.feedback ? ". " + v.feedback : "")
    }
    return ""
  }

  // A take that has heard nothing for its first seconds says so, while there
  // is still time to check the microphone. Once a voice comes through it
  // stays quiet, so a pause to think does not raise it.
  property bool heard: false
  readonly property bool noSignal: recordingModes.indexOf(mode) >= 0 && app.recordingSeconds >= 3 && !heard && !app.micDetected
  // Something said while a take records, such as a journal shortcut pressed
  // mid-dictation, shows beside the voice for a few seconds; the recording
  // keeps the card, so it would otherwise go unseen.
  property string said: ""
  Timer { id: saidFor; interval: 4000; onTriggered: overlay.said = "" }

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
  // Open goes to the list the capture went to, the Inbox included.
  readonly property string savedRoute: listed ? "todos/list:" + savedList : "todos"
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

  // The width of the take a processing card replaced, or 0.
  property real takeWidth: 0

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
  // A menu left open would hold the card for good, so it closes a moment
  // after the pointer leaves both, long enough to cross the gap between them.
  onPointedChanged: if (pointed) menuLeave.stop(); else if (listMenu.open) menuLeave.restart()
  Timer { id: menuLeave; interval: 800; onTriggered: if (!overlay.pointed) overlay.closeMenu() }
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
    function onMicDetectedChanged() { if (overlay.app.micDetected) overlay.heard = true }
    function onFeedbackSerialChanged() {
      if (overlay.recordingModes.indexOf(overlay.mode) < 0 || !overlay.app.feedback) return
      overlay.said = overlay.app.feedback
      saidFor.restart()
    }
  }

  onModeChanged: {
    if (recordingModes.indexOf(mode) < 0) heard = false
    else if (app.micDetected) heard = true
    if (mode !== "idle") {
      var before = shownMode
      // Stopping a take leaves the card its width, so Discard stays put
      // instead of sliding under the pointer that clicked Stop.
      takeWidth = mode === "processing" && recordingModes.indexOf(before) >= 0 ? content.implicitWidth : 0
      shownMode = mode
      // A take that grows (held, then locked) keeps its waveform steady;
      // anything else swaps its words in as the card reshapes.
      var steady = recordingModes.indexOf(before) >= 0 && recordingModes.indexOf(mode) >= 0
      if (before !== "idle" && card.opacity > 0 && !steady && Theme.motion) swap.restart()
    }
    listMenu.open = false
    editingIndex = -1
    said = ""
    todosChanged = false
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
    UiText { anchors.centerIn: parent; text: "Esc"; font.pixelSize: 10; weight: Font.DemiBold; muted: !ringMouse.containsMouse }
    MouseArea { id: ringMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overlay.app.dismiss() }
    Accessible.role: Accessible.Button
    Accessible.name: "Close the card"
    Accessible.onPressAction: overlay.app.dismiss()
  }

  // Throws a failed take's kept recording away. With only the card holding
  // it, Esc leaves the card alone, so this is the one way, and it says so.
  component DiscardKept: Pill {
    kind: "ghost"
    text: "Discard"
    verticalPadding: 4
    hint: "Throw the recording away"
    Accessible.name: "Discard the recording"
    onClicked: overlay.app.command(["discard"])
  }

  // Discard on a take in progress. A long one is a lot to lose to a slip
  // beside Stop, so past 15 seconds the first click asks, naming how much,
  // and a second within 3 seconds throws it away.
  component DiscardTake: Pill {
    id: discardTake
    signal confirmed()
    property string thing: ""
    property bool asking: false
    anchors.verticalCenter: parent.verticalCenter
    kind: asking ? "danger" : "ghost"
    text: asking ? "Discard " + overlay.app.clock(overlay.app.recordingSeconds) + "?" : "Discard"
    verticalPadding: 4
    hint: asking ? "Click again to throw " + thing + " away" : "Throw " + thing + " away"
    Timer { id: askFor; interval: 3000; onTriggered: discardTake.asking = false }
    onClicked: {
      if (asking || overlay.app.recordingSeconds < 15) { confirmed(); return }
      asking = true
      askFor.restart()
    }
  }

  // Opens the settings page the card's words name.
  component SettingsLink: Pill {
    property string page: ""
    visible: page !== ""
    kind: "fill"
    text: overlay.settingsLabels[page] || ""
    verticalPadding: 4
    onClicked: overlay.app.showWindow("settings/" + page)
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
      // A long list name ends in an ellipsis so the card keeps its shape.
      UiText { anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, 160); elide: Text.ElideRight; text: chip.list || "Inbox"; weight: Font.DemiBold }
      Icon { anchors.verticalCenter: parent.verticalCenter; name: "down"; size: 9; color: Theme.secondary }
    }
    MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overlay.toggleMenu(chip) }
    Accessible.role: Accessible.ComboBox
    Accessible.name: "List: " + (chip.list || "Inbox")
    Accessible.onPressAction: overlay.toggleMenu(chip)
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
          UiText { x: 28; anchors.verticalCenter: parent.verticalCenter; width: parent.width - x - 30; elide: Text.ElideRight; text: modelData || "Inbox" }
          Icon { visible: modelData === overlay.chipList; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 11; color: Theme.text }
          MouseArea { id: itemMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overlay.pickList(modelData) }
          Accessible.role: Accessible.MenuItem
          Accessible.name: modelData || "Inbox"
          Accessible.onPressAction: overlay.pickList(modelData)
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
    Accessible.role: Accessible.StatusBar
    Accessible.name: overlay.statusName

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
  // Said beside the voice, where the flat line already hints at it.
  component NoSignal: UiText {
    visible: overlay.noSignal && !overlay.said
    text: "No sound from the microphone"
    color: Theme.yellowText
  }
  // And what was said meanwhile, in the same place.
  component Said: UiText {
    visible: overlay.said !== ""
    text: overlay.said
  }

  Component {
    id: holding
    Row {
      spacing: 10
      Live { anchors.verticalCenter: parent.verticalCenter }
      NoSignal { anchors.verticalCenter: parent.verticalCenter }
      Said { anchors.verticalCenter: parent.verticalCenter }
    }
  }

  Component {
    id: locked
    Row {
      spacing: 10
      Live { anchors.verticalCenter: parent.verticalCenter }
      NoSignal { anchors.verticalCenter: parent.verticalCenter }
      Said { anchors.verticalCenter: parent.verticalCenter }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.app.clock(overlay.app.recordingSeconds); muted: true; font.features: { "tnum": 1 } }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Stop"; verticalPadding: 4; hint: overlay.app.pasteMode === "clipboard" ? "Stop and copy the words" : "Stop and paste the words"; onClicked: overlay.app.stopRecording() }
      DiscardTake { thing: "this dictation"; onConfirmed: overlay.app.cancel() }
    }
  }

  Component {
    id: journalTake
    Row {
      spacing: 10
      Live { anchors.verticalCenter: parent.verticalCenter }
      NoSignal { anchors.verticalCenter: parent.verticalCenter }
      Said { anchors.verticalCenter: parent.verticalCenter }
      // The one thing that differs from a locked dictation: the words go to
      // the journal, not into the app you are in. Another day stands out
      // from the clock, as a list does on a to-do take, so "Fri 2 Oct" and
      // "0:09" never read as a time on that day.
      UiText { anchors.verticalCenter: parent.verticalCenter; text: !overlay.takeDay ? "Journal" : overlay.takeLater ? "Note for" : "Journal for"; muted: true }
      UiText { anchors.verticalCenter: parent.verticalCenter; visible: overlay.takeDay !== ""; text: overlay.takeDay; weight: Font.DemiBold }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.app.clock(overlay.app.recordingSeconds); muted: true; font.features: { "tnum": 1 } }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Stop"; verticalPadding: 4; hint: overlay.app.journalShortcut ? "Stop and save the entry. " + overlay.app.journalShortcut + " does the same." : "Stop and save the entry."; onClicked: overlay.app.journalToggle() }
      DiscardTake { thing: "the entry"; onConfirmed: overlay.app.journalDiscard() }
    }
  }

  Component {
    id: todoTake
    Row {
      spacing: 10
      Live { anchors.verticalCenter: parent.verticalCenter }
      NoSignal { anchors.verticalCenter: parent.verticalCenter }
      Said { anchors.verticalCenter: parent.verticalCenter }
      // As with the journal: the same card, and where it goes.
      UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.listed ? "To-dos for" : "To-dos"; muted: true }
      ListChip { anchors.verticalCenter: parent.verticalCenter; visible: overlay.listed; list: overlay.v.todoList }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.app.clock(overlay.app.recordingSeconds); muted: true; font.features: { "tnum": 1 } }
      Pill { anchors.verticalCenter: parent.verticalCenter; kind: "fill"; text: "Stop"; verticalPadding: 4; hint: overlay.app.todoShortcut ? "Stop and add the to-dos. " + overlay.app.todoShortcut + " does the same." : "Stop and add the to-dos."; onClicked: overlay.app.todoToggle() }
      DiscardTake { thing: "the to-dos"; onConfirmed: overlay.app.todoDiscard() }
    }
  }

  Component {
    id: processing
    Item {
      id: working
      // As wide as the take it replaces, with Discard where Discard was.
      // A second click on Stop still lands on the card in that moment, so
      // Discard waits a little before it counts as a choice.
      implicitWidth: Math.max(says.implicitWidth + 10 + discard.implicitWidth, overlay.takeWidth)
      implicitHeight: Math.max(says.implicitHeight, discard.implicitHeight)
      property bool armed: false
      Timer { interval: 400; running: true; onTriggered: working.armed = true }
      Row {
        id: says
        anchors.verticalCenter: parent.verticalCenter
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
              // Held still when the desktop turns animations off.
              SequentialAnimation on opacity {
                running: Theme.motion
                loops: Animation.Infinite
                PauseAnimation { duration: index * 160 }
                NumberAnimation { to: 1; duration: 260 }
                NumberAnimation { to: 0.35; duration: 260 }
                PauseAnimation { duration: (2 - index) * 160 }
              }
            }
          }
        }
        UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.processingText }
      }
      Pill {
        id: discard
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        kind: "ghost"
        text: "Discard"
        verticalPadding: 4
        hint: overlay.v.journalTake ? "Throw the entry away" : overlay.v.todoTake ? "Throw the to-dos away" : "Throw this dictation away"
        onClicked: if (working.armed) overlay.app.cancel()
      }
    }
  }

  // What went wrong on the way, under a card that still did its job.
  component Warning: UiText {
    visible: overlay.v.feedbackError && text.length > 0
    text: overlay.withoutPointer(overlay.v.feedback)
    color: Theme.yellowText
    font.pixelSize: 12
    wrapMode: Text.Wrap
  }

  Component {
    id: success
    Row {
      spacing: 9
      Icon { anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 13; color: Theme.greenText }
      UiText { anchors.verticalCenter: parent.verticalCenter; text: "Pasted"; weight: Font.DemiBold }
    }
  }

  // A clipboard, for words that wait there for you to paste them: nothing
  // went wrong, there is one step left.
  component ClipboardGlyph: Shape {
    width: 12; height: 14
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeWidth: 1.3
      strokeColor: Theme.text
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: "M3.2 2.2H2.1c-.6 0-1.1.5-1.1 1.1v9.1c0 .6.5 1.1 1.1 1.1h7.8c.6 0 1.1-.5 1.1-1.1V3.3c0-.6-.5-1.1-1.1-1.1H8.8M4 .9h4c.4 0 .8.4.8.8v1.1c0 .4-.4.8-.8.8H4c-.4 0-.8-.4-.8-.8V1.7c0-.4.4-.8.8-.8Z" }
    }
  }

  Component {
    id: copied
    Column {
      spacing: 6
      // One capsule, or with a warning the words under it and Esc in the top
      // right corner, as on the other tall cards.
      width: overlay.tall ? Math.min(560, Math.max(head.implicitWidth + 40, 360)) : head.implicitWidth + 9 + 28
      Item {
        width: parent.width
        height: 28
        Row {
          id: head
          anchors.verticalCenter: parent.verticalCenter
          spacing: 9
          Icon { anchors.verticalCenter: parent.verticalCenter; visible: !overlay.pasteMissed; name: "check"; size: 13; color: overlay.v.feedbackError ? Theme.yellowText : Theme.greenText }
          ClipboardGlyph { anchors.verticalCenter: parent.verticalCenter; visible: overlay.pasteMissed }
          UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.copiedTitle; weight: Font.DemiBold }
          UiText {
            anchors.verticalCenter: parent.verticalCenter
            visible: overlay.pasteMissed
            text: "It's copied. The paste did not reach the window."
            muted: true
          }
        }
        EscRing { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
      }
      Warning { width: parent.width }
      SettingsLink { page: overlay.warned ? overlay.settingsPage(overlay.v.feedback) : "" }
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
          Pill { anchors.verticalCenter: parent.verticalCenter; kind: "primary"; text: "Copy again"; verticalPadding: 4; onClicked: overlay.app.copyAgain() }
        }
        // With History off the card is the words' only copy, so Esc leaves
        // it alone, as it does a recording only the card holds.
        Pill { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; visible: overlay.holdsWords; kind: "ghost"; text: "Discard"; verticalPadding: 4; hint: "Throw the words away"; Accessible.name: "Discard the words"; onClicked: overlay.app.command(["discard"]) }
        EscRing { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; visible: !overlay.holdsWords }
      }
      UiText { width: parent.width; text: overlay.v.errorText; muted: true; font.pixelSize: 12; wrapMode: Text.Wrap }
    }
  }

  // A notice that names a settings page opens it, and waits like any card
  // you can act on. A long one wraps, with its button under the words.
  Component {
    id: notice
    Row {
      spacing: 9
      UiText { anchors.verticalCenter: parent.verticalCenter; visible: !overlay.longNotice; text: overlay.noticeShown; muted: true }
      Column {
        visible: overlay.longNotice
        spacing: 8
        UiText { width: 420; text: overlay.noticeShown; muted: true; wrapMode: Text.Wrap }
        SettingsLink { page: overlay.noticePage }
      }
      SettingsLink { anchors.verticalCenter: parent.verticalCenter; visible: !overlay.longNotice && page !== ""; page: overlay.noticePage }
      // Top right on a long one, as on the other two-line cards.
      EscRing { anchors.verticalCenter: overlay.longNotice ? undefined : parent.verticalCenter; visible: overlay.noticePage !== "" }
    }
  }

  Component {
    id: failed
    Column {
      spacing: 6
      width: Math.min(560, Math.max(head.implicitWidth + 12 + ends.implicitWidth, 360))
      Item {
        width: parent.width
        height: 28
        Row {
          id: head
          anchors.verticalCenter: parent.verticalCenter
          spacing: 9
          Icon { anchors.verticalCenter: parent.verticalCenter; name: overlay.ready ? "check" : "warning"; size: overlay.ready ? 13 : 15
            color: overlay.ready ? Theme.greenText : overlay.waiting ? Theme.yellowText : Theme.redText }
          UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.errorTitle; weight: Font.DemiBold }
          Row {
            anchors.verticalCenter: parent.verticalCenter
            visible: overlay.downloadPercent >= 0
            spacing: 6
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 56; height: 5; radius: 2.5; color: Theme.fill18
              Rectangle { width: parent.width * Math.max(0, overlay.downloadPercent) / 100; height: parent.height; radius: 2.5; color: Theme.accent }
            }
            UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.downloadPercent + "%"; muted: true }
          }
          // Nothing to transcribe with yet: the way to fix that, one click away.
          Pill { anchors.verticalCenter: parent.verticalCenter; visible: overlay.v.errorAction === "choose_model"; kind: "primary"; text: "Choose a model"; verticalPadding: 4; hint: "Open Settings, Models"; onClicked: overlay.app.showWindow("settings/models") }
          // The recording is kept: send it again instead of saying it again.
          // Not while the model downloads: it would only fail the same way.
          Pill { anchors.verticalCenter: parent.verticalCenter; visible: overlay.v.canRetry && !(overlay.v.errorAction === "downloading" && overlay.app.speechDownloading); kind: overlay.v.errorAction === "choose_model" ? "fill" : "primary"; text: "Try again"; verticalPadding: 4; hint: "Transcribe the same recording again"; onClicked: overlay.app.retry() }
          // The words are on the clipboard; the folder to check is one page away.
          Pill { anchors.verticalCenter: parent.verticalCenter; visible: overlay.failedPlace !== ""; kind: "primary"; text: "Open"; verticalPadding: 4; hint: overlay.failedPlace === "journal" ? "Open the journal" : "Open the to-dos"; onClicked: overlay.app.showWindow(overlay.failedPlace) }
        }
        Row {
          id: ends
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6
          // One saved in History is deleted there, where its Undo is.
          DiscardKept { anchors.verticalCenter: parent.verticalCenter; visible: overlay.holdsRecording }
          EscRing { anchors.verticalCenter: parent.verticalCenter; visible: !overlay.holdsRecording }
        }
      }
      UiText { width: parent.width; text: overlay.errorShown; muted: true; font.pixelSize: 12; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
      SettingsLink { page: overlay.v.errorAction ? "" : overlay.settingsPage(overlay.v.errorText) }
    }
  }

  Component {
    id: saved
    Column {
      spacing: 6
      // Laid out like the pasted card: one capsule, or with a warning the
      // words under it and Esc in the top right corner.
      width: overlay.tall ? Math.min(560, Math.max(head.implicitWidth + 40, 360)) : head.implicitWidth + 9 + 28
      Item {
        width: parent.width
        height: 28
        Row {
          id: head
          anchors.verticalCenter: parent.verticalCenter
          spacing: 9
          Icon { anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 13; color: overlay.v.feedbackError ? Theme.yellowText : Theme.greenText }
          UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.savedTitle; weight: Font.DemiBold }
          UiText {
            anchors.verticalCenter: parent.verticalCenter
            visible: overlay.v.journalSaved !== null
            text: overlay.v.journalSaved
              // Words first, so a date is never followed by what reads as a time.
              ? overlay.v.journalSaved.words + (overlay.v.journalSaved.words === 1 ? " word, " : " words, ") + overlay.app.clock(overlay.v.journalSaved.duration_ms / 1000)
              : ""
            muted: true
          }
          Pill { anchors.verticalCenter: parent.verticalCenter; kind: "primary"; text: "Open"; verticalPadding: 4; hint: "Open the journal on that day"; onClicked: overlay.app.showWindow(overlay.savedDate ? "journal/" + overlay.savedDate : "journal") }
        }
        EscRing { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
      }
      Warning { width: parent.width }
      SettingsLink { page: overlay.warned ? overlay.settingsPage(overlay.v.feedback) : "" }
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
          UiText { anchors.verticalCenter: parent.verticalCenter; text: overlay.addedTitle; weight: Font.DemiBold }
          ListChip { anchors.verticalCenter: parent.verticalCenter; visible: overlay.listed; list: overlay.savedList }
          Pill { anchors.verticalCenter: parent.verticalCenter; kind: "primary"; text: "Open"; verticalPadding: 4; hint: overlay.listed ? "Open " + (overlay.savedList || "Inbox") : "Open the to-dos"; onClicked: overlay.app.showWindow(overlay.savedRoute) }
          // After a move, an edit or a × it no longer undoes the last step,
          // so it says what it does; the chip moves them back.
          Pill { anchors.verticalCenter: parent.verticalCenter; kind: "ghost"; text: overlay.undoTakesOut ? "Take out" : "Undo"; verticalPadding: 4; hint: "Take these to-dos back out"; onClicked: overlay.app.todoUndo() }
        }
        EscRing { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
      }
      Column {
        width: parent.width
        Repeater {
          model: added.items.slice(0, added.shown)
          TodoLine { width: added.width }
        }
        Pill {
          visible: added.items.length > added.shown
          x: 24 - horizontalPadding
          kind: "link"
          verticalPadding: 4
          text: "and " + (added.items.length - added.shown) + " more"
          hint: overlay.listed ? "Open " + (overlay.savedList || "Inbox") : "Open the to-dos"
          onClicked: overlay.app.showWindow(overlay.savedRoute)
        }
      }
      Warning { width: parent.width }
    }
  }

  // One added to-do: click the words to fix them, Enter keeps the change,
  // Esc drops it, × takes the to-do out.
  component TodoLine: Item {
    id: line
    required property var modelData
    readonly property bool editing: overlay.editingIndex === modelData.index
    height: Math.max(30, (line.editing ? editor.contentHeight + 4 + keys.implicitHeight : words.implicitHeight) + 10)
    HoverHandler { id: lineHover }
    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -8; anchors.rightMargin: -8
      radius: 8
      color: line.editing ? Theme.fill8 : lineHover.hovered ? Theme.fill4 : "transparent"
    }
    // A bullet, not a tick box: ticking happens in the list, not here.
    Rectangle {
      x: 5; y: 13
      width: 5; height: 5; radius: 2.5
      color: Theme.secondary
    }
    UiText {
      id: words
      visible: !line.editing
      x: 24; y: 5
      width: (cardBell.visible ? cardBell.x : dueText.x) - x - 10
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
      Accessible.onPressAction: overlay.editingIndex = line.modelData.index
    }
    // Wraps like the words it replaces, so a long to-do stays readable.
    TextEdit {
      id: editor
      visible: line.editing
      x: 24; y: 5
      width: (cardBell.visible ? cardBell.x : dueText.x) - x - 10
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
        if (keep && next.length > 0 && next !== line.modelData.text) overlay.editTodo(line.modelData, next)
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
      id: keys
      visible: line.editing
      x: 24; y: editor.y + editor.contentHeight + 4
      text: "Enter keeps the change, Esc drops it"
      muted: true
      font.pixelSize: 11
    }
    // A reminder said with it, read back: when, or that there is none.
    Row {
      id: cardBell
      readonly property string reminder: line.modelData.reminder && line.modelData.time ? String(line.modelData.reminder) : ""
      visible: reminder.length > 0
      anchors.right: dueText.left
      anchors.rightMargin: 8
      y: 5
      height: dueText.height
      spacing: 4
      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: cardBell.reminder === "off" ? "bell-off" : "bell"
        size: 11
        color: cardBell.reminder === "off" ? Theme.secondary : Theme.accentText
      }
      UiText {
        id: cardBellTime
        visible: cardBell.reminder !== "off"
        anchors.verticalCenter: parent.verticalCenter
        text: cardBell.reminder && cardBell.reminder !== "off"
          ? Dates.remindAt(cardBell.reminder, String(line.modelData.due), overlay.app.todayIso()) : ""
        color: Theme.accentText
      }
      Accessible.name: cardBell.reminder === "off" ? "No reminder" : "Reminds you " + cardBellTime.text
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
      MouseArea { id: removeMouse; anchors.fill: parent; enabled: parent.opacity > 0; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overlay.removeTodo(line.modelData) }
      Accessible.role: Accessible.Button
      Accessible.name: "Take out " + line.modelData.text
    }
  }
}
