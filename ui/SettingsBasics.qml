import QtQuick
import "Diff.js" as Diff

// What most people change. Everything else is one level down, in Advanced.
Column {
  id: page
  required property var app
  signal go(string target)
  spacing: 22

  readonly property var cleanupNotes: ({
    "off": "Pastes exactly what the speech model heard. Your words list still applies.",
    "light": "Drops fillers such as um and uh, and repeated words. Never adds a word. Runs instantly, no model needed.",
    "medium": "The cleanup model fixes punctuation, applies the corrections you say out loud and writes numbers as digits."
  })
  // What each level does to one sentence, for when History has nothing to show.
  readonly property var cleanupSamples: ({
    "off": { raw: "so um can you move the review to Thursday no wait Friday at ten", text: "so um can you move the review to Thursday no wait Friday at ten" },
    "light": { raw: "so um can you move the the review to Friday at ten", text: "so can you move the review to Friday at ten" },
    "medium": { raw: "so um can you move the review to Thursday no wait Friday at ten", text: "Can you move the review to Friday at 10?" }
  })
  // Your own words where History can show them truthfully: what you said for
  // Off, and a dictation the cleanup model changed for Medium. Light is not
  // recorded per dictation, so it keeps the sample. Long ones would bury the
  // setting, and ones you edited no longer show what cleanup did, so they are
  // skipped.
  readonly property var lastDictation: {
    var level = app.cleanupLevel
    if (level === "light") return null
    return app.history.find(function(entry) {
      var raw = String(entry.raw_text || "")
      return raw.length > 0 && entry.edited !== true && Diff.words(raw).length <= 60
        && (level === "off" || (entry.cleanup_model && entry.text !== raw))
    }) || null
  }
  readonly property var example: lastDictation
    ? { raw: lastDictation.raw_text, text: app.cleanupLevel === "off" ? lastDictation.raw_text : lastDictation.text }
    : cleanupSamples[app.cleanupLevel] || cleanupSamples.off

  // The dictation keys, recorded right here; Hotkeys has the rest.
  property bool recordingHold: false
  function saveHold(keys) {
    var consumed = (app.shortcutSettings.consumed || []).filter(function(key) { return keys.indexOf(key) >= 0 })
    app.spawn(["python3", app.pluginDir + "/tools/set_hotkey.py", "--keys", keys.join(","), "--consumed", consumed.join(",")], function(stdout, stderr) {
      var response = null
      try { response = JSON.parse(stdout) } catch (error) { response = null }
      if (response && response.ok) { recordingHold = false; return }
      holdRecorder.start()
      holdRecorder.problem = response ? response.message : (String(stderr || "").trim() || "Could not save the shortcut. Check that Hyprland is running.")
    })
  }

  PageTitle { width: parent.width; title: "Basics"; subtitle: "What most people change." }

  Column {
    width: parent.width
    spacing: 18

    SettingRow {
      title: "Hold to dictate"
      caption: "Double-tap to lock"
      alignTop: page.recordingHold
      Column {
        width: parent.width
        spacing: 8
        Item {
          visible: !page.recordingHold
          width: parent.width
          height: 32
          Keycap { anchors.verticalCenter: parent.verticalCenter; text: page.app.hotkeyDisplay ? page.app.hotkeyDisplay.split(/\s*\+\s*/).join("+") : "No shortcut" }
          Pill {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            kind: "outline"; text: "Change"; size: 13
            Accessible.name: "Change the dictation keys"
            onClicked: page.recordingHold = true
            // Back here after Esc or a save from the keyboard, not lost.
            onVisibleChanged: if (visible && holdRecorder.endedByKey) { holdRecorder.endedByKey = false; forceActiveFocus() }
          }
        }
        KeyRecorder {
          id: holdRecorder
          visible: page.recordingHold
          width: parent.width
          mode: "chord"
          onVisibleChanged: if (visible) { value = []; Qt.callLater(start) }
          onCancelled: page.recordingHold = false
          onRecorded: page.saveHold(value)
        }
        // The recorder's Esc hint, when it has no room beside the prompt.
        UiText {
          visible: page.recordingHold && holdRecorder.listening && !holdRecorder.keysHintFits
          width: parent.width
          wrapMode: Text.Wrap
          font.pixelSize: 12
          muted: true
          text: holdRecorder.keysHint + "."
        }
        UiText {
          visible: page.recordingHold
          width: parent.width
          wrapMode: Text.Wrap
          font.pixelSize: 12
          color: holdRecorder.problem ? Theme.redText : Theme.secondary
          text: holdRecorder.problem || "Your current keys start dictation instead of showing here."
        }
      }
    }

    SettingRow {
      title: "Microphone"
      caption: "Speak to test"
      alignTop: true
      Column {
        width: parent.width
        spacing: 8
        Item {
          width: parent.width
          height: Math.max(micText.implicitHeight, soundSettings.height)
          UiText {
            id: micText
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - soundSettings.width - 8
            // A long device name wraps rather than hiding which one it is.
            wrapMode: Text.Wrap
            readonly property string device: String(page.app.inputDevice || "")
            text: page.app.micDetected ? "Your voice is coming through" + (device ? " on " + device : "") + "."
              : device ? "Listening on " + device + " (default input)."
              : "Uses your default input."
            muted: !page.app.micDetected
            color: page.app.micDetected ? Theme.greenText : Theme.secondary
          }
          Pill {
            id: soundSettings
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            kind: "link"; text: "Change in sound settings"; size: 13; horizontalPadding: 4
            onClicked: page.app.spawn(["omarchy-shell", "shell", "toggle", "omarchy.audio"])
          }
        }
        Meter { width: parent.width; app: page.app }
      }
    }

    SettingRow {
      title: "Cleanup"
      caption: "For dictation and to-dos. The journal has its own setting."
      alignTop: true
      Column {
        width: parent.width
        spacing: 10
        Segmented {
          name: "Cleanup"
          options: [{ value: "off", label: "Off" }, { value: "light", label: "Light" }, { value: "medium", label: "Medium" }]
          current: page.app.cleanupLevel
          onPicked: function(value) { page.app.setCleanupLevel(value) }
        }
        UiText {
          width: parent.width
          text: (page.cleanupNotes[page.app.cleanupLevel] || "") + (page.app.cleanupLevel === "off" ? ""
            : page.app.historyLimit > 0 ? " The raw text stays in History." : " History is off, so the raw text is not kept.")
          muted: true
          wrapMode: Text.Wrap
          lineHeight: 18
        }
        // The level shown on real words before you rely on it.
        Rectangle {
          width: parent.width
          height: sample.implicitHeight + 24
          radius: Theme.radiusCard
          color: Theme.fill4
          Column {
            id: sample
            x: 12; y: 12
            width: parent.width - 24
            spacing: 4
            UiText { text: page.lastDictation ? "Your last dictation" : "For example"; muted: true; font.pixelSize: 12 }
            UiText {
              width: parent.width
              textFormat: Text.RichText
              text: Diff.html(page.example.raw, page.example.text, { removed: Theme.redText, added: Theme.greenText })
              color: Theme.text
              wrapMode: Text.Wrap
              lineHeight: 20
            }
          }
        }
        // The same cause the Cleanup page names. The link wraps under the
        // sentence at the narrowest window, and the dot carries the warning
        // where the theme's yellow is close to the text colour.
        Flow {
          id: runtimeLine
          visible: page.app.cleanupLevel === "medium" && page.app.cleanupRuntime !== "ready"
          width: parent.width
          spacing: 8
          Row {
            spacing: 8
            Rectangle { y: (runtimeText.lineHeight - height) / 2; width: 8; height: 8; radius: 4; color: Theme.yellow }
            UiText {
              id: runtimeText
              width: Math.min(implicitWidth, runtimeLine.width - 16)
              wrapMode: Text.Wrap
              text: (page.app.cleanupRuntime === "missing" ? "Ollama is not installed"
                : (page.app.modelSettings.cleanup_engine === "openai" ? "The cleanup server" : "Ollama") + " is not answering") + ", so Medium can't run yet."
              color: Theme.yellowText
            }
          }
          // No vertical padding, so its words sit on the sentence's line.
          Pill { kind: "link"; text: "Set it up"; size: 13; horizontalPadding: 4; verticalPadding: 0; Accessible.name: "Set up the cleanup model"; onClicked: page.go("cleanup") }
        }
      }
    }

    SettingRow {
      title: "Paste with"
      caption: "Text also stays on the clipboard"
      alignTop: true
      last: true
      Column {
        width: parent.width
        spacing: 10
        // Your own keys are a capsule of their own, so they wrap under the
        // four fixed choices at the narrowest window instead of running off.
        Flow {
          width: parent.width
          spacing: 8
          Segmented {
            name: "Paste with"
            horizontalPadding: 12
            options: [{ value: "auto", label: "Auto" }, { value: "ctrl-v", label: "Ctrl+V" }, { value: "shift-insert", label: "Shift+Insert" }, { value: "clipboard", label: "Copy only" }]
            current: page.app.pasteMode
            onPicked: function(value) { page.app.setPasteMode(value) }
          }
          Segmented {
            visible: page.app.customPaste
            name: "Paste with your own keys"
            horizontalPadding: 12
            options: [{ value: "custom", label: page.app.pasteLabel(page.app.pasteShortcut) }]
            current: page.app.pasteMode
            onPicked: function(value) { page.app.setPasteMode(value) }
          }
        }
        Flow {
          width: parent.width
          spacing: 8
          UiText {
            width: Math.min(implicitWidth, parent.width)
            wrapMode: Text.Wrap
            muted: true
            text: page.app.pasteMode === "custom" ? "Your own keys, in every app."
              : page.app.pasteMode === "clipboard" ? "OmaFlow copies and you paste."
              : page.app.pasteMode === "auto" ? "Ctrl+V, or Shift+Insert in terminals."
              : ""
          }
          Pill {
            visible: page.app.pasteMode === "custom"
            kind: "link"; text: "Change them in Hotkeys"; size: 13; horizontalPadding: 4; verticalPadding: 0
            onClicked: page.go("hotkeys")
          }
        }
      }
    }
  }
}
