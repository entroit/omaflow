-- Exercise the real adapter without changing the desktop or its key state.
local down, commands = {}, {}
local callbacks = {}
hl = {
  is_key_down = function(key) return down[key] == true end,
  exec_cmd = function(command) table.insert(commands, command) end,
  timer = function(fn) fn() end,
  on = function(event, fn) assert(event == "input.keyboard.key"); table.insert(callbacks, fn) end,
  dsp = { no_op = function() return function() end end },
}
local binds, labels, windows, shortcut
o = {
  bind = function(key, label, command) binds[key] = command; labels[key] = label end,
  window = function(match, rules) table.insert(windows, {match = match, rules = rules}) end,
}
local original_loadfile = loadfile
loadfile = function(path)
  if path:match("shortcut.lua$") then return function() return shortcut end end
  return original_loadfile(path)
end
local function load(settings)
  binds, labels, windows, shortcut, callbacks = {}, {}, {}, settings, {}
  dofile("integrations/hyprland.lua")
end

-- A file from before these settings: the window opens with Super Shift V and
-- journal entries have no shortcut until one is chosen.
load({hotkey={"ISO_Level3_Shift","Menu"}, consumed={"Menu"}})
assert(binds["SUPER + SHIFT + V"] == "omarchy-shell -q entroit.omaflow toggle", "window shortcut defaults to Super Shift V")
for _, command in pairs(binds) do
  assert(command ~= "omaflow journal-press", "no journal shortcut by default")
  assert(command ~= "omarchy-shell -q entroit.omaflow toggleJournal", "no open-journal shortcut by default")
end
assert(labels["Menu"] == "OmaFlow dictate, hold AltGr + Menu", "Super K names the dictation chord")
-- Chosen shortcuts, and an empty one turned off; both work without a dictation hotkey.
load({hotkey={}, window="", journal="SUPER + ALT + J"})
assert(binds["SUPER + ALT + J"] == "omaflow journal-press")
-- Held like the dictation key: letting go of the key reports the release,
-- even when Super came up first; typing the letter alone reports nothing.
local function journal_key(name, pressed) down[name] = pressed; for _, fn in ipairs(callbacks) do fn() end end
commands = {}
journal_key("Super_L", true); journal_key("Alt_L", true); journal_key("j", true)
assert(#commands == 0, "the press itself is Hyprland's binding")
journal_key("Super_L", false); journal_key("Alt_L", false); journal_key("j", false)
assert(commands[1] == "omaflow journal-release", "release reported")
commands = {}
journal_key("j", true); journal_key("j", false)
assert(#commands == 0, "typing j is not the shortcut")
for _, command in pairs(binds) do assert(command ~= "omarchy-shell -q entroit.omaflow toggle", "empty turns the window shortcut off") end
load({hotkey={}, open_journal="SUPER + SHIFT + J"})
assert(binds["SUPER + SHIFT + J"] == "omarchy-shell -q entroit.omaflow toggleJournal", "open-journal shortcut when chosen")
assert(labels["SUPER + SHIFT + J"] == "OmaFlow journal", "Super K names it")
for _, command in pairs(binds) do assert(command ~= "omaflow todo-press", "no to-do shortcut by default") end
-- The to-do shortcut is held the same way, alongside the journal's.
load({hotkey={}, journal="SUPER + ALT + J", todo="MOD5 + T", open_todos="SUPER + SHIFT + T"})
assert(binds["MOD5 + T"] == "omaflow todo-press" and labels["MOD5 + T"] == "OmaFlow to-do")
assert(binds["SUPER + SHIFT + T"] == "omarchy-shell -q entroit.omaflow toggleTodos")
commands = {}
journal_key("ISO_Level3_Shift", true); journal_key("t", true)
journal_key("t", false); journal_key("ISO_Level3_Shift", false)
assert(#commands == 1 and commands[1] == "omaflow todo-release", "to-do release reported")

load({hotkey={"ISO_Level3_Shift","Menu"}, consumed={"Menu"}, window="SUPER + SHIFT + V", journal=""})
assert(#windows == 1 and windows[1].rules.float and windows[1].rules.center, "the window floats, centred")
-- Hyprland regexes: only Quickshell's window titled exactly OmaFlow.
assert(windows[1].match.class == "^org\\.quickshell$" and windows[1].match.title == "^OmaFlow$")
local function key(name, pressed) down[name] = pressed; for _, fn in ipairs(callbacks) do fn() end end
for _, order in ipairs({{"Menu", "ISO_Level3_Shift"}, {"ISO_Level3_Shift", "Menu"}}) do
  commands = {}
  key(order[1], true); assert(#commands == 0)
  key(order[2], true); assert(commands[1] == "omaflow press")
  key(order[2], true); assert(#commands == 1)
  key(order[1], false); assert(commands[2] == "omaflow release")
  key(order[2], false); assert(#commands == 2)
end
print("PASS compositor chord ordering, repeated key events and either-key release")
