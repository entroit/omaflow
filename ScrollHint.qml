import QtQuick
import qs.Commons

// A clipped list gives no sign that anything is below it, so a page that
// continues past the fold reads as a page that ends there. This is the one
// mark that says otherwise: present only when there is somewhere to go,
// brighter while you are moving.
//
// Sits in a gutter the content reserves, rather than over the content.
Rectangle {
  id: hint

  required property Flickable view
  property bool reducedMotion: false

  readonly property real span: Math.max(0, view.contentHeight - view.height)

  anchors.right: parent.right
  anchors.rightMargin: Style.space(1)
  width: Style.space(3)
  radius: width / 2
  color: Util.alpha(Color.popups.text, view.moving ? 0.38 : 0.18)
  visible: span > 0

  height: Math.max(Style.space(24),
    view.height * (view.height / Math.max(1, view.contentHeight)))
  y: view.contentY + (view.height - height) * (view.contentY / Math.max(1, span))

  Behavior on color { ColorAnimation { duration: hint.reducedMotion ? 0 : 150 } }
}
