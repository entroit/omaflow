#!/usr/bin/env python3
"""Validate and atomically save OmaFlow's Hyprland shortcuts, rolling back on errors.

The dictation hotkey is a chord of XKB keys (--keys). Opening the window,
starting a journal entry and opening the journal are ordinary Hyprland
bindings (--action window|journal|open_journal|todo|open_todos --bind).
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/release/omaflow"

def config_path():
    return Path(os.environ.get("OMAFLOW_CONFIG", str(Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home()/".config"))) / "omaflow/config.toml")))

def config_command(*args):
    result = subprocess.run([str(BINARY), *args], capture_output=True, text=True, timeout=8)
    if result.returncode != 0:
        # A mistake in config.toml: pass on what OmaFlow says about it.
        raise ValueError(result.stderr.strip() or result.stdout.strip() or "OmaFlow could not read its settings")
    return result.stdout


MODIFIERS = {"Shift_L": 1, "Shift_R": 1, "Control_L": 4, "Control_R": 4,
             "Alt_L": 8, "Alt_R": 8, "Super_L": 64, "Super_R": 64,
             "ISO_Level3_Shift": 128}


def parse_keys(value):
    keys = [key.strip() for key in re.split(r"[, +]+", value) if key.strip()]
    if len(keys) != len(set(keys)) or len(keys) > 4:
        raise ValueError("Choose up to four different keys")
    library = ctypes.CDLL("libxkbcommon.so.0")
    library.xkb_keysym_from_name.argtypes = [ctypes.c_char_p, ctypes.c_int]
    library.xkb_keysym_from_name.restype = ctypes.c_uint32
    for key in keys:
        if not re.fullmatch(r"[A-Za-z0-9_]+", key) or not library.xkb_keysym_from_name(key.encode(), 0):
            raise ValueError(f"Unknown XKB key: {key}. Try F9, F13, Control_L, Shift_L, or Menu.")
    return keys


# Keys that type nothing, so binding one alone takes nothing away from other apps.
TYPES_NOTHING = re.compile(r"F[0-9]+|Menu|Pause|Print|Insert|Scroll_Lock")
# MOD5 is AltGr.
BINDING_MODIFIERS = {"SUPER": 64, "WIN": 64, "META": 64, "SHIFT": 1, "CTRL": 4, "CONTROL": 4, "ALT": 8, "MOD5": 128, "ALTGR": 128}
ACTIONS = {"window": "OmaFlow window", "journal": "OmaFlow journal entry", "open_journal": "OmaFlow journal",
           "todo": "OmaFlow to-do", "open_todos": "OmaFlow to-dos"}
NAMES = {"window": "Open OmaFlow", "journal": "Journal entry", "open_journal": "Open the journal",
         "todo": "To-do", "open_todos": "Open to-dos"}


def parse_binding(value):
    """"super+shift+v" -> "SUPER + SHIFT + V"; "f13" -> "F13"; empty turns the shortcut off."""
    parts = [part.strip() for part in value.split("+") if part.strip()]
    if not parts:
        return ""
    *modifiers, key = parts
    names = []
    for modifier in modifiers:
        name = modifier.upper()
        if name not in BINDING_MODIFIERS:
            raise ValueError(f"{modifier} is not a modifier. Use Super, Shift, Ctrl or Alt, then one key.")
        name = {"WIN": "SUPER", "META": "SUPER", "CONTROL": "CTRL", "ALTGR": "MOD5"}.get(name, name)
        if name in names:
            raise ValueError(f"{modifier} is listed twice")
        names.append(name)
    if key.upper() in BINDING_MODIFIERS:
        raise ValueError("End with the key to press, such as V")
    if re.fullmatch(r"f[0-9]+", key, re.IGNORECASE):
        key = key.upper()
    # A physical key, recorded while AltGr or Shift changed what it types:
    # Hyprland matches the key as it is without them, in your layout.
    code = re.fullmatch(r"code:([0-9]+)", key)
    if code:
        key = base_keysym(int(code.group(1)))
    key = parse_keys(key)[0]
    if len(key) == 1:
        key = key.upper()
    if not names and not TYPES_NOTHING.fullmatch(key):
        raise ValueError(f"{key} alone would stop typing {key} in every app. Add Super, Shift, Ctrl or Alt, or use a key that types nothing, such as F13.")
    order = ["SUPER", "CTRL", "ALT", "MOD5", "SHIFT"]
    return " + ".join(sorted(names, key=order.index) + [key])


# How keys read in messages, the same as in the Settings table (ui/Keys.js).
LABELS = {"minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/", "semicolon": ";",
          "apostrophe": "'", "bracketleft": "[", "bracketright": "]", "backslash": "\\", "grave": "`",
          "plus": "+", "numbersign": "#", "less": "<", "ssharp": "ß", "adiaeresis": "ä", "odiaeresis": "ö",
          "udiaeresis": "ü", "space": "Space", "Return": "Enter", "Prior": "Page Up", "Next": "Page Down",
          "Scroll_Lock": "Scroll Lock", "ISO_Level3_Shift": "AltGr", "Alt_R": "Right Alt",
          "Control_R": "Right Ctrl", "Super_R": "Right Super", "Shift_R": "Right Shift", "MOD5": "AltGr",
          "periodcentered": "·", "endash": "–"}


def label(binding):
    """"SUPER + ISO_Level3_Shift" -> "Super + AltGr"."""
    return " + ".join(LABELS.get(part, part.title() if part.isupper() else part) for part in binding.split(" + "))


def base_keysym(keycode):
    """The XKB name of the key at `keycode` with no modifiers, in the layout
    of Hyprland's main keyboard: what Hyprland matches a binding against."""
    try:
        keyboards = json.loads(subprocess.run(["hyprctl", "-j", "devices"], capture_output=True, text=True, timeout=8).stdout)["keyboards"]
        keyboard = next((k for k in keyboards if k.get("main")), keyboards[0])
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
        keyboard = {}
    library = ctypes.CDLL("libxkbcommon.so.0")

    class RuleNames(ctypes.Structure):
        _fields_ = [(field, ctypes.c_char_p) for field in ("rules", "model", "layout", "variant", "options")]

    library.xkb_context_new.restype = ctypes.c_void_p
    library.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.POINTER(RuleNames), ctypes.c_int]
    library.xkb_keymap_new_from_names.restype = ctypes.c_void_p
    library.xkb_state_new.argtypes = [ctypes.c_void_p]
    library.xkb_state_new.restype = ctypes.c_void_p
    library.xkb_state_key_get_one_sym.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    library.xkb_state_key_get_one_sym.restype = ctypes.c_uint32
    library.xkb_keysym_get_name.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]
    for name in ("xkb_state_unref", "xkb_keymap_unref", "xkb_context_unref"):
        getattr(library, name).argtypes = [ctypes.c_void_p]
    context = library.xkb_context_new(0)
    names = RuleNames(*((keyboard.get(field) or "").encode() or None for field in ("rules", "model", "layout", "variant", "options")))
    keymap = library.xkb_keymap_new_from_names(context, ctypes.byref(names), 0)
    if not keymap:
        library.xkb_context_unref(context)
        raise ValueError("Could not read your keyboard layout to name that key")
    state = library.xkb_state_new(keymap)
    symbol = library.xkb_state_key_get_one_sym(state, keycode)
    buffer = ctypes.create_string_buffer(64)
    library.xkb_keysym_get_name(symbol, buffer, 64)
    library.xkb_state_unref(state)
    library.xkb_keymap_unref(keymap)
    library.xkb_context_unref(context)
    name = buffer.value.decode()
    if not symbol or name == "NoSymbol":
        raise ValueError("That key has no name in your keyboard layout. Choose another key.")
    return name


