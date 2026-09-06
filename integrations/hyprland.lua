-- The hotkey comes from ~/.config/omaflow/config.toml via the generated shortcut.lua.
local omaflow_hotkey = {}
local omaflow_consumed_keys = {}

-- shortcut.lua is generated from config.toml by install, the Settings panel
-- and omaflow reload-config. A broken generated file must not abort Hyprland.
local omaflow_override_path = (os.getenv("XDG_CONFIG_HOME")
  or ((os.getenv("HOME") or "") .. "/.config")) .. "/omaflow/shortcut.lua"
local omaflow_chunk = loadfile(omaflow_override_path)
if omaflow_chunk then
  local ok, override = pcall(omaflow_chunk)
  if ok and type(override) == "table" and type(override.hotkey) == "table"
    and #override.hotkey > 0 then
    omaflow_hotkey = override.hotkey
    omaflow_consumed_keys = type(override.consumed) == "table" and override.consumed or {}
  end
end
if #omaflow_hotkey == 0 then return end
local omaflow_chord_down = false

for _, key in ipairs(omaflow_consumed_keys) do
  o.bind(key, "Reserve for OmaFlow", hl.dsp.no_op(), { ignore_mods = true })
end

local function omaflow_all_keys_down()
  for _, key in ipairs(omaflow_hotkey) do
    if not hl.is_key_down(key) then
      return false
    end
  end
  return #omaflow_hotkey > 0
end

-- A normal Hyprland binding only accepts modifiers plus one final key; Menu is
-- not a modifier. Watching Hyprland's own key-state event makes arbitrary
-- one-, two-, or three-key chords reliable, order-independent, and symmetric:
-- pressing the final required key starts, releasing any required key stops.
local function omaflow_update_chord()
  local all_down = omaflow_all_keys_down()
  if all_down and not omaflow_chord_down then
    omaflow_chord_down = true
    hl.exec_cmd("omaflow press")
  elseif omaflow_chord_down and not all_down then
    omaflow_chord_down = false
    hl.exec_cmd("omaflow release")
  end
end

hl.on("input.keyboard.key", function()
  -- The event is emitted just before Hyprland updates its merged key-state
  -- table. Evaluate one millisecond later so the current press/release is
  -- included. Hyprland owns the timer; there is no helper process to leak.
  hl.timer(omaflow_update_chord, { timeout = 1, type = "oneshot" })
end)

-- Passive result cards never take focus from the application below. This
-- transparent release binding lets Escape dismiss them without swallowing it.
o.bind("Escape", "Dismiss OmaFlow result", "omaflow close", {
  release = true,
  ignore_mods = true,
  non_consuming = true,
  transparent = true,
})
