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
    { key: "updates", label: "Updates" }
  ]

  // The microphone meter only runs while a page that shows it is open.
  readonly property bool meterVisible: active && (page === "basics" || page === "audio")
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
        onClicked: { screen.advancedOpen = !screen.advancedOpen; if (screen.advancedOpen && screen.advanced.indexOf(screen.page) < 0) screen.page = "models" }
      }
      Repeater {
        model: screen.advancedOpen ? screen.advancedSections : []
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
      contentHeight: loader.height + 48
      boundsBehavior: Flickable.StopAtBounds

      Loader {
        id: loader
        x: 32; y: 24
        width: flick.width - 64
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