def binding_mask(binding):
    *modifiers, _ = binding.split(" + ")
    mask = 0
    for modifier in modifiers:
        mask |= BINDING_MODIFIERS[modifier]
    return mask


def lua_file(shortcut):
    return ("-- Generated from omaflow/config.toml [shortcut]. Do not edit this file.\n"
            + "local omaflow_hotkey = { " + ", ".join(json.dumps(key) for key in shortcut["keys"]) + " }\n"
            + "local omaflow_consumed_keys = { " + ", ".join(json.dumps(key) for key in shortcut["consumed"]) + " }\n"
            + "return {\n  hotkey = omaflow_hotkey,\n  consumed = omaflow_consumed_keys,\n"
            + "  window = " + json.dumps(shortcut.get("window", "")) + ",\n"
            + "  journal = " + json.dumps(shortcut.get("journal", "")) + ",\n"
            + "  open_journal = " + json.dumps(shortcut.get("open_journal", "")) + ",\n"
            + "  todo = " + json.dumps(shortcut.get("todo", "")) + ",\n"
            + "  open_todos = " + json.dumps(shortcut.get("open_todos", "")) + ",\n}\n").encode()


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".omaflow-hotkey-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=8, check=True).stdout


def save(keys, consumed, write_only=False):
    if not keys:
        raise ValueError("Choose at least one trigger key")
    if any(key not in keys or key in MODIFIERS for key in consumed):
        raise ValueError("Reserved keys must be non-modifier keys in your shortcut")
    bindings = json.loads(run("hyprctl", "-j", "binds"))
    mask = 0
    for key in keys:
        mask |= MODIFIERS.get(key, 0)
    for binding in bindings:
        if "OmaFlow" in binding.get("description", ""):
            continue
        key = binding.get("key", "")
        if key in consumed or (key in keys and binding.get("modmask", 0) == mask):
            raise ValueError(f"{key} already controls {binding.get('description') or 'another Hyprland action'}. Choose a different key.")
    apply({"keys": keys, "consumed": consumed}, write_only)
    return "Shortcut saved: " + " + ".join(keys)


