import QtQuick
import QtQuick.Controls as Controls
import "Dates.js" as Dates

// One to-do: a circle to tick, the words, and when it is due. In a view
// across lists it also says which list it is in. Move, Edit and Delete
// appear under the pointer, and clicking the date changes it. Ticking draws
// a line through the words before the task moves to Done, so you see what
// you finished.
Rectangle {
  id: row

  required property var todo
  property bool current: false
  property bool editing: false
  // Just ticked: still in its place while the line is drawn through it.
  property bool settling: false
  // Deleted: greyed out in its place while it can come back.
  property bool ghost: false
  property string today: ""
  // The time now, HH:MM, so a to-do due at 15:00 today is late at 15:01.
  property string now: ""
  // Across lists (Today, Upcoming, All, Done), the list it is in.
  property bool showList: false
  property bool canMove: false
  property bool showDue: true
  // What the edit field holds: the words as typed so far, kept by the page so
  // they survive the row being rebuilt.
  property string draft: ""
  signal toggled()
  signal moveRequested(Item anchor)
  signal dueRequested(Item anchor)
  signal editRequested()
  signal saveRequested(string text)
  signal draftEdited(string text)
  signal cancelRequested()
  signal deleteRequested()

  // What the Move and date menus open under.
  readonly property Item moveAnchor: moveButton
  readonly property Item dueAnchor: dueBox
  readonly property bool done: Boolean(todo.done) || settling
  readonly property string due: todo.due ? String(todo.due) : ""
  readonly property string time: todo.time ? String(todo.time) : ""
  readonly property bool late: due.length > 0 && today.length > 0 && !done
    && (due < today || (due === today && time.length > 0 && now.length > 0 && time < now))
  readonly property bool showActions: (hover.hovered || current) && !editing && !ghost && !settling

  // The words' height even while editing, so the list never jumps.
  implicitHeight: Math.max(44, words.implicitHeight + 22)
  radius: Theme.radiusPanel
  color: (showActions || editing) ? Theme.fill4 : "transparent"
  Behavior on color { ColorAnimation { duration: 120 } }

  HoverHandler { id: hover; enabled: !row.ghost }

  Item {
    id: content
    anchors.fill: parent
    opacity: row.ghost ? 0.38 : 1

    // The circle. Ticked, it fills; the pop is the only motion on the page.
    Rectangle {
      id: box
      x: 14
      y: 11 + (words.lineHeight - height) / 2
      width: 20; height: 20; radius: 10
      color: row.done ? Theme.text : "transparent"
      border.width: row.done ? 0 : 1.5
      border.color: boxMouse.containsMouse ? Theme.text : Theme.outline
      Behavior on color { ColorAnimation { duration: 140 } }
      Icon { anchors.centerIn: parent; name: "check"; size: 11; color: Theme.background; visible: row.done }
      SequentialAnimation {
        id: pop
        NumberAnimation { target: box; property: "scale"; to: 0.82; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: box; property: "scale"; to: 1; duration: 220; easing.type: Easing.OutBack; easing.overshoot: 2.4 }
      }
      MouseArea {
        id: boxMouse
        anchors.fill: parent
        anchors.margins: -8
        enabled: !row.ghost && !row.settling
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { if (!row.done) pop.restart(); row.toggled() }
      }
      Accessible.role: Accessible.CheckBox
      Accessible.checked: row.done
      Accessible.name: row.todo.text
    }

    UiText {
      id: words
      visible: !row.editing
      x: 48
      y: 11
      width: (row.showList ? badge.x : dueBox.x) - x - 12
      text: row.todo.text
      font.pixelSize: 15
      lineHeight: 22
      wrapMode: Text.Wrap
      verticalAlignment: Text.AlignTop
      color: row.done ? Theme.secondary : Theme.text
      font.strikeout: Boolean(row.todo.done) && !row.settling || (row.settling && lineCount > 1)
      Behavior on color { ColorAnimation { duration: 300 } }
      MouseArea {
        anchors.fill: parent
        enabled: !row.ghost && !row.done
        onDoubleClicked: row.editRequested()
      }
    }

    // The line drawn through a task as it is ticked, left to right.
    Rectangle {
      visible: row.settling && words.lineCount === 1
      x: words.x
      y: words.y + words.lineHeight / 2
      height: 1.5
      color: Theme.secondary
      width: 0
      NumberAnimation on width {
        running: row.settling
        from: 0; to: words.contentWidth
        duration: 260; easing.type: Easing.OutCubic
      }
    }

    Controls.TextField {
      id: field
      visible: row.editing
      x: 48 - leftPadding
      y: 11 - topPadding
      width: dueBox.x - x - 12
      color: Theme.text
      background: null
      font.family: Theme.sans
      font.pixelSize: 15
      selectionColor: Theme.alpha(Theme.accent, 0.4)
      selectByMouse: true
      // The cursor at the end, nothing selected: a stray key adds a letter
      // instead of replacing the whole to-do.
      function begin() { text = row.draft || row.todo.text; cursorPosition = text.length; forceActiveFocus() }
      onVisibleChanged: if (visible) begin()
      Component.onCompleted: if (visible) begin()
      onTextEdited: row.draftEdited(text)
      onAccepted: finish()
      // Clicking elsewhere keeps what you typed, like most lists.
      onActiveFocusChanged: if (!activeFocus && row.editing) finish()
      Keys.onEscapePressed: row.cancelRequested()
      function finish() {
        var next = text.trim()
        if (next.length === 0 || next === row.todo.text) row.cancelRequested()
        else row.saveRequested(next)
      }
      Accessible.name: "Edit the to-do"
    }

    // The list it is in, in views across lists.
    Row {
      id: badge
      visible: row.showList
      x: row.showDue ? dueBox.x - 96 : parent.width - 10 - width
      width: 92
      y: 11 + (words.lineHeight - height) / 2
      spacing: 7
      opacity: row.showActions ? 0 : 1
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 7; height: 7; radius: 3.5
        color: row.todo.list ? Theme.listColor(row.todo.list) : "transparent"
        border.width: row.todo.list ? 0 : 1.2
        border.color: Theme.outline
      }
      UiText { anchors.verticalCenter: parent.verticalCenter; width: 78; elide: Text.ElideRight; text: row.todo.list || "Inbox"; muted: true }
    }

    // When it is due. Click to set or change it.
    Item {
      id: dueBox
      x: parent.width - 10 - width
      y: 11
      // Wide enough for "Tomorrow 15:00"; the words make room.
      width: Math.max(76, dueLabel.implicitWidth)
      height: words.lineHeight
      UiText {
        id: dueLabel
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // Upcoming says the day above, so only the time is left to say.
        text: row.due && row.showDue ? Dates.dueAt(row.due, row.time, row.today)
          : row.due && row.time ? row.time
          : row.showActions && !row.done ? (row.due ? "Change" : "Add date") : ""
        muted: !row.late && !(row.due === row.today && !row.done)
        color: row.late ? Theme.redText : muted ? Theme.secondary : Theme.text
        weight: row.due === row.today && !row.done ? Font.DemiBold : Font.Normal
      }
      MouseArea {
        anchors.fill: parent
        enabled: !row.ghost && !row.done && !row.settling
        cursorShape: Qt.PointingHandCursor
        onClicked: row.dueRequested(dueBox)
      }
      Accessible.role: Accessible.Button
      Accessible.name: row.due ? "Due " + Dates.dueAt(row.due, row.time, row.today) + ". Change the date" : "Add a date"
    }

    // Under the pointer, over the end of the words: what you can do with it.
    Rectangle {
      id: actions
      anchors.right: dueBox.left
      anchors.rightMargin: 4
      y: 11 + (words.lineHeight - height) / 2
      width: buttons.width + 18
      height: 26
      color: row.color
      visible: opacity > 0
      opacity: row.showActions ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 100 } }
      Rectangle {
        anchors.right: parent.left
        width: 18; height: parent.height
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: Theme.alpha(row.color, 0) }
          GradientStop { position: 1; color: row.color }
        }
      }
      Row {
        id: buttons
        anchors.right: parent.right
        spacing: 2
        Pill { id: moveButton; kind: "ghost"; text: "Move"; size: 12; verticalPadding: 4; visible: row.canMove && !row.done; enabled: row.showActions; onClicked: row.moveRequested(moveButton) }
        Pill { kind: "ghost"; text: "Edit"; size: 12; verticalPadding: 4; visible: !row.done; enabled: row.showActions; onClicked: row.editRequested() }
        Pill { kind: "ghost"; text: "Delete"; size: 12; verticalPadding: 4; enabled: row.showActions; onClicked: row.deleteRequested() }
      }
    }
  }
}
