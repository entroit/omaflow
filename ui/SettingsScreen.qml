import QtQuick
import QtQuick.Layouts

// Settings: what most people change first, then the rest under Advanced.
FocusScope {
  id: screen

  required property var app
  property string page: "basics"
  property bool active: false
  readonly property var advanced: ["models", "ownmodel", "cleanup", "hotkeys", "audio", "updates"]
  property bool advancedOpen: advanced.indexOf(page) >= 0
  readonly property var sections: [
    { key: "basics", label: "Basics" },
    { key: "words", label: "Words" },
    { key: "privacy", label: "Privacy" }
  ]
  readonly property var advancedSections: [
    { key: "models", label: "Models" },
    { key: "ownmodel", label: "Your own model" },
    { key: "cleanup", label: "Cleanup" },
    { key: "hotkeys", label: "Hotkeys" },
    { key: "audio", label: "Audio" },
    { key: "updates", label: "Updates and app" }
  ]

  // The microphone meter only runs while a page that shows it is open.
  readonly property bool meterVisible: active && (page === "basics" || page === "audio")
  // OmaFlow itself saves every setting, so while it is not running nothing
  // here would stick. Updates and app works without it.
  readonly property bool saves: app.connected || page === "updates"
  onMeterVisibleChanged: app.setMeterPreview(meterVisible)
  Component.onDestruction: app.setMeterPreview(false)
  onPageChanged: { if (advanced.indexOf(page) >= 0) advancedOpen = true; flick.contentY = 0 }

  RowLayout {
    anchors.fill: parent
    spacing: 0

    Column {
      Layout.preferredWidth: 184
      Layout.fillHeight: true
      Layout.alignment: Qt.AlignTop
      topPadding: 16
      leftPadding: 10
      rightPadding: 10
      spacing: 2

      Repeater {
        model: screen.sections
        NavItem { required property var modelData; text: modelData.label; selected: screen.page === modelData.key; onClicked: screen.page = modelData.key }
      }
      NavItem {
        text: "Advanced"
        expander: true
        expanded: screen.advancedOpen
        onClicked: screen.advancedOpen = !screen.advancedOpen
      }
      // Collapsed, Advanced still shows the page you are on.
      Repeater {
        model: screen.advancedOpen ? screen.advancedSections
          : screen.advancedSections.filter(function(section) { return section.key === screen.page })
        NavItem { required property var modelData; text: modelData.label; nested: true; selected: screen.page === modelData.key; onClicked: screen.page = modelData.key }
      }
    }

    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.divider }

    Flickable {
      id: flick
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      contentWidth: width
      contentHeight: content.height + 48
      boundsBehavior: Flickable.StopAtBounds

      // Tab to a control below the fold, or above it, and the page follows.
      function reveal(item) {
        if (!item || !screen.active) return
        for (var p = item; p !== loader; p = p.parent) if (!p) return
        var top = item.mapToItem(contentItem, 0, 0).y
        var bottom = top + item.height
        if (top - 16 < contentY) contentY = Math.max(0, top - 16)
        else if (bottom + 16 > contentY + height) contentY = Math.max(0, Math.min(contentHeight - height, bottom + 16 - height))
      }
      Connections {
        target: screen.Window.window
        function onActiveFocusItemChanged() { flick.reveal(screen.Window.activeFocusItem) }
      }

      Column {
        id: content
        x: 32; y: 24
        width: flick.width - 64
        spacing: 24

        Item {
          visible: !screen.saves
          width: parent.width
          height: stopped.implicitHeight
          Icon { y: 2; name: "warning"; size: 14; color: Theme.yellow }
          UiText {
            id: stopped
            x: 24
            width: parent.width - 24
            wrapMode: Text.Wrap
            text: !screen.app.binaryFound
              ? "OmaFlow is not installed yet, so changes here are not saved. Choose Finish setup on History."
              : "OmaFlow is stopped, so changes here are not saved. Start it from the top of the window."
          }
        }

        Loader {
          id: loader
          width: parent.width
          enabled: screen.saves
          sourceComponent: screen.page === "words" ? words
            : screen.page === "privacy" ? privacy
            : screen.page === "models" ? models
            : screen.page === "ownmodel" ? ownModel
            : screen.page === "cleanup" ? cleanup
            : screen.page === "hotkeys" ? hotkeys
            : screen.page === "audio" ? audio
            : screen.page === "updates" ? updates
            : basics
        }
      }
    }
  }

  Component { id: basics; SettingsBasics { app: screen.app; onGo: function(target) { screen.page = target } } }
  Component { id: words; SettingsWords { app: screen.app } }
  Component { id: privacy; SettingsPrivacy { app: screen.app } }
  Component { id: models; SettingsModels { app: screen.app; onGo: function(target) { screen.page = target } } }
  Component { id: ownModel; SettingsOwnModel { app: screen.app; onGo: function(target) { screen.page = target } } }
  Component { id: cleanup; SettingsCleanup { app: screen.app; onGo: function(target) { screen.page = target } } }
  Component { id: hotkeys; SettingsHotkeys { app: screen.app } }
  Component { id: audio; SettingsAudio { app: screen.app } }
  Component { id: updates; SettingsUpdates { app: screen.app } }
}
