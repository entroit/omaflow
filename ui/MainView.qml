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

  function show(target) {
    var parts = String(target || "history").split("/")
    if (["history", "journal", "todos", "settings"].indexOf(parts[0]) < 0) return
    page = parts[0]
    if (parts[0] === "settings" && parts.length > 1) settingsPage = parts[1]
    Qt.callLater(focusPage)
  }
  function focusPage() {
    var screen = page === "journal" ? journal : page === "todos" ? todos : page === "settings" ? settings : history
    screen.forceActiveFocus()
  }

  color: Theme.background
  focus: true

  Keys.onPressed: function(event) {
    if (event.modifiers & Qt.ControlModifier) {
      var index = event.key - Qt.Key_1
      if (index >= 0 && index < view.pages.length) { view.show(view.pages[index].key); event.accepted = true }
      else if (event.key === Qt.Key_Tab) {
        var current = view.pages.findIndex(function(p) { return p.key === view.page })
        view.show(view.pages[(current + 1) % view.pages.length].key)
        event.accepted = true
      }
    }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    // ---------------------------------------------------------------- header
    Item {
      Layout.fillWidth: true
      Layout.preferredHeight: 58

      Row {
        anchors.left: parent.left
        anchors.leftMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10
        Mark { anchors.verticalCenter: parent.verticalCenter; badge: view.app.updateAttention; badgeColor: Theme.accent }
        UiText {
          anchors.verticalCenter: parent.verticalCenter
          text: "OmaFlow"
          font.pixelSize: 15
          weight: Font.Bold
        }
      }

      Row {
        anchors.centerIn: parent
        spacing: 4
        Repeater {
          model: view.pages
          Pill {
            required property var modelData
            kind: "ghost"
            text: modelData.label
            size: 14
            horizontalPadding: 14
            verticalPadding: 6
            selected: view.page === modelData.key
            Accessible.role: Accessible.PageTab
            onClicked: view.show(modelData.key)
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
          anchors.verticalCenter: parent.verticalCenter
          text: view.app.statusText
          muted: true
        }
        Pill {
          visible: !view.app.connected && view.app.binaryFound
          anchors.verticalCenter: parent.verticalCenter
          kind: "outline"
          text: "Start"
          onClicked: view.app.start()
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

      HistoryScreen { id: history; app: view.app; onOpenSettings: function(target) { view.show("settings/" + target) } }
      JournalScreen { id: journal; app: view.app; active: view.shown && view.page === "journal" }
      TodosScreen { id: todos; app: view.app; active: view.shown && view.page === "todos" }
      SettingsScreen { id: settings; app: view.app; page: view.settingsPage; active: view.shown && view.page === "settings"; onPageChanged: view.settingsPage = page }
    }
  }
}
