-- Exercise the real adapter without changing the desktop or its key state.
local down, commands = {}, {}
local callback
hl = {
  is_key_down = function(key) return down[key] == true end,
  exec_cmd = function(command) table.insert(commands, command) end,
  timer = function(fn) fn() end,
  on = function(event, fn) assert(event == "input.keyboard.key"); callback = fn end,
  dsp = { no_op = function() return function() end end },
}
o = { bind = function() end }
local original_loadfile = loadfile
loadfile = function(path)
  if path:match("shortcut.lua$") then return function() return {hotkey={"ISO_Level3_Shift","Menu"}, consumed={"Menu"}} end end
  return original_loadfile(path)
end
dofile("integrations/hyprland.lua")
local function key(name, pressed) down[name] = pressed; callback() end
for _, order in ipairs({{"Menu", "ISO_Level3_Shift"}, {"ISO_Level3_Shift", "Menu"}}) do
  commands = {}
  key(order[1], true); assert(#commands == 0)
  key(order[2], true); assert(commands[1] == "omaflow press")
  key(order[2], true); assert(#commands == 1)
  key(order[1], false); assert(commands[2] == "omaflow release")
  key(order[2], false); assert(#commands == 2)
end
print("PASS compositor chord ordering, repeated key events and either-key release")