def save_binding(action, value, write_only=False):
    binding = parse_binding(value)
    if binding:
        mask, key = binding_mask(binding), binding.rsplit(" + ", 1)[1]
        for existing in json.loads(run("hyprctl", "-j", "binds")):
            if existing.get("description") == ACTIONS[action]:
                continue
            if existing.get("key", "").upper() == key.upper() and existing.get("modmask", 0) == mask:
                raise ValueError(f"{label(binding)} already controls {existing.get('description') or 'another Hyprland action'}. Choose a different key.")
    apply({action: binding}, write_only)
    name = NAMES[action]
    return f"{name}: {label(binding)}" if binding else f"{name} has no shortcut"


def lua_path():
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "omaflow/shortcut.lua"


def apply(update, write_only):
    """Write the setting and the generated Lua together, or neither."""
    path = lua_path()
    personal = config_path()
    old_config = personal.read_bytes() if personal.exists() else None
    previous = path.read_bytes() if path.exists() else None
    try:
        config_command("config-shortcut", json.dumps(update))
        shortcut = json.loads(config_command("effective-config"))["shortcut"]
        write_atomic(path, lua_file(shortcut))
        if not write_only:
            run("hyprctl", "reload")
            errors = run("hyprctl", "configerrors").strip()
            if errors:
                raise ValueError(errors)
    except Exception:
        if old_config is None:
            personal.unlink(missing_ok=True)
        else:
            write_atomic(personal, old_config)
        if previous is None:
            path.unlink(missing_ok=True)
        else:
            write_atomic(path, previous)
        if not write_only:
            run("hyprctl", "reload")
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keys")
    parser.add_argument("--sync", action="store_true", help="validate and apply the TOML shortcut")
    parser.add_argument("--consumed", default="")
    parser.add_argument("--write-only", action="store_true")
    parser.add_argument("--action", choices=sorted(ACTIONS))
    parser.add_argument("--bind", help="for --action: modifiers and one key, or empty to turn it off")
    args = parser.parse_args()
    try:
        if args.action:
            if args.bind is None:
                raise ValueError("Use --action with --bind")
            message = save_binding(args.action, args.bind, args.write_only)
            if not args.write_only:
                config_command("configure", "shortcut", json.dumps({args.action: parse_binding(args.bind)}))
            print(json.dumps({"ok": True, "message": message}))
            return 0
        if args.sync:
            if args.keys:
                raise ValueError("Use --sync or --keys, not both")
            # Resolve defaults without changing the file before save() has
            # captured its rollback copy.
            config = json.loads(config_command("effective-config"))
            keys = config["shortcut"]["keys"]
            consumed = config["shortcut"]["consumed"]
            for action in ACTIONS:
                parse_binding(config["shortcut"].get(action, ""))
            keys, consumed = parse_keys(",".join(keys)), parse_keys(",".join(consumed))
            # The shell syncs after every change to config.toml. When the
            # shortcuts are already in effect, write nothing and leave
            # Hyprland alone: a write here would change the file again.
            if lua_path().exists() and lua_path().read_bytes() == lua_file(config["shortcut"]):
                print(json.dumps({"ok": True, "message": "Shortcuts unchanged"}))
                return 0
            message = save(keys, consumed, args.write_only)
        elif args.keys:
            message = save(parse_keys(args.keys), parse_keys(args.consumed), args.write_only)
        else:
            raise ValueError("Use --keys or --sync")
        if not args.sync and not args.write_only:
            config_command("configure", "shortcut", json.dumps({"keys":parse_keys(args.keys),"consumed":parse_keys(args.consumed)}))
        print(json.dumps({"ok": True, "message": message}))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "message": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
