import QtQuick

// What stands between this computer and the first dictation, with the one
// button that fixes it. Hidden when nothing does. The setup's states come
// from app.setup; the speech model is the step after it.
Rectangle {
  id: banner

  required property var app
  // On Updates and app only the setup shows; the speech model has its own page.
  property bool setupOnly: false
  signal openSettings(string target)

  readonly property var setup: app.setup
  readonly property var update: setup.update
  readonly property string problem: setup.state !== "ready" ? setup.state
    : !setupOnly && app.connected && app.setupUnfinished && !app.speechDownloading ? "model"
    : ""
  readonly property bool isSetup: problem.length > 0 && problem !== "model"
  // The button keeps its words while the setup runs.
  readonly property string action: update ? "Finish update" : "Finish setup"
  // "jq and wl-clipboard"
  readonly property string missing: {
    var names = String(setup.missing || "").split(" ").filter(function(name) { return name.length > 0 })
    return names.length > 1 ? names.slice(0, -1).join(", ") + " and " + names[names.length - 1] : names.join("")
  }
  // The old version still works while an update waits; nothing does before the first install.
  readonly property bool blocking: problem === "needs-setup" || problem === "needs-packages" || problem === "failed" && !update
    || app.partlyUpdated

  // The clipboard says nothing back, so the button does for a moment.
  property bool copied: false
  Timer { id: copiedTimer; interval: 2000; onTriggered: banner.copied = false }

  visible: problem.length > 0
  height: visible ? content.implicitHeight + 40 : 0
  radius: Theme.radiusPanel
  color: Theme.fill4
  border.width: 1
  border.color: blocking ? Theme.red : Theme.yellow

  Column {
    id: content
    x: 20; y: 20
    width: parent.width - 40
    spacing: 14

    Row {
      width: parent.width
      spacing: 10
      Icon { id: icon; y: 3; name: "warning"; size: 15; color: banner.blocking ? Theme.red : Theme.yellow }
      UiText {
        width: parent.width - icon.width - 10
        wrapMode: Text.Wrap
        font.pixelSize: 16
        weight: Font.Bold
        text: banner.problem === "model" ? "One step left before you can dictate"
          : banner.problem === "failed" ? (banner.update ? "The update to " + banner.update.to + " did not finish" : "Setup did not finish")
          : banner.update ? "Finish updating to " + banner.update.to
          : "Finish setting up OmaFlow"
      }
    }

    // Why it stopped, in the setup's own words.
    UiText {
      visible: banner.problem === "failed"
      x: 25
      width: parent.width - 25
      wrapMode: Text.Wrap
      text: String(banner.setup.reason || "")
    }

    UiText {
      x: 25
      width: parent.width - 25
      wrapMode: Text.Wrap
      muted: true
      text: banner.problem === "model" ? (banner.app.missingSpeechModel ? String(banner.app.missingSpeechModel.label || banner.app.missingSpeechModel.id)
          + " is chosen but not downloaded yet. Nothing was downloaded during installation."
          : "Choose a speech model. Nothing was downloaded during installation, and each model lists its size and what it needs to run.")
        : banner.problem === "needs-packages" ? "OmaFlow needs " + banner.missing + " first. Nothing has changed yet. Run this in a terminal, then choose Check again:"
        : banner.problem === "failed" ? "Try again picks up where it stopped."
        : banner.update ? (banner.update.from !== banner.update.to
            ? "The OmaFlow folder is on " + banner.update.to + ", but the app still runs " + banner.update.from + "."
            : "Part of OmaFlow is still on the old version.")
          + " " + banner.action + " installs the app that came with it and restarts its background services. Your settings stay."
          + " The top bar restarts once, then this window opens again."
        : banner.action + " installs the OmaFlow app that came with the plugin, adds two background services, for dictation and a daily update check, and "
          + (banner.app.existingHotkey ? "keeps your dictation key, " + banner.app.existingHotkey + "." : "sets your dictation key to AltGr+Menu in Hyprland.")
          + " The top bar restarts once, then this window opens again."
    }

    Rectangle {
      visible: banner.problem === "needs-packages"
      x: 25
      width: Math.min(parent.width - 25, command.implicitWidth + 24)
      height: command.implicitHeight + 16
      radius: Theme.radiusInput
      color: Theme.fill8
      UiText {
        id: command
        x: 12
        width: parent.width - 24
        anchors.verticalCenter: parent.verticalCenter
        text: String(banner.setup.command || "")
        font.family: Theme.mono
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }

    Row {
      x: 25
      spacing: 8
      Pill {
        visible: banner.problem === "model"
        kind: "primary"; text: banner.app.missingSpeechModel ? "Download the speech model" : "Choose a speech model"
        size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: banner.openSettings("models")
      }
      Pill {
        visible: ["needs-setup", "needs-update", "running", "failed"].indexOf(banner.problem) >= 0
        enabled: banner.problem !== "running"
        kind: "primary"; text: banner.problem === "failed" ? "Try again" : banner.action
        size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: banner.app.finishSetup()
      }
      Pill {
        visible: banner.problem === "needs-packages"
        enabled: !banner.app.setupChecking
        kind: "primary"; text: "Check again"; size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: banner.app.checkPackages()
      }
      Pill {
        visible: banner.problem === "needs-packages"
        kind: "fill"; text: banner.copied ? "Copied" : "Copy command"; size: 13; verticalPadding: 7; horizontalPadding: 12
        onClicked: { banner.app.copy(banner.setup.command); banner.copied = true; copiedTimer.restart() }
      }
      Pill {
        visible: banner.problem === "failed" && String(banner.setup.log || "").length > 0
        kind: "link"; text: "Open the log"; size: 13; verticalPadding: 7
        onClicked: banner.app.openInEditor(banner.setup.log)
      }
      UiText {
        visible: banner.problem === "running" || banner.problem === "needs-packages" && banner.app.setupChecking
        anchors.verticalCenter: parent.verticalCenter
        text: banner.problem === "running" ? banner.app.setupStepText : "Checking…"
        muted: true
      }
    }

    // The terminal way does the same, and installs missing packages itself.
    UiText {
      visible: banner.isSetup && banner.problem !== "running"
      x: 25
      width: parent.width - 25
      wrapMode: Text.Wrap
      font.pixelSize: 12
      muted: true
      // A word joiner keeps "./install" whole when the line wraps.
      text: "Or run ./⁠install in a terminal, in " + banner.app.pluginDir + "."
    }
  }
}
