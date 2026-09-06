import QtQuick
import QtQuick.Window

Connections {
  required property Item scope
  target: scope.Window.window
  function onActiveFocusItemChanged() {
    var focused = target ? target.activeFocusItem : null
    var node = focused
    while (node && node !== scope) {
      var ancestor = node.parent
      if (ancestor && ancestor.contentItem !== undefined
          && ancestor.contentY !== undefined && ancestor.contentHeight !== undefined) {
        var point = focused.mapToItem(ancestor.contentItem, 0, 0)
        var next = ancestor.contentY
        if (point.y < next) next = point.y
        else if (point.y + Math.min(focused.height, ancestor.height) > next + ancestor.height)
          next = point.y + Math.min(focused.height, ancestor.height) - ancestor.height
        ancestor.contentY = Math.max(0, Math.min(ancestor.contentHeight - ancestor.height, next))
      }
      node = ancestor
    }
  }
}
