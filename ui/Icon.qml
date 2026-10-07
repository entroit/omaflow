import QtQuick
import QtQuick.Shapes

// Small vector glyphs drawn from SVG paths, so they stay sharp at any scale
// and take the theme's colours. Each is drawn in its own view box and scaled
// to `size`.
Item {
  id: icon

  property string name: "play"
  property color color: Theme.text
  property real size: 14

  readonly property var glyphs: ({
    "play": { box: [8, 10], fill: "M1 1l6 4-6 4Z" },
    "pause": { box: [8, 10], fill: "M0.5 2a1 1 0 0 1 1-1h0.4a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-0.4a1 1 0 0 1-1-1ZM5.1 2a1 1 0 0 1 1-1h0.4a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-0.4a1 1 0 0 1-1-1Z" },
    "mic": { box: [14, 16], fill: "M4 4a3 3 0 0 1 6 0v3a3 3 0 0 1-6 0Z", stroke: "M1.5 7.5a5.5 5.5 0 0 0 11 0M7 13v2", width: 1.6 },
    "folder": { box: [14, 12], stroke: "M1 2.2C1 1.5 1.5 1 2.2 1H5l1.4 1.6h5.4c.7 0 1.2.5 1.2 1.2v5.9c0 .7-.5 1.3-1.2 1.3H2.2C1.5 11 1 10.5 1 9.8Z", width: 1.3 },
    "more": { box: [14, 14], fill: "M1.7 7a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0-2.6 0ZM5.7 7a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0-2.6 0ZM9.7 7a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0-2.6 0Z" },
    "book": { box: [16, 14], stroke: "M8 3C6.5 1.8 4.2 1.4 1.5 1.6v9.6c2.7-.2 5 .2 6.5 1.4 1.5-1.2 3.8-1.6 6.5-1.4V1.6C11.8 1.4 9.5 1.8 8 3ZM8 3v9.6", width: 1.3 },
    "lock": { box: [12, 14], fill: "M2 6.5a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1Z", stroke: "M3.8 5.5V4a2.2 2.2 0 0 1 4.4 0v1.5", width: 1.4 },
    "check": { box: [14, 14], stroke: "M2.5 7.5l3 3 6-7", width: 1.8 },
    "warning": { box: [16, 14], stroke: "M8 1.5l6.5 11h-13ZM8 5.5v3.2M8 10.6v.2", width: 1.4 },
    "left": { box: [8, 12], stroke: "M6 1.5L1.8 6 6 10.5", width: 1.6 },
    "right": { box: [8, 12], stroke: "M2 1.5L6.2 6 2 10.5", width: 1.6 },
    "down": { box: [12, 8], stroke: "M1.5 2l4.5 4.2L10.5 2", width: 1.6 },
    "close": { box: [12, 12], stroke: "M2 2l8 8M10 2l-8 8", width: 1.6 },
    "return": { box: [14, 12], stroke: "M12.5 1.5v4.2a1.6 1.6 0 0 1-1.6 1.6H2M5 4.3L2 7.3l3 3", width: 1.5 },
    "search": { box: [14, 14], stroke: "M6 1.5a4.5 4.5 0 1 0 0 9a4.5 4.5 0 1 0 0-9ZM9.3 9.3l3.2 3.2", width: 1.5 },
    "bell": { box: [14, 14], stroke: "M3.4 10.2V6.6a3.6 3.6 0 0 1 7.2 0v3.6l1.2 1.3H2.2ZM5.7 13a1.4 1.4 0 0 0 2.6 0", width: 1.3 },
    "bell-off": { box: [14, 14], stroke: "M3.4 10.2V6.6a3.6 3.6 0 0 1 7.2 0v3.6l1.2 1.3H2.2ZM5.7 13a1.4 1.4 0 0 0 2.6 0M1.5 1.5l11 11", width: 1.3 },
    "dot": { box: [8, 8], fill: "M0 4a4 4 0 1 0 8 0a4 4 0 1 0-8 0Z" }
  })
  readonly property var glyph: glyphs[name] || glyphs["dot"]
  readonly property real ratio: glyph.box[0] / glyph.box[1]

  implicitWidth: ratio >= 1 ? size : size * ratio
  implicitHeight: ratio >= 1 ? size / ratio : size

  Shape {
    width: icon.glyph.box[0]
    height: icon.glyph.box[1]
    anchors.centerIn: parent
    scale: icon.width / icon.glyph.box[0]
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeWidth: -1
      fillColor: icon.glyph.fill ? icon.color : "transparent"
      PathSvg { path: icon.glyph.fill || "" }
    }
    ShapePath {
      strokeWidth: icon.glyph.stroke ? icon.glyph.width : -1
      strokeColor: icon.glyph.stroke ? icon.color : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: icon.glyph.stroke || "" }
    }
  }
}
