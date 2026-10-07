import QtQuick
import QtQuick.Layouts

// The window: who you are looking at, where you are, and whether OmaFlow is
// fine, then one of three places. Hyprland draws the frame around it.
Rectangle {
  id: view

  required property var app
  // False while the host has the window hidden; pages pause their live parts.
  property bool shown: true
  property string page: "history"
  property string settingsPage: "basics"
  readonly property var pages: [
    { key: "history", label: "History" },
    { key: "journal", label: "Journal" },
    { key: "todos", label: "To-dos" },
    { key: "settings", label: "Settings" }
  ]

  // A route from outside the window: "journal" opens today,
  // "journal/2026-09-25" that day, "todos/today" or "todos/list:Infra" ("todos/list:"
  // is the Inbox) a view, "settings/models" a settings page. An empty route
  // keeps the page you were on.
  function show(target) {
    var route = String(target || "")
    var slash = route.indexOf("/")
    var place = slash < 0 ? route : route.slice(0, slash)
    var rest = slash < 0 ? "" : route.slice(slash + 1)
    if (place === "") { Qt.callLater(focusPage); return }
    if (["history", "journal", "todos", "settings"].indexOf(place) < 0) return
    page = place
    if (place === "journal") journal.openDay(/^\d{4}-\d{2}-\d{2}$/.test(rest) ? rest : app.todayIso())
    if (place === "settings" && rest) settingsPage = rest
    if (place === "todos" && rest) todos.openOn(rest)
    Qt.callLater(focusPage)
  }
  // The tabs and Ctrl+1 to 4 only switch places; each keeps where it was.
  function switchTo(place) {
    page = place
    Qt.callLater(focusPage)
  }
  function focusPage() {
    var screen = page === "journal" ? journal : page === "todos" ? todos : page === "settings" ? settings : history
    screen.forceActiveFocus()
  }

  color: Theme.background
  focus: true

  // What OmaFlow says about the last thing you asked of it, over whichever
  // page is open. Every message shows, even the same words twice in a row,
  // for as long as the notice or error time in the settings says.
  property string toast: ""
  property bool toastError: false
  // A message from the window itself, which has nothing to undo.
  property bool toastLocal: false
  readonly property bool toastCovered: (page === "journal" && journal.toast.length > 0) || (page === "todos" && todos.toast.length > 0)
  readonly property bool undoOffered: toast.length > 0 && !toastLocal && !toastCovered && app.canUndoDelete
  function flash(message, error, local) {
    toast = message
    toastError = Boolean(error)
    toastLocal = Boolean(local)
    toastTimer.interval = toastError ? app.errorVisibleMs : app.noticeVisibleMs
    toastTimer.restart()
  }
  function undo() {
    app.undoDelete()
    toast = ""
  }
  Connections {
    target: view.app
    function onFeedbackSerialChanged() {
      if (view.app.feedback.length > 0) view.flash(view.app.feedback, view.app.feedbackError, false)
    }
    function onToast(message, error) { view.flash(message, error, true) }
  }
  // Held while the pointer or focus is on it; it goes once they leave.
  Timer { id: toastTimer; interval: 5000; onTriggered: if (!windowToast.held) view.toast = "" }
  // An error that arrived while a page's own message covered it gets its
  // full time once that message goes.
  onToastCoveredChanged: if (!toastCovered && toast.length > 0 && toastError) toastTimer.restart()

  Keys.onPressed: function(event) {
    if (event.modifiers & Qt.ControlModifier) {
      var index = event.key - Qt.Key_1
      var current = view.pages.findIndex(function(p) { return p.key === view.page })
      if (index >= 0 && index < view.pages.length) { view.switchTo(view.pages[index].key); event.accepted = true }
      else if (event.key === Qt.Key_Backtab) {
        view.switchTo(view.pages[(current + view.pages.length - 1) % view.pages.length].key)
        event.accepted = true
      } else if (event.key === Qt.Key_Tab) {
        view.switchTo(view.pages[(current + 1) % view.pages.length].key)
        event.accepted = true
      } else if (event.key === Qt.Key_Z && view.undoOffered) { view.undo(); event.accepted = true }
    }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    // ---------------------------------------------------------------- header
    Item {
      id: header
      Layout.fillWidth: true
      Layout.preferredHeight: 58

      // With an update to look at, the mark carries a dot and opens it.
      Rectangle {
        id: brand
        readonly property bool link: view.app.updateAttention
        readonly property string hint: !link ? ""
          : (view.app.updateFailed ? "An update did not finish"
            : view.app.updateRunning ? "Updating"
            : view.app.updateOffer.externalCheckoutWarning ? "The OmaFlow folder changed"
            : "Update ready") + ". Opens Settings, Advanced, Updates and app"
        x: 14
        anchors.verticalCenter: parent.verticalCenter
        width: brandRow.implicitWidth + 12
        height: 32
        radius: height / 2
        color: link && brandMouse.containsMouse ? Theme.fill8 : "transparent"
        activeFocusOnTab: link
        Rectangle {
          anchors.fill: parent
          anchors.margins: -3
          radius: height / 2
          color: "transparent"
          border.width: 2
          border.color: Theme.accent
          visible: brand.activeFocus
        }
        Row {
          id: brandRow
          anchors.centerIn: parent
          spacing: 10
          // A state colour, not the accent, so the dot does not read as part
          // of the mark: a red ring for an update that did not finish.
          Mark { anchors.verticalCenter: parent.verticalCenter; badge: brand.link; badgeColor: view.app.updateFailed ? Theme.red : Theme.yellow; badgeRing: view.app.updateFailed }
          UiText {
            anchors.verticalCenter: parent.verticalCenter
            text: "OmaFlow"
            font.pixelSize: 15
            weight: Font.Bold
          }
        }
        MouseArea {
          id: brandMouse
          anchors.fill: parent
          enabled: brand.link
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.show("settings/updates")
          onContainsMouseChanged: if (containsMouse) view.hoveredTab = brand; else if (view.hoveredTab === brand) view.hoveredTab = null
        }
        Keys.onReturnPressed: if (link) view.show("settings/updates")
        Keys.onSpacePressed: if (link) view.show("settings/updates")
        Accessible.role: link ? Accessible.Link : Accessible.StaticText
        Accessible.name: link ? hint : "OmaFlow"
        Accessible.onPressAction: if (link) view.show("settings/updates")
      }

      // The status line's natural width, so the tabs can make room for it.
      TextMetrics { id: statusMetrics; font.family: Theme.sans; font.pixelSize: 13; text: view.app.statusText }
      readonly property real statusNeed: 15 + Math.ceil(statusMetrics.advanceWidth) + (status.visible ? 8 : 0)
        + (statusButton.visible ? statusButton.implicitWidth + 8 : 0)
      // Room the status may use right of the tabs; it shortens only past that.
      readonly property real statusRoom: width - 20 - (tabs.x + tabs.width) - 24

      // Centred, unless a long status needs the space: then the tabs move
      // left first, and only past the mark does the status shorten.
      Row {
        id: tabs
        x: Math.max(brand.x + brand.width + 24,
          Math.min(Math.round((parent.width - width) / 2), parent.width - 20 - header.statusNeed - 24 - width))
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4
        Repeater {
          model: view.pages
          Pill {
            id: tab
            required property var modelData
            required property int index
            kind: "ghost"
            text: modelData.label
            size: 14
            horizontalPadding: 14
            verticalPadding: 6
            selected: view.page === modelData.key
            // The fill shows which tab is open; a bolder label would nudge the row.
            bold: false
            hint: "Ctrl+" + (index + 1)
            Accessible.role: Accessible.PageTab
            Accessible.selected: selected
            onClicked: view.switchTo(modelData.key)
            onHoveredChanged: if (hovered) view.hoveredTab = tab; else if (view.hoveredTab === tab) view.hoveredTab = null
          }
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: 7; height: 7; radius: 3.5
          color: view.app.statusTone === "red" ? Theme.red
            : view.app.statusTone === "yellow" ? Theme.yellow : Theme.green
        }
        UiText {
          visible: !status.visible
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, header.statusRoom - 15 - (statusButton.visible ? statusButton.implicitWidth + 8 : 0))
          elide: Text.ElideRight
          text: view.app.statusText
          muted: true
        }
        // Not installed yet, no speech model, or partly updated: the line is
        // the way to fix it. On History the install command is already on
        // the page, so there it is only the line.
        Pill {
          id: status
          visible: ["install", "models", "updates"].indexOf(view.app.statusAction) >= 0
            && !(view.app.statusAction === "install" && view.page === "history")
          anchors.verticalCenter: parent.verticalCenter
          kind: "link"
          text: view.app.statusText
          size: 13
          horizontalPadding: 4
          verticalPadding: 2
          labelMaximumWidth: header.statusRoom - 15 - 8
          hint: view.app.statusAction === "models" ? "Opens Settings, Advanced, Models"
            : view.app.statusAction === "updates" ? "Opens Settings, Advanced, Updates and app"
            : "Shows the command that finishes installing"
          onClicked: view.show(view.app.statusAction === "models" ? "settings/models"
            : view.app.statusAction === "updates" ? "settings/updates" : "history")
        }
        // While it runs, the line beside it says so, and the button steps
        // aside so the line keeps its words in a narrow window.
        Pill {
          id: statusButton
          visible: (view.app.statusAction === "start" || view.app.statusAction === "restart") && view.app.pendingAction === ""
          anchors.verticalCenter: parent.verticalCenter
          kind: "outline"
          text: view.app.statusAction === "restart" ? "Restart" : "Start"
          Accessible.name: view.app.statusAction === "restart" ? "Restart the speech model" : "Start OmaFlow"
          onClicked: view.app.statusAction === "restart" ? view.app.restartSpeech() : view.app.start()
        }
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Theme.divider
      }
    }

    // ------------------------------------------------------------- places
    StackLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      currentIndex: view.page === "journal" ? 1 : view.page === "todos" ? 2 : view.page === "settings" ? 3 : 0

      HistoryScreen {
        id: history
        app: view.app
        onOpenSettings: function(target) { view.show("settings/" + target) }
        onFlash: function(message) { view.flash(message, false, true) }
        onUndoRequested: if (view.undoOffered) view.undo()
      }
      JournalScreen { id: journal; app: view.app; active: view.shown && view.page === "journal" }
      TodosScreen { id: todos; app: view.app; active: view.shown && view.page === "todos" }
      SettingsScreen { id: settings; app: view.app; page: view.settingsPage; active: view.shown && view.page === "settings"; onPageChanged: view.settingsPage = page }
    }
  }

  // A tab's shortcut, under the tab while the pointer rests on it.
  property Item hoveredTab: null
  onHoveredTabChanged: { tabHint.shown = null; if (hoveredTab) tabHintDelay.restart(); else tabHintDelay.stop() }
  // A short rest first, so passing over the tabs shows nothing.
  Timer { id: tabHintDelay; interval: 450; onTriggered: tabHint.shown = view.hoveredTab }
  Rectangle {
    id: tabHint
    property Item shown: null
    readonly property point at: shown ? shown.mapToItem(view, shown.width / 2, shown.height) : Qt.point(0, 0)
    visible: shown !== null
    z: 10
    x: Math.max(8, Math.min(view.width - width - 8, Math.round(at.x - width / 2)))
    y: Math.round(at.y + 6)
    width: hintText.implicitWidth + 14
    height: hintText.implicitHeight + 8
    radius: Theme.radiusInput
    color: Theme.fill18
    UiText { id: hintText; anchors.centerIn: parent; text: tabHint.shown ? tabHint.shown.hint : ""; font.pixelSize: 12 }
  }

  // The journal and to-do pages say what their own actions did in the same
  // spot, above the composer; while theirs shows, this one steps aside.
  Toast {
    id: windowToast
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: view.page === "journal" || view.page === "todos" ? 104 : 20
    message: view.toastCovered ? "" : view.toast
    error: view.toastError
    actionText: view.undoOffered ? "Undo" : ""
    actionShortcut: view.undoOffered ? "Ctrl+Z" : ""
    onAction: view.undo()
    onHeldChanged: if (!held && view.toast.length > 0) toastTimer.restart()
  }
}
