.pragma library
// Key names as Hyprland and XKB write them, and how OmaFlow shows them.

// Keys a shortcut can end with, beyond letters, digits and F1 to F24: XKB
// names by keysym. Hyprland matches a binding on the key without Shift, so
// these are the unshifted names.
var BY_KEYSYM = {
  0x2d: "minus", 0x3d: "equal", 0x2c: "comma", 0x2e: "period", 0x2f: "slash",
  0x3b: "semicolon", 0x27: "apostrophe", 0x5b: "bracketleft", 0x5d: "bracketright",
  0x5c: "backslash", 0x60: "grave", 0x2b: "plus", 0x23: "numbersign", 0x3c: "less",
  0xdf: "ssharp", 0xe4: "adiaeresis", 0xf6: "odiaeresis", 0xfc: "udiaeresis",
  0xff67: "Menu", 0xff13: "Pause", 0xff14: "Scroll_Lock", 0xff61: "Print", 0xff63: "Insert",
  0xff50: "Home", 0xff57: "End", 0xff55: "Prior", 0xff56: "Next",
  0xff51: "Left", 0xff52: "Up", 0xff53: "Right", 0xff54: "Down",
  0x20: "space", 0xff0d: "Return", 0xff09: "Tab"
}

// Modifier keys, which can also be the last key of a shortcut: hold Super,
// tap AltGr.
var MODIFIER_BY_KEYSYM = {
  0xfe03: "ISO_Level3_Shift", 0xffe1: "Shift_L", 0xffe2: "Shift_R", 0xffe3: "Control_L",
  0xffe4: "Control_R", 0xffe9: "Alt_L", 0xffea: "Alt_R", 0xffeb: "Super_L", 0xffec: "Super_R"
}

var LABELS = {
  minus: "-", equal: "=", comma: ",", period: ".", slash: "/", semicolon: ";",
  apostrophe: "'", bracketleft: "[", bracketright: "]", backslash: "\\", grave: "`",
  plus: "+", numbersign: "#", less: "<", ssharp: "ß", adiaeresis: "ä", odiaeresis: "ö",
  udiaeresis: "ü", space: "Space", Return: "Enter", Prior: "Page Up", Next: "Page Down",
  Scroll_Lock: "Scroll Lock", ISO_Level3_Shift: "AltGr", Shift_L: "Shift", Shift_R: "Right Shift",
  Control_L: "Ctrl", Control_R: "Right Ctrl", Alt_L: "Alt", Alt_R: "Right Alt",
  Super_L: "Super", Super_R: "Right Super", SUPER: "Super", SHIFT: "Shift", CTRL: "Ctrl", ALT: "Alt",
  MOD5: "AltGr"
}

// "SUPER + SHIFT + minus" -> ["Super", "Shift", "-"]
function labels(binding) {
  return String(binding || "").split(" + ").map(function(part) { return part.trim() })
    .filter(function(part) { return part.length > 0 })
    .map(function(part) { return LABELS[part] || (part.length > 1 ? part.charAt(0) + part.slice(1).toLowerCase() : part) })
}

// One key's label, for XKB names in a chord.
function label(name) { return LABELS[name] || name }
