pragma Singleton
import QtQuick

// OmaFlow's look, derived from whatever theme is active. The host hands over
// the theme's colors.toml (load) and everything else is mixed from five of its
// colours, so a light theme, a dark theme and a hand-made one all come out
// with the same structure and contrast.
//
// Shapes and type are OmaFlow's own: capsules for anything pressable, soft
// radii that grow with the size of the surface, Schibsted Grotesk for the
// interface and Newsreader for the journal.
QtObject {
  id: theme

  // ---------------------------------------------------------------- palette
  property color background: "#1a1b26"
  property color text: "#a9b1d6"
  property color accent: "#7aa2f7"
  property color red: "#f7768e"
  property color green: "#9ece6a"
  property color yellow: "#e0af68"
  property bool light: false
  // Off when the desktop turns animations off; motion then just cuts.
  property bool motion: true

  function mix(a, b, amount) {
    return Qt.rgba(a.r + (b.r - a.r) * amount,
                   a.g + (b.g - a.g) * amount,
                   a.b + (b.b - a.b) * amount, 1)
  }
  // A list's colour comes from its name, so it never changes when lists are
  // reordered. Red is left for what is late.
  readonly property var listColors: [yellow, accent, green, mix(accent, red, 0.5), mix(green, accent, 0.5), mix(yellow, red, 0.45)]
  function listColor(name) {
    var hash = 0
    var text = String(name || "").toLowerCase()
    for (var i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) % 9973
    return listColors[hash % listColors.length]
  }
  function alpha(c, amount) { return Qt.rgba(c.r, c.g, c.b, amount) }

  // Surfaces step up from the background toward the text colour.
  readonly property color fill4: mix(background, text, 0.04)
  readonly property color fill8: mix(background, text, 0.08)
  readonly property color fill18: mix(background, text, 0.18)
  readonly property color fill22: mix(background, text, 0.22)
  // A row under the pointer: the theme's own lighter surface, so it keeps the
  // theme's tint instead of a grey mixed from the text, taken only as far as a
  // gentle step (1.12:1) so even a theme whose lighter surface is a full grey
  // only lifts the row. Where that surface is fainter, it carries on from it
  // toward the text.
  property color lighterBackground: background
  readonly property color hover: contrast(background, lighterBackground) >= 1.12
    ? stepToward(background, background, lighterBackground, 1.12)
    : stepToward(background, lighterBackground, text, 1.12)
  // From `from` toward `to` until it stands `target` apart from `base`.
  function stepToward(base, from, to, target) {
    for (var step = 1; step <= 100; step++) {
      var c = mix(from, to, step / 100)
      if (contrast(c, base) >= target) return c
    }
    return to
  }
  readonly property color divider: mix(background, text, 0.12)
  readonly property color outline: mix(background, text, 0.40)
  // Also on fill22, where a hovered button shows its shortcut.
  readonly property color secondary: readable(mix(background, text, 0.71), 4.5, fill22)

  // Colours used as text or marks are checked against the background and
  // against fill18, the selected row or pressed control furthest from it, and
  // darkened or lightened until they read on both (WCAG 4.5:1 for words).
  // Every fill in between then reads too. A light theme darkens toward black,
  // which keeps the hue; mixing toward its grey text would turn yellow and
  // green into more grey.
  function luminance(c) {
    function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
  }
  function contrast(a, b) {
    var la = luminance(a), lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }
  // `darkest` is a fill past fill18 the colour must also read on.
  function readable(c, minimum, darkest) {
    var step = 0
    var result = c
    var toward = light ? Qt.rgba(0, 0, 0, 1) : text
    while ((contrast(result, background) < minimum || contrast(result, fill18) < minimum
        || (darkest !== undefined && contrast(result, darkest) < minimum)) && step < 20) {
      step++
      result = mix(c, toward, step / 20)
    }
    return result
  }
  readonly property color accentText: readable(accent, 4.5)
  readonly property color redText: readable(red, 4.5)
  readonly property color greenText: readable(green, 4.5)
  readonly property color yellowText: readable(yellow, 4.5)
  // Words drawn on an accent fill: the background colour when it reads, else
  // the text colour, else black or white for an accent that is neither light
  // nor dark enough for the theme's own colours.
  readonly property color accentInk: contrast(background, accent) >= 4.5 ? background
    : contrast(text, accent) >= 4.5 ? text
    : contrast(Qt.rgba(0, 0, 0, 1), accent) >= contrast(Qt.rgba(1, 1, 1, 1), accent) ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1)
  // QML reads "onAccent: …" as a signal handler, so the name every screen
  // uses cannot hold a binding; it is copied over instead.
  property color onAccent
  onAccentInkChanged: theme.onAccent = accentInk
  Component.onCompleted: theme.onAccent = accentInk

  // ------------------------------------------------------------------- type
  readonly property FontLoader grotesk: FontLoader { source: Qt.resolvedUrl("fonts/SchibstedGrotesk.ttf") }
  readonly property FontLoader serif: FontLoader { source: Qt.resolvedUrl("fonts/Newsreader.ttf") }
  readonly property FontLoader serifItalic: FontLoader { source: Qt.resolvedUrl("fonts/Newsreader-Italic.ttf") }
  readonly property string sans: grotesk.status === FontLoader.Ready ? grotesk.name : "sans-serif"
  readonly property string book: serif.status === FontLoader.Ready ? serif.name : "serif"
  // Keys, paths and code only.
  readonly property string mono: "JetBrainsMono Nerd Font"

  // ---------------------------------------------------------------- shapes
  readonly property int radiusKey: 6
  readonly property int radiusInput: 10
  readonly property int radiusCard: 12
  readonly property int radiusPanel: 16
  readonly property int radiusDialog: 20

  // ------------------------------------------------------------ theme file
  // colors.toml: `name = "#rrggbb"` lines. Older themes only have color0-15.
  function load(raw) {
    var values = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6}|[a-z]+)["']?/)
      if (match) values[match[1]] = match[2]
    }
    function pick(names, fallback) {
      for (var j = 0; j < names.length; j++)
        if (values[names[j]] && values[names[j]].charAt(0) === "#") return values[names[j]]
      return fallback
    }
    background = pick(["background", "color0"], background)
    text = pick(["foreground", "color7"], text)
    accent = pick(["accent", "blue", "color4"], accent)
    red = pick(["red", "color1"], red)
    green = pick(["green", "color2"], green)
    yellow = pick(["yellow", "color3"], yellow)
    lighterBackground = pick(["lighter_background"], background)
    light = values.mode === "light" || luminance(background) > 0.5
  }
}
