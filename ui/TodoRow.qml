import QtQuick
import QtQuick.Controls as Controls
import "Dates.js" as Dates

// One to-do, in lanes that line up down the page: a circle to tick, the
// words, in views across lists the list it is in, when it is due, and ⋯ for
// Move, Edit and Delete. The pointer only tints the row and lifts the date
// and ⋯ so they read as buttons; nothing appears or moves. Clicking the date
// opens the When menu. Ticking draws a line through the words before the
// task moves to Done, so you see what you finished. A to-do with a time
// reminds you at it unless it shows a bell: the time it reminds you instead,
// or struck through, not at all. Once it has, in Today's Bubbled up, Later
// and Done wait on it instead.
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
  property bool showDue: true
  // In Bubbled up: its reminder went off at this moment, "YYYY-MM-DD HH:MM".
  property bool bubbled: false
  property string remindedAt: ""
  // What the edit field holds: the words as typed so far, kept by the page so
  // they survive the row being rebuilt.
  property string draft: ""
  signal toggled()
  signal dueRequested(Item anchor)
  signal menuRequested(Item anchor)
  signal reminderRequested(Item anchor)
  signal laterRequested(Item anchor)
  signal editRequested()
  signal saveRequested(string text)
  signal draftEdited(string text)
  signal cancelRequested()

  // What the When, row, reminder and Later menus open under.
  readonly property Item dueAnchor: bubbled ? laterButton : dueChip
  readonly property Item menuAnchor: bubbled ? doneButton : moreButton
  readonly property Item reminderAnchor: bell.visible ? bell : dueAnchor
  readonly property Item laterAnchor: laterButton
  readonly property bool done: Boolean(todo.done) || settling
  readonly property string due: todo.due ? String(todo.due) : ""
  readonly property string time: todo.time ? String(todo.time) : ""
  readonly property bool late: due.length > 0 && today.length > 0 && !done
    && (due < today || (due === today && time.length > 0 && now.length > 0 && time < now))
  // Under the pointer or the keyboard: the row lifts at once, in the theme's
  // own hover surface, and the date and ⋯ read as buttons.
  readonly property bool lifted: (hover.hovered || current) && !editing && !ghost && !settling
  readonly property bool live: !ghost && !settling && !done
  // The to-do as its buttons name it to a screen reader.
  readonly property string named: "“" + String(todo.text || "") + "”"
  // "off", a moment set by hand, or "" when it follows the default.
  readonly property string reminder: todo.reminder && time ? String(todo.reminder) : ""

  // The lanes, from the right edge in: ⋯, when, and the list.
  readonly property real whenWidth: showDue ? 150 : 96
  readonly property real whenX: width - 12 - 28 - 12 - whenWidth
  // A narrow window keeps the list's dot and gives its name's room to the words.
  readonly property bool compactList: whenX - 12 - 92 - 12 - 48 < 200
  readonly property real listWidth: compactList ? 10 : 92
  readonly property real wordsEnd: bubbled ? nudge.x - 14 : showList && !editing ? whenX - 12 - listWidth - 12 : whenX - 12

  // The words' height even while editing, so the list never jumps, unless
  // the edit itself runs onto another line.
  implicitHeight: Math.max(44, (editing ? Math.max(words.implicitHeight, field.contentHeight) : words.implicitHeight) + 22)
  radius: Theme.radiusPanel
  color: editing ? Theme.fill4 : lifted ? Theme.hover : "transparent"
  // The keyboard cursor is a ring as well, so it never reads as the pointer resting.
  border.width: current && !editing ? 1.5 : 0
  border.color: Theme.accent

  HoverHandler { id: hover; enabled: !row.ghost }

  Accessible.role: Accessible.ListItem
  Accessible.name: String(todo.text || "") + (due ? ", due " + Dates.dueAt(due, time, today) : "") + (showList ? ", " + (todo.list || "Inbox") : "")
    + (bubbled && remindedAt ? ", reminded " + Dates.remindSaid(remindedAt, today, today) : "")
    + (todo.done ? ", done" : "")
  Accessible.focusable: true
  Accessible.focused: current

  // A right-click anywhere on the row opens the same menu as ⋯.
  MouseArea {
    anchors.fill: parent
    enabled: !row.ghost && !row.settling
    acceptedButtons: Qt.RightButton
    onClicked: row.menuRequested(row.menuAnchor)
  }

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
      border.color: boxMouse.containsMouse || row.lifted ? Theme.text : Theme.outline
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
      width: row.wordsEnd - x
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

    // A long to-do wraps as it does on the row; Enter saves it, as a to-do is
    // one line in the file.
    Controls.TextArea {
      id: field
      visible: row.editing
      x: 48 - leftPadding
      y: 11 - topPadding
      width: row.wordsEnd + 8 - x
      leftPadding: 8; rightPadding: 8; topPadding: 5; bottomPadding: 5
      color: Theme.text
      background: Rectangle {
        radius: 8
        color: "transparent"
        border.width: 1.5
        border.color: Theme.accent
      }
      font.family: Theme.sans
      font.pixelSize: 15
      wrapMode: TextEdit.Wrap
      selectionColor: Theme.alpha(Theme.accent, 0.4)
      selectedTextColor: Theme.text
      selectByMouse: true
      // The cursor at the end, nothing selected: a stray key adds a letter
      // instead of replacing the whole to-do.
      function begin() { text = row.draft || row.todo.text; cursorPosition = text.length; forceActiveFocus() }
      onVisibleChanged: if (visible) begin()
      Component.onCompleted: if (visible) begin()
      onTextChanged: if (row.editing) row.draftEdited(text)
      Keys.onReturnPressed: finish()
      Keys.onEnterPressed: finish()
      // Clicking elsewhere keeps what you typed, like most lists.
      onActiveFocusChanged: if (!activeFocus && row.editing) finish()
      Keys.onEscapePressed: row.cancelRequested()
      function finish() {
        var next = text.replace(/\s*\n\s*/g, " ").trim()
        if (next.length === 0 || next === row.todo.text) row.cancelRequested()
        else row.saveRequested(next)
      }
      Accessible.name: "Edit “" + row.todo.text + "”"
    }

    // The list it is in, in views across lists. Not while editing: the field
    // runs to the date.
    Row {
      id: badge
      visible: row.showList && !row.editing && !row.bubbled
      x: row.whenX - 12 - row.listWidth
      width: row.listWidth
      y: 11 + (words.lineHeight - height) / 2
      spacing: 7
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 7; height: 7; radius: 3.5
        color: row.todo.list ? Theme.listColor(row.todo.list) : "transparent"
        border.width: row.todo.list ? 0 : 1.2
        border.color: Theme.outline
      }
      UiText { visible: !row.compactList; anchors.verticalCenter: parent.verticalCenter; width: 78; elide: Text.ElideRight; text: row.todo.list || "Inbox"; muted: true }
      Accessible.role: Accessible.StaticText
      Accessible.name: "In " + (row.todo.list || "Inbox")
    }

    // When it is due, and before it a reminder other than the default: when,
    // or that there is none. Each opens its menu.
    Item {
      id: whenLane
      visible: !row.bubbled
      x: row.whenX
      y: 11
      width: row.whenWidth
      height: words.lineHeight

      Item {
        id: dueChip
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: dueLabel.implicitWidth
        height: parent.height
        // Lifted with the row, so the date reads as the button it is.
        Rectangle {
          visible: row.live
          anchors.centerIn: parent
          width: parent.width + 18
          height: 24
          radius: 12
          color: dueMouse.containsMouse ? Theme.fill18 : row.lifted ? Theme.fill8 : "transparent"
        }
        UiText {
          id: dueLabel
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          // Upcoming says the day above, so only the time is left to say.
          text: row.showDue ? (row.due ? Dates.dueAt(row.due, row.time, row.today) : row.done ? "" : "No date")
            : row.time ? row.time : row.done ? "" : "No time"
          color: row.late ? Theme.redText : row.due === row.today && !row.done ? Theme.text : Theme.secondary
          weight: row.due === row.today && !row.done ? Font.DemiBold : Font.Normal
        }
        MouseArea {
          id: dueMouse
          anchors.fill: parent
          anchors.margins: -6
          enabled: row.live
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: row.dueRequested(dueChip)
        }
        Accessible.role: Accessible.Button
        Accessible.name: row.due ? "Due " + Dates.dueAt(row.due, row.time, row.today) + ". Change when " + row.named + " is due" : "Add a date to " + row.named
        Accessible.ignored: !row.live
      }

      Item {
        id: bell
        visible: row.reminder.length > 0 && !row.done
        // Said with its time where the lane has room, else the bell alone.
        readonly property bool roomy: bellIcon.width + 4 + remindLabel.implicitWidth + 16 + dueChip.width <= whenLane.width
        anchors.right: dueChip.left
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        width: bellRow.width
        height: parent.height
        Rectangle {
          anchors.centerIn: parent
          width: parent.width + 12
          height: 24
          radius: 12
          color: bellMouse.containsMouse ? Theme.fill18 : "transparent"
        }
        Row {
          id: bellRow
          anchors.verticalCenter: parent.verticalCenter
          spacing: 4
          Icon {
            id: bellIcon
            anchors.verticalCenter: parent.verticalCenter
            name: row.reminder === "off" ? "bell-off" : "bell"
            size: 12
            color: row.lifted ? Theme.text : Theme.secondary
          }
          UiText {
            id: remindLabel
            visible: row.reminder !== "off" && bell.roomy
            anchors.verticalCenter: parent.verticalCenter
            text: row.reminder.length > 0 && row.reminder !== "off" ? Dates.remindAt(row.reminder, row.due, row.today) : ""
            font.pixelSize: 12
            muted: true
          }
        }
        MouseArea {
          id: bellMouse
          anchors.fill: parent
          anchors.margins: -6
          enabled: row.live
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: row.reminderRequested(bell)
        }
        Accessible.role: Accessible.Button
        Accessible.name: (row.reminder === "off" ? "No reminder" : row.reminder ? "Reminds you " + Dates.remindSaid(row.reminder, row.due, row.today) : "")
          + ". Change the reminder for " + row.named
      }
    }

    // ⋯: Move, Edit and Delete. Always in its place, quiet until the row is
    // under the pointer.
    Rectangle {
      id: moreButton
      visible: !row.bubbled
      x: row.width - 12 - width
      y: 11 + (words.lineHeight - height) / 2
      width: 28; height: 28; radius: 14
      color: moreMouse.containsMouse ? Theme.fill18 : row.lifted ? Theme.fill8 : "transparent"
      Icon { anchors.centerIn: parent; name: "more"; size: 14; color: moreMouse.containsMouse || row.lifted ? Theme.text : Theme.secondary }
      MouseArea {
        id: moreMouse
        anchors.fill: parent
        enabled: !row.ghost && !row.settling
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.menuRequested(moreButton)
      }
      Accessible.role: Accessible.Button
      Accessible.name: (row.done ? "Delete " : "Move, edit or delete ") + row.named
    }

    // Bubbled up: when it reminded you, then again later, or finished.
    Row {
      id: nudge
      visible: row.bubbled
      x: row.width - 12 - width
      y: 11 + (words.lineHeight - height) / 2
      spacing: 8
      UiText {
        anchors.verticalCenter: parent.verticalCenter
        rightPadding: 6
        text: row.remindedAt ? "Reminded " + Dates.remindSaid(row.remindedAt, row.today, row.today) : ""
        muted: true
      }
      Pill {
        id: laterButton
        anchors.verticalCenter: parent.verticalCenter
        kind: "fill"; text: "Later"; size: 13; verticalPadding: 4; horizontalPadding: 11
        enabled: row.live
        trailing: Component { Icon { name: "down"; size: 8; color: Theme.secondary } }
        onClicked: row.laterRequested(laterButton)
        Accessible.name: "Remind me again about " + row.named
      }
      Pill {
        id: doneButton
        anchors.verticalCenter: parent.verticalCenter
        kind: "primary"; text: "Done"; size: 13; verticalPadding: 4; horizontalPadding: 12
        enabled: row.live
        onClicked: { pop.restart(); row.toggled() }
        Accessible.name: "Mark " + row.named + " done"
      }
    }
  }
}
