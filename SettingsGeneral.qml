import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

ColumnLayout {
  id: page

  required property var flow

  spacing: Style.space(12)

  SettingsHeading {
    title: "Shortcut"
    note: "Hold to talk, double-tap to lock hands-free."
  }

  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: shortcutContent.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: Util.alpha(Color.popups.text, 0.055)

    RowLayout {
      id: shortcutContent
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(12)

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: page.flow.hotkeyDisplay
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      ActionButton {
        text: page.flow.editShortcut ? "Done" : "Change"
        foreground: Color.popups.text
        bordered: true
        onClicked: page.flow.editHotkey()
      }
    }
  }

  HotkeySettings {
    Layout.fillWidth: true
    visible: page.flow.editShortcut
    flow: page.flow
  }

  SettingsHeading {
    title: "Paste delivery"
    note: "Auto sends Ctrl+V, or Shift+Insert in terminals."
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(6)

    Repeater {
      model: [
        { "label": "Auto", "value": "auto" },
        { "label": "Ctrl+V", "value": "ctrl-v" },
        { "label": "Shift+Insert", "value": "shift-insert" },
        { "label": "Copy only", "value": "clipboard" }
      ]

      ActionButton {
        required property var modelData
        text: modelData.label
        foreground: Color.popups.text
        background: page.flow.pasteMode === modelData.value
          ? Util.alpha(Color.accent, 0.22) : "transparent"
        bordered: page.flow.pasteMode === modelData.value
        onClicked: page.flow.setPasteMode(modelData.value)
      }
    }

    Item { Layout.fillWidth: true }
  }

  SettingsHeading { title: "Memory" }

  Toggle {
    Layout.fillWidth: true
    label: "Keep models loaded"
    description: "On, the models stay resident so the hotkey answers at once. Off, they are unloaded after five idle minutes and the next dictation waits a couple of seconds while they load. Servers you run yourself are left alone."
    foreground: Color.popups.text
    checked: page.flow.keepModelsLoaded
    onClicked: page.flow.preference("keep_models_loaded", !checked)
  }

  SettingsHeading { title: "Updates" }

  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: updateContent.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: Util.alpha(Color.popups.text, 0.055)

    RowLayout {
      id: updateContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(10)
      spacing: Style.space(10)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: page.flow.updateError
            ? "Could not check for updates"
            : !page.flow.supportedState
              ? "The running daemon is newer than this panel"
              : page.flow.needsRebuild
                ? "Version " + page.flow.checkoutVersion + " is ready to install"
                : page.flow.updateAvailable
                  ? (page.flow.updateRemoteVersion
                    ? "Version " + page.flow.updateRemoteVersion + " is available"
                    : page.flow.updateBehind + (page.flow.updateBehind === 1
                      ? " new commit is available" : " new commits are available"))
                  : page.flow.updateCheckedAtMs === 0
                    ? "Updates have not been checked"
                    : "OmaFlow " + page.flow.runningVersion + " is up to date"
          color: page.flow.updateAttention ? Color.accent : Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: page.flow.updateError
            ? "Last check failed: " + page.flow.updateError
            : page.flow.needsRebuild || !page.flow.supportedState
              ? "The checkout moved but the daemon was not rebuilt. Finish update rebuilds it."
              : page.flow.updateCheckedAtMs > 0
                ? "Checked " + page.flow.formatHistoryTime(page.flow.updateCheckedAtMs).toLowerCase()
                : "Not checked yet"
          color: Util.alpha(Color.popups.text, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ActionButton {
        visible: page.flow.needsRebuild || !page.flow.supportedState
        text: "Finish update"
        foreground: Color.popups.text
        background: Util.alpha(Color.accent, 0.22)
        bordered: true
        onClicked: page.flow.finishUpdate()
      }

      ActionButton {
        visible: page.flow.updateAvailable && !page.flow.needsRebuild && page.flow.supportedState
        text: "Update"
        foreground: Color.popups.text
        background: Util.alpha(Color.accent, 0.22)
        bordered: true
        onClicked: page.flow.applyUpdate()
      }

      ActionButton {
        visible: !page.flow.updateAttention
        text: page.flow.updateChecking ? "Checking…" : "Check now"
        enabled: !page.flow.updateChecking
        foreground: Color.popups.text
        bordered: true
        onClicked: page.flow.checkForUpdate()
      }
    }
  }

  SettingsHeading {
    title: "Configuration file"
    note: "Every setting, including the cleanup prompt, lives in one TOML file you or an agent can edit."
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(6)

    ActionButton {
      text: "Open config.toml"
      foreground: Color.popups.text
      bordered: true
      onClicked: page.flow.openEditor(page.flow.personalConfigPath)
    }

    ActionButton {
      text: "Reload it"
      foreground: Color.popups.text
      onClicked: Quickshell.execDetached(["omaflow", "reload-config"])
    }

    Item { Layout.fillWidth: true }
  }

  Rectangle {
    Layout.fillWidth: true
    Layout.topMargin: Style.space(4)
    Layout.preferredHeight: Style.spacing.hairline
    color: Util.alpha(Color.popups.text, 0.12)
  }

  ActionButton {
    Layout.bottomMargin: Style.space(4)
    text: "Quit OmaFlow"
    foreground: Color.urgent
    onClicked: page.flow.quitOmaFlow()
  }
}
