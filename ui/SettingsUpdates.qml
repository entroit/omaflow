import QtQuick
import "Dates.js" as Dates

// Which OmaFlow this is, what is new, the file behind every setting, and Quit.
Column {
  id: page
  required property var app
  spacing: 22

  readonly property string installCommand: "cd " + app.pluginDir + " && ./install"
  // The clipboard says nothing back, so the button does for a moment.
  property bool copied: false
  Timer { id: copiedTimer; interval: 2000; onTriggered: page.copied = false }

  // A half-replaced OmaFlow is put right by bringing back the version you
  // had, not by installing again, so its button says that. Progress that
  // could not be read names no update, and Check now is its way out.
  readonly property bool restores: app.updatePausesDictation && Boolean(app.updateTransaction.targetCommit)
  readonly property string previousVersion: String((app.updateTransaction.originalRelease || {}).version || "")
  readonly property string putBack: previousVersion ? "Put back " + previousVersion : "Put back the previous version"
  // A failed update: what happened and what to do, under a short headline
  // that already says it did not finish.
  readonly property string failureDetail: {
    if (restores && app.updateState === "interrupted")
      return "The update stopped partway through. " + putBack + " to dictate again, then update."
    var message = String(app.updateTransaction.message || "").replace(/^The update did not finish\. /, "")
    if (!restores) return message
    // The button names the step, so the daemon's own "Choose …" sentence
    // gives way to one that says what it is for.
    message = message.replace(/ ?Choose (Try again|Put back \S+ to try again)\./, "")
    return message + (message ? " " : "") + (/paused/.test(message) ? "Choose " + putBack + " to dictate again."
      : "Dictation is paused until you choose " + putBack + ".")
  }
  // "Checked today at 14:02."
  readonly property string checkedText: {
    var at = Number(app.updateOffer.checkedAtMs || 0)
    if (at === 0) return ""
    var day = Dates.group(at, app.nowMs)
    return "Checked " + (day === "Today" || day === "Yesterday" ? day.toLowerCase() : day) + " at " + Dates.stamp(at) + "."
  }

  PageTitle { width: parent.width; title: "Updates and app"; subtitle: "Installed: OmaFlow " + (page.app.runningVersion || "unknown") + ". A new version shows as a dot on the bar icon and a notification." }

  Rectangle {
    width: parent.width
    height: card.implicitHeight + 36
    radius: Theme.radiusPanel
    color: Theme.fill4
    border.width: page.app.updateFailed || page.app.updateOffer.externalCheckoutWarning || !page.app.supportedState ? 1 : 0
    // Red where the header is red: dictation is blocked until this is put right.
    border.color: !page.app.supportedState || page.app.updatePausesDictation ? Theme.red : Theme.yellow

    Column {
      id: card
      x: 18; y: 18
      width: parent.width - 36
      spacing: 10

      // A long headline wraps beside the buttons in a narrow window.
      Item {
        width: parent.width
        height: Math.max(32, headline.implicitHeight)
        UiText {
          id: headline
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - actions.width - 12
          wrapMode: Text.Wrap
          font.pixelSize: 16
          weight: Font.Bold
          text: !page.app.supportedState ? "OmaFlow is only partly updated"
            : page.app.updateFailed ? (page.app.updateTransaction.targetVersion
              ? "The update to " + page.app.updateTransaction.targetVersion + " did not finish" : "The update did not finish")
            : page.app.updateRunning ? String(page.app.updateTransaction.message || "Preparing the update")
            : page.app.updateOffer.externalCheckoutWarning ? "The OmaFlow folder changed outside OmaFlow"
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
          // Later puts the dot away for a day; the update stays here.
          UiText {
            visible: page.app.updateActionsAvailable && !page.app.updateFailed && page.app.updateDeferred
            anchors.verticalCenter: parent.verticalCenter
            text: "Reminding you tomorrow"
            muted: true
          }
          UiText {
            visible: page.app.updateChecking
            anchors.verticalCenter: parent.verticalCenter
            text: "Checking…"
            muted: true
          }
          Pill { visible: page.app.updateActionsAvailable && !page.app.updateFailed && !page.app.updateDeferred; kind: "fill"; text: "Later"; size: 13; onClicked: page.app.deferUpdate() }
          Pill { visible: page.app.updateActionsAvailable; kind: "primary"; text: page.restores ? page.putBack : page.app.updateFailed ? "Try again" : "Update and restart"; size: 13; onClicked: page.app.requestUpdate() }
          // Also after the plugin folder changed, to look again once it is
          // clean, and after a failed update, where checking again repairs an
          // unreadable progress file.
          Pill {
            visible: page.app.supportedState && !page.app.updateRunning
              && (!page.app.updateAvailable || Boolean(page.app.updateOffer.error) || page.app.updateRequestError.length > 0
                || Boolean(page.app.updateOffer.externalCheckoutWarning) || page.app.updateFailed)
            kind: "outline"; text: "Check now"; size: 13
            enabled: !page.app.updateChecking
            onClicked: page.app.checkForUpdate()
          }
        }
      }

      UiText {
        width: parent.width
        wrapMode: Text.Wrap
        visible: page.app.updateRequestError.length > 0 && !page.app.updateRunning
        text: page.app.updateRequestError
        color: Theme.redText
      }
      UiText {
        width: parent.width
        wrapMode: Text.Wrap
        muted: true
        visible: text.length > 0
        text: !page.app.supportedState ? "Part of OmaFlow is still on the old version. Paste this in a terminal:"
          : page.app.updateFailed ? page.failureDetail
          : page.app.updateOffer.externalCheckoutWarning
            ? "Updates are paused. Review the changes " + (page.app.pluginDir ? "in " + page.app.pluginDir + " " : "") + "with git, then choose Check now."
          : page.app.updateOffer.error ? String(page.app.updateOffer.error)
          : page.app.updateAvailable ? String(page.app.verifiedUpdate.summary || "")
          : page.checkedText || "OmaFlow checks once a day."
      }
      Row {
        visible: !page.app.supportedState
        width: parent.width
        spacing: 10
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(parent.width - copyCommand.width - 10, command.implicitWidth + 24)
          height: command.implicitHeight + 16
          radius: Theme.radiusInput
          color: Theme.fill8
          UiText {
            id: command
            x: 12
            width: parent.width - 24
            anchors.verticalCenter: parent.verticalCenter
            // A word joiner keeps "./install" whole when the line wraps.
            text: page.installCommand.replace("./install", "./\u2060install")
            font.family: Theme.mono
            font.pixelSize: 12
            wrapMode: Text.Wrap
          }
        }
        Pill {
          id: copyCommand
          anchors.verticalCenter: parent.verticalCenter
          kind: "primary"; text: page.copied ? "Copied" : "Copy command"; size: 13
          onClicked: { page.app.copy(page.installCommand); page.copied = true; copiedTimer.restart() }
        }
      }
      Repeater {
        // Not while partly updated: the repair comes first, the news after.
        // Nor under an update that did not finish or cannot start yet,
        // where they would read as what happened.
        model: page.app.supportedState && page.app.updateAvailable && !page.app.updateFailed
          && !page.app.updateOffer.externalCheckoutWarning && !page.app.updateOffer.error && Array.isArray(page.app.verifiedUpdate.changes) ? page.app.verifiedUpdate.changes : []
        UiText { required property var modelData; width: card.width; wrapMode: Text.Wrap; text: String(modelData) }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 18
    SettingRow {
      title: "Configuration file"
      caption: "Every setting, including the cleanup prompt. Saved changes apply within a second."
      Pill { kind: "outline"; text: "Open config.toml"; size: 13; onClicked: page.app.openInEditor(page.app.personalConfigPath) }
    }
    SettingRow {
      title: "Quit"
      caption: "Stops dictation and unloads the models. Start brings it back from the top of this window."
      last: true
      Pill { kind: "outline"; text: "Quit OmaFlow"; size: 13; onClicked: page.app.quit() }
    }
  }
}
