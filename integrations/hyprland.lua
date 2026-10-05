-- The OmaFlow window floats, centred at the size it is designed for, so
-- opening it never rearranges the windows already on the workspace.
-- Super T tiles it for a longer session. It stays opaque: reading and
-- writing over the text of another window is hard.
o.window({ class = "^org\\.quickshell$", title = "^OmaFlow$" }, {
  float = true,
  center = true,
  size = { 880, 720 },
  tag = "-default-opacity",
  opacity = "1 1",
})

-- Shortcuts come from ~/.config/omaflow/config.toml via the generated
-- shortcut.lua, which install, the Settings panel and omaflow reload-config
-- write. A broken generated file must not abort Hyprland.
local omaflow_hotkey = {}
local omaflow_consumed_keys = {}
local omaflow_shortcuts = { window = "SUPER + SHIFT + V", journal = "", open_journal = "", todo = "", open_todos = "" }

local omaflow_override_path = (os.getenv("XDG_CONFIG_HOME")
  or ((os.getenv("HOME") or "") .. "/.config")) .. "/omaflow/shortcut.lua"
local omaflow_chunk = loadfile(omaflow_override_path)
if omaflow_chunk then
  local ok, override = pcall(omaflow_chunk)
  if ok and type(override) == "table" then
    if type(override.hotkey) == "table" and #override.hotkey > 0 then
      omaflow_hotkey = override.hotkey
      omaflow_consumed_keys = type(override.consumed) == "table" and override.consumed or {}
    end
    -- Files written before these settings existed keep the defaults.
    for _, action in ipairs({ "window", "journal", "open_journal", "todo", "open_todos" }) do
      if type(override[action]) == "string" then
        omaflow_shortcuts[action] = override[action]
      end
    end
  end
end

-- Opening the window, journal entries and to-dos work without a dictation hotkey, so
-- they are bound before that is checked. Empty means unbound.
if omaflow_shortcuts.window ~= "" then
  o.bind(omaflow_shortcuts.window, "OmaFlow window", "omarchy-shell -q entroit.omaflow toggle")
end
-- The journal and to-do shortcuts work like the dictation key: hold one to
-- talk, or double-tap to keep going hands-free. Hyprland runs the press; the
-- key-state watcher below reports when that key comes up, whichever modifier
-- is let go first, and only while the shortcut is held, so typing costs
-- nothing.
local omaflow_held = {}
local omaflow_modifier_keys = {
  SUPER = { "Super_L", "Super_R" }, SHIFT = { "Shift_L", "Shift_R" }, CTRL = { "Control_L", "Control_R" },
  ALT = { "Alt_L", "Alt_R" }, MOD5 = { "ISO_Level3_Shift" },
}
local function omaflow_hold(binding, label, take)
  if binding == "" then return end
  o.bind(binding, label, "omaflow " .. take .. "-press")
  local parts = {}
  for part in string.gmatch(binding, "[^+%s]+") do table.insert(parts, part) end
  local key = table.remove(parts)
  -- A letter is looked up as the key that types it, without Shift.
  if #key == 1 then key = string.lower(key) end
  local modifiers = {}
  for _, name in ipairs(parts) do table.insert(modifiers, omaflow_modifier_keys[name] or { name }) end
  table.insert(omaflow_held, {
    key = key, modifiers = modifiers, release = "omaflow " .. take .. "-release", down = false, held = false,
  })
end
omaflow_hold(omaflow_shortcuts.journal, "OmaFlow journal entry", "journal")
omaflow_hold(omaflow_shortcuts.todo, "OmaFlow to-do", "todo")

local function omaflow_any_down(keys)
  for _, key in ipairs(keys) do
    if hl.is_key_down(key) then return true end
  end
  return false
end

local function omaflow_update_held()
  for _, shortcut in ipairs(omaflow_held) do
    local down = hl.is_key_down(shortcut.key)
    if down and not shortcut.down then
      -- Pressed with its modifiers: this is the shortcut, not typing.
      shortcut.held = true
      for _, keys in ipairs(shortcut.modifiers) do
        if not omaflow_any_down(keys) then shortcut.held = false end
      end
    elseif shortcut.down and not down and shortcut.held then
      shortcut.held = false
      hl.exec_cmd(shortcut.release)
    end
    shortcut.down = down
  end
end
if omaflow_shortcuts.open_journal ~= "" then
  o.bind(omaflow_shortcuts.open_journal, "OmaFlow journal", "omarchy-shell -q entroit.omaflow toggleJournal")
end
if omaflow_shortcuts.open_todos ~= "" then
  o.bind(omaflow_shortcuts.open_todos, "OmaFlow to-dos", "omarchy-shell -q entroit.omaflow toggleTodos")
end

if #omaflow_held > 0 then
  hl.on("input.keyboard.key", function()
    hl.timer(omaflow_update_held, { timeout = 1, type = "oneshot" })
  end)
end

if #omaflow_hotkey == 0 then return end
local omaflow_chord_down = false

-- Reserving the key is also what lists dictation in Omarchy's Super K menu,
-- so the label names the whole chord in words people use.
local omaflow_key_names = {
  ISO_Level3_Shift = "AltGr", Control_L = "Ctrl", Control_R = "Ctrl",
  Shift_L = "Shift", Shift_R = "Shift", Alt_L = "Alt", Alt_R = "Alt",
  Super_L = "Super", Super_R = "Super",
}
local omaflow_chord = {}
for _, key in ipairs(omaflow_hotkey) do
  table.insert(omaflow_chord, omaflow_key_names[key] or key)
end
for _, key in ipairs(omaflow_consumed_keys) do
  o.bind(key, "OmaFlow dictate, hold " .. table.concat(omaflow_chord, " + "), hl.dsp.no_op(), { ignore_mods = true })
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
