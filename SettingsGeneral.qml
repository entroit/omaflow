import QtQuick
import QtQuick.Controls as Controls
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
        { "label": "Copy only", "value": "clipboard" },
        { "label": "Custom", "value": "custom" }
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

  Rectangle {
    id: customPaste
    Layout.fillWidth: true
    Layout.preferredHeight: customPasteContent.implicitHeight + Style.space(20)
    visible: page.flow.pasteMode === "custom"
    radius: Style.cornerRadius
    color: Util.alpha(Color.popups.text, 0.055)

    property bool ctrlOn: true
    property bool shiftOn: false
    property bool altOn: false
    property bool superOn: false

    function syncFromFlow() {
      var modifiers = Array.isArray(page.flow.pasteShortcut.modifiers)
        ? page.flow.pasteShortcut.modifiers : ["ctrl"]
      ctrlOn = modifiers.indexOf("ctrl") >= 0
      shiftOn = modifiers.indexOf("shift") >= 0
      altOn = modifiers.indexOf("alt") >= 0
      superOn = modifiers.indexOf("super") >= 0
      pasteKey.text = String(page.flow.pasteShortcut.key || "V")
    }

    Component.onCompleted: syncFromFlow()
    Connections {
      target: page.flow
      function onPasteShortcutChanged() { customPaste.syncFromFlow() }
    }

    ColumnLayout {
      id: customPasteContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: "Choose modifiers and one XKB key, such as V, Insert or F8."
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Util.alpha(Color.popups.text, 0.65)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Repeater {
          model: [
            {"label":"Ctrl", "value":"ctrl"},
            {"label":"Shift", "value":"shift"},
            {"label":"Alt", "value":"alt"},
            {"label":"Super", "value":"super"}
          ]
          ActionButton {
            required property var modelData
            readonly property bool active: modelData.value === "ctrl" ? customPaste.ctrlOn
              : modelData.value === "shift" ? customPaste.shiftOn
              : modelData.value === "alt" ? customPaste.altOn : customPaste.superOn
            text: modelData.label
            selected: active
            Accessible.name: modelData.label + " modifier"
            Accessible.checkable: true
            Accessible.checked: active
            onClicked: {
              if (modelData.value === "ctrl") customPaste.ctrlOn = !customPaste.ctrlOn
              else if (modelData.value === "shift") customPaste.shiftOn = !customPaste.shiftOn
              else if (modelData.value === "alt") customPaste.altOn = !customPaste.altOn
              else customPaste.superOn = !customPaste.superOn
            }
          }
        }

        Controls.TextField {
          id: pasteKey
          Layout.preferredWidth: Style.space(100)
          placeholderText: "Key"
          maximumLength: 80
          color: Color.popups.text
          Accessible.name: "Custom paste key"
        }

        Item { Layout.fillWidth: true }

        ActionButton {
          text: "Save"
          foreground: Color.popups.text
          background: Util.alpha(Color.accent, 0.22)
          bordered: true
          enabled: (customPaste.ctrlOn || customPaste.shiftOn || customPaste.altOn || customPaste.superOn)
            && /^[A-Za-z0-9_]+$/.test(pasteKey.text.trim())
          onClicked: {
            var modifiers = []
            if (customPaste.ctrlOn) modifiers.push("ctrl")
            if (customPaste.shiftOn) modifiers.push("shift")
            if (customPaste.altOn) modifiers.push("alt")
            if (customPaste.superOn) modifiers.push("super")
            page.flow.savePasteShortcut(modifiers, pasteKey.text)
          }
        }
      }
    }
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
          text: page.flow.updateRunning || page.flow.updateFailed
            ? String(page.flow.updateTransaction.message || "Preparing the OmaFlow update")
            : page.flow.updateOffer.externalCheckoutWarning
              ? "The plugin checkout changed outside OmaFlow"
              : page.flow.updateOffer.error
                ? "Could not check for updates"
                : page.flow.updateAvailable
                  ? "OmaFlow " + String(page.flow.verifiedUpdate.version || "") + " is available"
                  : Number(page.flow.updateOffer.checkedAtMs || 0) === 0
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
          text: page.flow.updateOffer.externalCheckoutWarning
            ? String(page.flow.updateOffer.externalCheckoutWarning)
            : page.flow.updateOffer.error
              ? String(page.flow.updateOffer.error)
              : page.flow.updateAvailable
                ? String(page.flow.verifiedUpdate.summary || "")
                  + (Array.isArray(page.flow.verifiedUpdate.changes)
                    ? "\n" + page.flow.verifiedUpdate.changes.join(" · ") : "")
                : Number(page.flow.updateOffer.checkedAtMs || 0) > 0
                  ? "Checked " + page.flow.formatHistoryTime(Number(page.flow.updateOffer.checkedAtMs)).toLowerCase()
                  : "Not checked yet"
          color: Util.alpha(Color.popups.text, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ActionButton {
        visible: page.flow.updateActionsAvailable
        text: page.flow.updateFailed ? "Retry" : "Update"
        foreground: Color.popups.text
        background: Util.alpha(Color.accent, 0.22)
        bordered: true
        onClicked: page.flow.requestUpdate()
      }

      ActionButton {
        visible: page.flow.laterActionAvailable
        text: "Later"
        foreground: Color.popups.text
        onClicked: page.flow.deferUpdate()
      }

      ActionButton {
        visible: page.flow.updaterControlsEnabled
          && (!page.flow.updateAvailable || Boolean(page.flow.updateOffer.error))
          && !page.flow.updateRunning
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
