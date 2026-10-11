import QtQuick

// How every text field pastes. The shell never reads the clipboard itself:
// Qt reads whatever an app offers with no size or time limit, so an app that
// offers endless data could fill the shell's memory or freeze it. Pasting
// goes through `omaflow clipboard-text` instead, in its own process, which
// gives up after a few seconds or a megabyte.
//
// One sits inside each field and takes every way Qt would paste: Ctrl+V and
// Shift+Insert, the middle button's primary selection, and right-click, whose
// menu here pastes the same way. The field adds two lines, or four for a
// Controls.TextArea, which has Qt's own menu to replace:
//   Keys.onPressed: function(event) { if (paste.key(event)) return; ... }
//   Controls.ContextMenu.menu: null
//   Controls.ContextMenu.onRequested: function(at) { paste.openMenu(at) }
//   PasteGuard { id: paste; app: ... }
// A one-line field is a LineEdit, which has its own. Never a TextInput or
// TextField: those read the clipboard themselves (see LineEdit.qml).
// Dropped text needs nothing: Qt's text items do not take drops.
MouseArea {
  id: guard

  required property var app
  // The TextArea or TextEdit it sits in.
  readonly property Item field: parent
  // A one-line field gets a pasted line break as a space.
  property bool singleLine: false
  // A password, which is never cut or copied: LineEdit's text says so.
  readonly property bool hidden: field !== null && field.masked === true
  // Right-click opens Cut, Copy, Paste and Select all. A plain TextEdit has
  // no menu of its own to replace.
  property bool offersMenu: true
  // A field that ends its edit when it loses the keyboard waits while this
  // menu has it.
  readonly property bool menuOpen: menuLoader.item ? menuLoader.item.open : false
  readonly property bool editable: field !== null && field.enabled && field.visible && !field.readOnly

  anchors.fill: parent
  z: 10
  acceptedButtons: offersMenu ? Qt.MiddleButton | Qt.RightButton : Qt.MiddleButton
  // A MouseArea brings an arrow of its own; this is the field's, as Qt picks it.
  cursorShape: field && field.readOnly && !field.selectByMouse ? Qt.ArrowCursor : Qt.IBeamCursor
  // As Qt does: the press puts the cursor under the pointer, the release pastes.
  onPressed: function(mouse) { press(mouse.button, mouse.x, mouse.y) }
  onReleased: function(mouse) { if (mouse.button === Qt.MiddleButton) paste(true) }
  // Also for a press beside the field, at X, Y in the field.
  function press(button, x, y) {
    if (button === Qt.RightButton) openMenu(Qt.point(x, y))
    else if (editable) {
      field.forceActiveFocus()
      field.deselect()
      field.cursorPosition = field.positionAt(x, y)
    }
  }

  // True when EVENT was a paste key, which it then takes.
  function key(event) {
    if (!event.matches(StandardKey.Paste)) return false
    event.accepted = true
    paste(false)
    return true
  }

  // Gone before the answer comes, such as a row deleted meanwhile: nothing
  // to paste into.
  property var life: ({ live: true })
  Component.onDestruction: life.live = false

  function paste(primary) {
    if (!editable) return
    var app = guard.app, alive = guard.life
    app.spawn(primary ? ["omaflow", "clipboard-text", "--primary"] : ["omaflow", "clipboard-text"], function(stdout, stderr, code) {
      if (!alive.live) return
      if (code !== 0) app.toast(app.failureText(stderr, "Could not read the clipboard"), true)
      else guard.insert(String(stdout || ""))
    })
  }

  // Over the selection if there is one, else at the cursor, and undone with
  // Ctrl+Z. A field with a maximumLength takes what fits.
  function insert(text) {
    if (!editable) return
    text = singleLine ? text.replace(/\r\n|[\r\n\u2028\u2029]/g, " ") : text.replace(/\r\n?/g, "\n")
    if (field.maximumLength !== undefined)
      text = text.slice(0, Math.max(0, field.maximumLength - field.length + field.selectionEnd - field.selectionStart))
    if (text.length === 0) return
    var at = field.selectionStart
    if (field.selectionEnd > at) field.remove(at, field.selectionEnd)
    else at = field.cursorPosition
    var before = field.length
    field.insert(at, text)
    field.cursorPosition = at + field.length - before
  }

  // ---------------------------------------------------------------- menu
  // The menu takes the keyboard, which would clear the selection; it stays
  // for Cut and Copy and for Paste to replace, as with any menu.
  property bool wasPersistent: false
  Item { id: spot; width: 0; height: 0 }

  function openMenu(at) {
    if (!offersMenu || !field || !field.enabled || !field.visible) return
    var selected = field.selectionEnd > field.selectionStart && !hidden
    var items = []
    if (selected && editable) items.push({ label: "Cut", action: "cut", aside: "Ctrl+X" })
    if (selected) items.push({ label: "Copy", action: "copy", aside: "Ctrl+C" })
    if (editable) items.push({ label: "Paste", action: "paste", aside: "Ctrl+V" })
    if (field.length > 0) {
      if (items.length > 0) items.push({ divider: true })
      items.push({ label: "Select all", action: "select-all", aside: "Ctrl+A" })
    }
    if (items.length === 0) return
    // Opens at the pointer: the menu goes 6 under the spot it is given.
    spot.x = at.x
    spot.y = at.y - 6
    field.forceActiveFocus()
    wasPersistent = field.persistentSelection
    field.persistentSelection = true
    menuLoader.active = true
    menuLoader.item.items = items
    menuLoader.item.open = true
  }
  function act(action) {
    if (action === "cut") { if (!hidden) field.cut() }
    else if (action === "copy") { if (!hidden) field.copy() }
    else if (action === "paste") paste(false)
    else if (action === "select-all") field.selectAll()
  }

  // Over the whole window, as every menu is, so it is not cut off at the field.
  readonly property Item windowRoot: Window.window ? Window.window.contentItem : null
  Loader {
    id: menuLoader
    parent: guard.windowRoot || guard
    anchors.fill: parent
    z: 1000
    active: false
    sourceComponent: PopupMenu {
      anchorItem: spot
      align: "left"
      panelWidth: 184
      name: "Edit text"
      onOpenChanged: if (!open && guard.field) {
        guard.field.persistentSelection = guard.wasPersistent
        if (guard.field.visible) guard.field.forceActiveFocus()
      }
      onPicked: function(action) { guard.act(action) }
    }
  }
}
