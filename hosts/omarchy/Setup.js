.pragma library
// How the window starts Finish setup. Not as its own child: the setup's last
// step restarts the shell, and the window with it, so the setup runs in a
// systemd user unit of its own and writes how far it got to a status file.
// The unit is named, so a second click cannot start a second setup.

// The session the window runs in, which the user manager may not have.
var PASSED = ["PATH", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP",
  "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "OMARCHY_PATH"]

var UNIT = "omaflow-setup.service"

// env(name) reads the window's environment; unset ones are left out.
function command(installer, env) {
  var argv = ["systemd-run", "--user", "--unit=" + UNIT, "--collect", "--quiet"]
  PASSED.forEach(function(name) {
    var value = env(name)
    if (value) argv.push("--setenv=" + name + "=" + value)
  })
  return argv.concat([installer, "--from-window"])
}

// Whether the setup still runs, asked while its file says it does.
var ACTIVE = ["systemctl", "--user", "is-active", "--quiet", UNIT]

// "ISO_Level3_Shift", "Menu" from the generated Hyprland shortcut file.
function hotkeys(lua) {
  var match = /omaflow_hotkey\s*=\s*\{([^}]*)\}/.exec(String(lua || ""))
  return match ? (match[1].match(/"[^"]+"/g) || []).map(function(name) { return name.slice(1, -1) }) : []
}
