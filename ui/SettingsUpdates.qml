import QtQuick

// Which OmaFlow this is, what is new, and the file behind every setting.
Column {
  id: page
  required property var app
  spacing: 22

  PageTitle { width: parent.width; title: "Updates"; subtitle: "Installed: OmaFlow " + (page.app.runningVersion || "unknown") + ". Updates show as a dot on the bar icon, never a pop-up." }

  Rectangle {
    width: parent.width
    height: card.implicitHeight + 36
    radius: Theme.radiusPanel
    color: Theme.fill4
    border.width: page.app.updateFailed || page.app.updateOffer.externalCheckoutWarning || !page.app.supportedState ? 1 : 0
    border.color: Theme.yellow

    Column {
      id: card
      x: 18; y: 18
      width: parent.width - 36
      spacing: 10

      Item {
        width: parent.width
        height: 32
        UiText {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - actions.width - 12
          elide: Text.ElideRight
          font.pixelSize: 16
          weight: Font.Bold
          text: !page.app.supportedState ? "The window and the daemon are different versions"
            : page.app.updateRunning || page.app.updateFailed ? String(page.app.updateTransaction.message || "Preparing the update")
            : page.app.updateOffer.externalCheckoutWarning ? "The plugin folder changed outside OmaFlow"
            : page.app.updateOffer.error ? "Could not check for updates"
            : page.app.updateAvailable ? String(page.app.verifiedUpdate.version || "") + " is ready"
            : Number(page.app.updateOffer.checkedAtMs || 0) === 0 ? "Not checked yet"
            : "OmaFlow is up to date"
        }
        Row {
          id: actions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          Pill { visible: page.app.updateActionsAvailable && !page.app.updateFailed; kind: "fill"; text: "Later"; size: 13; onClicked: page.app.deferUpdate() }
          Pill { visible: page.app.updateActionsAvailable; kind: "primary"; text: page.app.updateFailed ? "Try again" : "Update and restart"; size: 13; onClicked: page.app.requestUpdate() }
          Pill {
            visible: page.app.supportedState && (!page.app.updateAvailable || Boolean(page.app.updateOffer.error)) && !page.app.updateRunning
            kind: "outline"; text: page.app.updateChecking ? "Checking…" : "Check now"; size: 13
            enabled: !page.app.updateChecking
            onClicked: page.app.checkForUpdate()
          }
        }
      }

      UiText {
        width: parent.width
        wrapMode: Text.Wrap
        muted: true
        visible: text.length > 0
        text: !page.app.supportedState ? "Run ./install again from the plugin folder to bring both to the same version."
          : page.app.updateOffer.externalCheckoutWarning ? String(page.app.updateOffer.externalCheckoutWarning)
          : page.app.updateOffer.error ? String(page.app.updateOffer.error)
          : page.app.updateAvailable ? String(page.app.verifiedUpdate.summary || "") : ""
      }
      Repeater {
        model: page.app.updateAvailable && Array.isArray(page.app.verifiedUpdate.changes) ? page.app.verifiedUpdate.changes : []
        UiText { required property var modelData; width: card.width; wrapMode: Text.Wrap; text: String(modelData) }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 18
    SettingRow {
      title: "Configuration file"
      caption: "Every setting, including the cleanup prompt"
      Row {
        spacing: 8
        Pill { kind: "outline"; text: "Open config.toml"; size: 13; onClicked: page.app.openInEditor(page.app.personalConfigPath) }
        Pill { kind: "fill"; text: "Reload it"; size: 13; onClicked: page.app.reloadConfig() }
      }
    }
    SettingRow {
      title: "OmaFlow"
      caption: "Stops dictation and unloads the models"
      last: true
      Pill { kind: "danger"; text: "Quit OmaFlow"; size: 13; onClicked: page.app.quit() }
    }
  }
}
