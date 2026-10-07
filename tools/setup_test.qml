// Finish setup in the window: every state of the setup banner, what its
// buttons start, and how the state follows the status file the detached
// setup writes across the shell restart.
//   qmltestrunner -input tools/setup_test.qml (run by ui_smoke.py)
import QtQuick
import QtTest
import "../ui"
import "../hosts/omarchy/Setup.js" as Setup
import "preview/Fixtures.js" as Fixtures

Item {
  id: root
  width: 880; height: 900
  property var spawned: []
  property var pending: []
  property var toasts: []

  App {
    id: app
    clockOverride: Fixtures.NOW
    nowMs: Fixtures.NOW
    pluginDir: "/home/you/.config/omarchy/plugins/entroit.omaflow"
    host: QtObject {
      function spawn(argv, callback) { root.spawned.push(argv); root.pending.push(callback) }
      function copy(text) {}
      function openInEditor(path) { root.spawned.push(["edit", path]) }
      function setupCommand() {
        return Setup.command(app.pluginDir + "/install", function(name) {
          return { PATH: "/home/you/.local/bin:/usr/bin", HYPRLAND_INSTANCE_SIGNATURE: "abc_1" }[name]
        })
      }
    }
    onToast: function(message, error) { root.toasts.push(message) }
  }
  SetupBanner { id: banner; width: 640; app: app }

  function answer(code, stderr) {
    var callbacks = root.pending
    root.pending = []
    callbacks.forEach(function(callback) { if (callback) callback("", stderr || "", code) })
  }
  function find(item, test) {
    if (item.visible && test(item)) return item
    for (var i = 0; i < item.children.length; i++) { var f = find(item.children[i], test); if (f) return f }
    return null
  }
  function text(words) { return find(banner, function(item) { return item.text === words && !item.hasOwnProperty("kind") }) }
  function pill(words) { return find(banner, function(item) { return item.hasOwnProperty("kind") && item.text === words }) }
  // A pill that just appeared is laid out on the next frame.
  function click(item) { testCase.wait(20); testCase.mouseClick(item) }
  function status(fields) { app.applySetupStatus(JSON.stringify(Object.assign({ updatedAtMs: Date.now() + 1000 }, fields))) }

  TestCase {
    id: testCase
    name: "Setup"
    when: windowShown

    function init() {
      app.applyState(JSON.stringify(Fixtures.state("history", Fixtures.NOW)))
      app.binaryFound = false
      app.pluginVersion = "0.21.0"
      app.installedVersion = ""
      app.existingHotkey = ""
      app.setupStatus = ({})
      app.setupRequestedAt = 0
      app.setupStartError = ""
      app.setupUnitActive = true
      app.setupMisses = 0
      root.spawned = []
      root.pending = []
      root.toasts = []
    }

    function test_not_installed_says_what_finish_setup_changes() {
      compare(app.setup.state, "needs-setup")
      verify(banner.visible)
      verify(text("Finish setting up OmaFlow") !== null)
      verify(text("Finish setup installs the OmaFlow app that came with the plugin, adds two background services, for dictation and a daily update check, and sets your dictation key to AltGr+Menu in Hyprland. The top bar restarts once, then this window opens again.") !== null)
      verify(pill("Finish setup") !== null && pill("Finish setup").kind === "primary")
      verify(text("Or run ./⁠install in a terminal, in /home/you/.config/omarchy/plugins/entroit.omaflow.") !== null)
      app.existingHotkey = "F13"
      verify(text("Finish setup installs the OmaFlow app that came with the plugin, adds two background services, for dictation and a daily update check, and keeps your dictation key, F13. The top bar restarts once, then this window opens again.") !== null, "an existing key is kept")
      compare(app.statusText, "Not installed yet")
      compare(app.setupPage, "history")
    }

    function test_finish_setup_starts_the_detached_setup_once() {
      root.click(pill("Finish setup"))
      compare(root.spawned.length, 1)
      compare(root.spawned[0], ["systemd-run", "--user", "--unit=omaflow-setup.service", "--collect", "--quiet",
        "--setenv=PATH=/home/you/.local/bin:/usr/bin", "--setenv=HYPRLAND_INSTANCE_SIGNATURE=abc_1",
        "/home/you/.config/omarchy/plugins/entroit.omaflow/install", "--from-window"])
      compare(app.setup.state, "running")
      var button = pill("Finish setup")
      verify(button !== null && !button.enabled, "same words, and it waits")
      verify(text("Installing OmaFlow…") !== null)
      compare(app.statusText, "Installing OmaFlow…")
      root.click(button)
      app.finishSetup()
      compare(root.spawned.length, 1, "a second click starts nothing")
      verify(text("Or run ./⁠install in a terminal, in /home/you/.config/omarchy/plugins/entroit.omaflow.") === null, "no other way while it runs")
    }

    function test_progress_follows_the_status_file_and_ends_with_the_outcome() {
      app.finishSetup()
      answer(0)
      status({ state: "running", step: "services", from: "" })
      compare(app.setupRequestedAt, 0, "the setup answered")
      verify(text("Starting the services…") !== null)
      status({ state: "running", step: "shell", from: "" })
      verify(text("Restarting the shell…") !== null)
      compare(app.statusText, "Restarting the shell…")
      status({ state: "ok", from: "", message: "OmaFlow is installed. Your dictation key is AltGr+Menu." })
      compare(root.toasts, ["OmaFlow is installed. Your dictation key is AltGr+Menu."])
      app.binaryFound = true
      app.installedVersion = "0.21.0"
      compare(app.setup.state, "ready")
      verify(!banner.visible || text("One step left before you can dictate") !== null, "the speech model is next")
    }

    function test_a_shell_restart_mid_setup_shows_the_outcome_once() {
      // The new window's first read: a setup that ended just before it started.
      app.applySetupStatus(JSON.stringify({ updatedAtMs: Date.now(), state: "ok", from: "0.20.1", message: "OmaFlow is updated to 0.21.0." }), true)
      compare(root.toasts, ["OmaFlow is updated to 0.21.0."])
      app.applySetupStatus(JSON.stringify({ updatedAtMs: Date.now(), state: "ok", from: "0.20.1", message: "OmaFlow is updated to 0.21.0." }))
      compare(root.toasts.length, 1)
    }

    function test_a_missing_package_shows_the_command_and_check_again() {
      status({ state: "needs-packages", from: "", missing: "jq wl-clipboard", command: "sudo pacman -S --needed jq wl-clipboard" })
      compare(app.setup.state, "needs-packages")
      verify(text("OmaFlow needs jq and wl-clipboard first. Nothing has changed yet. Run this in a terminal, then choose Check again:") !== null)
      verify(text("sudo pacman -S --needed jq wl-clipboard") !== null)
      verify(pill("Copy command") !== null)
      var check = pill("Check again")
      verify(check !== null && check.kind === "primary")
      root.click(check)
      compare(root.spawned, [["/home/you/.config/omarchy/plugins/entroit.omaflow/install", "--from-window", "--dry-run"]], "it only checks")
      verify(!check.enabled && text("Checking…") !== null)
      status({ state: "needs-packages", from: "", missing: "jq", command: "sudo pacman -S --needed jq" })
      answer(1)
      compare(root.toasts, ["Still missing: jq. Run the command, then check again."])
      status({ state: "checked", from: "" })
      compare(app.setup.state, "needs-setup", "Finish setup comes back")
    }

    function test_a_failure_says_why_and_tries_again() {
      status({ state: "failed", from: "", message: "Hyprland rejected the configuration: bindings.lua:3: bad bind", log: "/run/user/1000/omaflow-setup.log" })
      verify(text("Setup did not finish") !== null)
      verify(text("Hyprland rejected the configuration: bindings.lua:3: bad bind") !== null)
      verify(text("Try again picks up where it stopped.") !== null)
      root.click(pill("Open the log"))
      compare(root.spawned, [["edit", "/run/user/1000/omaflow-setup.log"]])
      root.click(pill("Try again"))
      compare(root.spawned[1][0], "systemd-run")
      compare(app.setup.state, "running")
    }

    function test_a_setup_that_did_not_start_or_vanished_is_a_failure() {
      app.finishSetup()
      answer(1, "Failed to start transient service unit: Unit omaflow-setup.service was already loaded or has a fragment file.")
      compare(app.setup.state, "failed")
      compare(app.setup.reason, "Failed to start transient service unit: Unit omaflow-setup.service was already loaded or has a fragment file.")
      app.setupStartError = ""
      status({ state: "running", step: "app", from: "" })
      app.noteSetupUnit(false)
      compare(app.setup.state, "running", "one miss may be the moment it finished")
      app.noteSetupUnit(false)
      compare(app.setup.state, "failed")
      compare(app.setup.reason, "Setup stopped before it finished.")
    }

    function test_an_update_from_omarchy_is_finished_with_the_same_setup() {
      app.binaryFound = true
      app.installedVersion = "0.20.1"
      compare(app.setup.state, "needs-update")
      compare(app.setupPage, "settings/updates")
      verify(text("Finish updating to 0.21.0") !== null)
      verify(text("The OmaFlow folder is on 0.21.0, but the app still runs 0.20.1. Finish update installs the app that came with it and restarts its background services. Your settings stay. The top bar restarts once, then this window opens again.") !== null)
      root.click(pill("Finish update"))
      compare(root.spawned[0][0], "systemd-run")
      answer(0)
      status({ state: "running", step: "app", from: "0.20.1" })
      // The new release is in place before the setup ends; it is still the update.
      app.installedVersion = "0.21.0"
      verify(text("Finish updating to 0.21.0") !== null)
      verify(pill("Finish update") !== null && !pill("Finish update").enabled)
      status({ state: "failed", from: "0.20.1", message: "Bundled OmaFlow binary has the wrong size.", log: "" })
      verify(text("The update to 0.21.0 did not finish") !== null)
      verify(pill("Open the log") === null, "no log, no link")
    }

    function test_partly_updated_and_updater_runs() {
      app.binaryFound = true
      app.installedVersion = "0.21.0"
      compare(app.setup.state, "ready")
      app.stateVersion = 3
      compare(app.setup.state, "needs-update", "an old daemon still running")
      verify(text("Part of OmaFlow is still on the old version. Finish update installs the app that came with it and restarts its background services. Your settings stay. The top bar restarts once, then this window opens again.") !== null)
      app.stateVersion = 4
      // OmaFlow's own updater moves the folder first; that is not for this banner.
      app.installedVersion = "0.20.1"
      app.updateTransaction = { state: "activating" }
      compare(app.setup.state, "ready")
      app.updateTransaction = ({})
    }

    function test_setup_only_leaves_the_speech_model_to_its_page() {
      app.binaryFound = true
      app.installedVersion = "0.21.0"
      var state = Fixtures.state("history-setup", Fixtures.NOW)
      app.applyState(JSON.stringify(state))
      verify(banner.visible && text("One step left before you can dictate") !== null)
      banner.setupOnly = true
      verify(!banner.visible)
      banner.setupOnly = false
    }
  }
}
