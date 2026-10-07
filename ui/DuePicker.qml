import QtQuick
import QtQuick.Controls as Controls
import "Dates.js" as Dates

// Any day, and if you like a time, for a to-do: for what the When menu does
// not offer. Two weeks to pick from, where almost every to-do lands, the
// usual times or one typed, and one line that says when it reminds you,
// with the earlier times and Off under it.
Item {
  id: picker

  property bool open: false
  property Item anchorItem: null
  property string today: ""
  // The moment now, "YYYY-MM-DD HH:MM", so a reminder already passed says so.
  property string now: ""
  // What it opens on: the to-do's date and time, if it has them.
  property string date: ""
  property string time: ""
  // Its reminder as the list gives it: "" for the default, "off", or a
  // moment set by hand. And the default, in minutes before.
  property string reminder: ""
  property int remindBefore: 0
  // "default", "off", minutes before, or "" to keep a moment that is none
  // of these, such as one set from Later.
  signal picked(string date, string time, string remind)

  anchors.fill: parent
  visible: open
  z: 90

  readonly property var times: ["09:00", "12:00", "15:00", "18:00"]
  // The Monday the two weeks start on.
  property string start: ""
  property string chosen: ""
  // One of the usual times, or "" for none; Other… types one instead.
  property string chipTime: ""
  property bool other: false
  readonly property var typedTime: other ? Dates.clockTime(timeInput.text) : chipTime
  readonly property bool ready: chosen.length > 0 && typedTime !== null
  // "0" to "60", "off", or "keep" for a moment set some other way.
  property string remind: ""
  // A choice picked by hand stays that time, even the one that is the
  // default; left alone, a to-do on the default follows it if it changes.
  property bool remindPicked: false
  readonly property string at: chosen && typedTime ? chosen + " " + typedTime : ""
  // A moment set some other way keeps its distance from the time, as the
  // list moves it; one after the old time falls back to the default.
  readonly property string kept: {
    if (remind !== "keep" || !at || !reminder || reminder === "off") return ""
    var gap = date && time ? Dates.minutesBetween(reminder, date + " " + time) : -1
    return Dates.later(at, -(gap >= 0 ? gap : remindBefore))
  }
  // When the chosen reminder goes off, or "" for none.
  readonly property string remindsAt: !at || remind === "off" ? ""
    : remind === "keep" ? kept
    : Dates.later(at, -Number(remind))
  // The Remind me line: what will happen.
  readonly property string remindText: !at ? "Add a time to be reminded"
    : remind === "off" || !remindsAt ? "Off"
    : "At " + Dates.remindAt(remindsAt, chosen, today)

  // Opened, the chosen day has the keyboard; closed, the keyboard goes back
  // where it was, as for a menu.
  property Item returnFocus: null
  onOpenChanged: if (!open) {
    remindMenu.open = false
    var item = returnFocus
    returnFocus = null
    if (item && item.visible) item.forceActiveFocus()
  } else {
    returnFocus = Window.activeFocusItem
    chosen = date || today
    start = Dates.weekStart(chosen)
    var opening = Dates.clockTime(time) || ""
    other = opening.length > 0 && times.indexOf(opening) < 0
    chipTime = other ? "" : opening
    timeInput.text = other ? opening : ""
    remindPicked = false
    remind = !reminder ? String(remindBefore)
      : reminder === "off" ? "off"
      : date && time && Dates.EARLIER.indexOf(Dates.minutesBetween(reminder, date + " " + time)) >= 0
        ? String(Dates.minutesBetween(reminder, date + " " + time))
      : "keep"
    Qt.callLater(function() { if (picker.open) days.focusDay(picker.chosen) })
  }
  function set() {
    if (!ready) return
    open = false
    picked(chosen, typedTime, !typedTime || remind === "keep" ? "" : !remindPicked && !reminder ? "default" : remind)
  }
  // The keyboard goes with the day picked, as Tab lands on the chosen one.
  function pickDay(day) {
    days.focusDay(day)
    chosen = day
  }
  function pickTime(value) {
    other = false
    chipTime = chipTime === value ? "" : value
  }

  MouseArea { anchors.fill: parent; onClicked: picker.open = false }

  Shadowed {
    id: panel
    readonly property point origin: picker.anchorItem && picker.open
      ? picker.anchorItem.mapToItem(picker, picker.anchorItem.width, picker.anchorItem.height + 6) : Qt.point(0, 0)
    x: Math.max(8, Math.min(picker.width - width - 8, origin.x - width + 9))
    // Above the date when there is no room under it.
    y: origin.y + height + 8 > picker.height && picker.anchorItem
      ? Math.max(8, origin.y - height - picker.anchorItem.height - 12) : origin.y
    width: 340
    height: body.implicitHeight + 36
    radius: Theme.radiusPanel
    color: Theme.fill8
    shadowOpacity: 0.45
    MouseArea { anchors.fill: parent }

    // Esc closes it from anywhere inside, the days included, and Tab goes
    // round inside it rather than into the page behind.
    FocusScope {
      anchors.fill: parent
      Keys.onEscapePressed: picker.open = false

      // Tab past the last control lands here and goes round to the first;
      // Shift+Tab past the first lands on `head` and goes to the last.
      Item {
        id: head
        activeFocusOnTab: picker.open
        onActiveFocusChanged: if (activeFocus) tail.nextItemInFocusChain(false).forceActiveFocus(Qt.BacktabFocusReason)
      }

      Column {
        id: body
        x: 18; y: 18
        width: parent.width - 36
        spacing: 14

        // ------------------------------------------------------ two weeks
        Column {
          id: days
          width: parent.width
          spacing: 4
          readonly property real cell: width / 7
          // A day the keyboard moved to, taken by its cell once it is drawn.
          property string focusing: ""
          function focusDay(day) {
            if (day < picker.start) picker.start = Dates.weekStart(day)
            else if (day > Dates.addDays(picker.start, 13)) picker.start = Dates.addDays(Dates.weekStart(day), -7)
            focusing = day
          }

          Item {
            width: parent.width
            height: 26
            UiText {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: picker.start ? Dates.fortnightTitle(picker.start) : ""
              font.pixelSize: 14
              weight: Font.DemiBold
            }
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              Repeater {
                model: [{ icon: "left", days: -7, name: "Previous week" }, { icon: "right", days: 7, name: "Next week" }]
                Rectangle {
                  required property var modelData
                  width: 26; height: 24; radius: 12
                  color: stepMouse.containsMouse ? Theme.fill18 : "transparent"
                  activeFocusOnTab: true
                  border.width: activeFocus ? 2 : 0
                  border.color: Theme.accent
                  Icon { anchors.centerIn: parent; name: modelData.icon; size: 9; color: Theme.secondary }
                  MouseArea { id: stepMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.start = Dates.addDays(picker.start, modelData.days) }
                  Keys.onReturnPressed: picker.start = Dates.addDays(picker.start, modelData.days)
                  Keys.onEnterPressed: picker.start = Dates.addDays(picker.start, modelData.days)
                  Keys.onSpacePressed: picker.start = Dates.addDays(picker.start, modelData.days)
                  Accessible.role: Accessible.Button
                  Accessible.name: modelData.name
                }
              }
            }
          }

          Row {
            Repeater {
              model: ["M", "T", "W", "T", "F", "S", "S"]
              UiText {
                required property string modelData
                width: days.cell
                horizontalAlignment: Text.AlignHCenter
                text: modelData
                muted: true
                font.pixelSize: 11
              }
            }
          }

          Repeater {
            model: [0, 7]
            Row {
              id: week
              required property int modelData
              Repeater {
                model: picker.start ? Dates.fortnight(picker.start).slice(week.modelData, week.modelData + 7) : []
                Item {
                  id: cell
                  required property string modelData
                  readonly property bool isToday: modelData === picker.today
                  readonly property bool isChosen: modelData === picker.chosen
                  readonly property bool past: modelData < picker.today
                  width: days.cell
                  height: 34
                  // Tab lands on the chosen day, or the first of the two weeks
                  // when it is not in them; arrows move from there.
                  activeFocusOnTab: picker.chosen >= picker.start && picker.chosen <= Dates.addDays(picker.start, 13)
                    ? isChosen : modelData === picker.start
                  function claim() { if (days.focusing === modelData) { days.focusing = ""; forceActiveFocus() } }
                  Component.onCompleted: claim()
                  Connections { target: days; function onFocusingChanged() { cell.claim() } }
                  Rectangle {
                    anchors.centerIn: parent
                    width: 32; height: 32; radius: 16
                    color: cell.isChosen ? Theme.accent : dayMouse.containsMouse ? Theme.fill18 : "transparent"
                    border.width: cell.isToday && !cell.isChosen ? 1.5 : 0
                    border.color: Theme.accent
                    UiText {
                      anchors.centerIn: parent
                      text: String(Number(cell.modelData.slice(8)))
                      weight: cell.isToday || cell.isChosen ? Font.Bold : Font.Normal
                      color: cell.isChosen ? Theme.onAccent : cell.past ? Theme.secondary : Theme.text
                    }
                    Rectangle {
                      anchors.fill: parent
                      anchors.margins: -3
                      radius: width / 2
                      color: "transparent"
                      border.width: 2
                      border.color: Theme.accent
                      visible: cell.activeFocus
                    }
                  }
                  MouseArea { id: dayMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.pickDay(cell.modelData) }
                  Keys.onReturnPressed: picker.pickDay(modelData)
                  Keys.onEnterPressed: picker.pickDay(modelData)
                  Keys.onSpacePressed: picker.pickDay(modelData)
                  Keys.onLeftPressed: days.focusDay(Dates.addDays(modelData, -1))
                  Keys.onRightPressed: days.focusDay(Dates.addDays(modelData, 1))
                  Keys.onUpPressed: days.focusDay(Dates.addDays(modelData, -7))
                  Keys.onDownPressed: days.focusDay(Dates.addDays(modelData, 7))
                  Accessible.role: Accessible.Button
                  Accessible.name: Dates.full(modelData) + (isToday ? ", today" : "")
                  Accessible.checkable: true
                  Accessible.checked: isChosen
                }
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.divider }

        // ----------------------------------------------------------- time
        Column {
          width: parent.width
          spacing: 8
          UiText { text: "Time"; muted: true; font.pixelSize: 12; weight: Font.DemiBold }
          Row {
            spacing: 5
            Repeater {
              model: picker.times
              Pill {
                required property string modelData
                kind: picker.typedTime === modelData && !picker.other ? "primary" : "fill"
                text: modelData
                size: 13
                verticalPadding: 5
                horizontalPadding: 8
                onClicked: picker.pickTime(modelData)
                Accessible.name: modelData + (picker.typedTime === modelData && !picker.other ? ", chosen. Press again for no time" : "")
              }
            }
            Pill {
              visible: !picker.other
              kind: "outline"
              text: "Other…"
              size: 13
              verticalPadding: 5
              horizontalPadding: 8
              onClicked: { picker.other = true; timeInput.forceActiveFocus() }
              Accessible.name: "Type another time"
            }
            // Other… opens the typed time in its place.
            Controls.TextField {
              id: timeInput
              visible: picker.other
              width: 82; height: 26
              leftPadding: 10; rightPadding: 10; topPadding: 0; bottomPadding: 0
              verticalAlignment: TextInput.AlignVCenter
              color: Theme.text
              placeholderText: "3pm"
              placeholderTextColor: Theme.secondary
              selectionColor: Theme.alpha(Theme.accent, 0.4)
              // The words stay in the text colour, which reads on the tint in light themes too.
              selectedTextColor: Theme.text
              font.family: Theme.sans
              font.pixelSize: 13
              selectByMouse: true
              background: Rectangle {
                radius: 13
                color: Theme.fill4
                border.width: timeInput.activeFocus ? 1.5 : 1
                border.color: picker.typedTime === null ? Theme.red : timeInput.activeFocus ? Theme.accent : Theme.outline
              }
              onAccepted: picker.set()
              Accessible.name: "Time, such as 15:00 or 3pm"
            }
          }
          UiText {
            visible: picker.typedTime === null
            font.pixelSize: 12
            color: Theme.redText
            text: "Like 15:00 or 3pm"
          }

          Item {
            width: parent.width
            height: 28
            UiText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Remind me"; muted: true }
            Rectangle {
              id: remindLine
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: remindRow.width + 16
              height: 26
              radius: 13
              enabled: picker.at.length > 0
              color: remindMouse.containsMouse ? Theme.fill18 : "transparent"
              activeFocusOnTab: enabled
              Row {
                id: remindRow
                anchors.centerIn: parent
                spacing: 6
                UiText { anchors.verticalCenter: parent.verticalCenter; text: picker.remindText; muted: !picker.at }
                Icon { visible: picker.at.length > 0; anchors.verticalCenter: parent.verticalCenter; name: "down"; size: 8; color: Theme.secondary }
              }
              Rectangle { anchors.fill: parent; anchors.margins: -3; radius: height / 2; color: "transparent"; border.width: 2; border.color: Theme.accent; visible: remindLine.activeFocus }
              MouseArea { id: remindMouse; anchors.fill: parent; enabled: parent.enabled; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: remindMenu.open = true }
              Keys.onReturnPressed: remindMenu.open = true
              Keys.onEnterPressed: remindMenu.open = true
              Keys.onSpacePressed: remindMenu.open = true
              Accessible.role: Accessible.Button
              Accessible.name: "Remind me: " + picker.remindText
            }
          }
          // A reminder that has already passed goes off as soon as it is set.
          UiText {
            visible: picker.now.length > 0 && picker.remindsAt.length > 0 && picker.remindsAt < picker.now
            width: parent.width
            wrapMode: Text.Wrap
            font.pixelSize: 12
            muted: true
            text: "That time has passed, so it reminds you as soon as you set it."
          }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.divider }

        Item {
          width: parent.width
          height: 30
          UiText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: picker.chosen ? Dates.dueAt(picker.chosen, picker.typedTime || "", picker.today) : ""
            weight: Font.DemiBold
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Pill { kind: "fill"; text: "Cancel"; size: 13; verticalPadding: 6; horizontalPadding: 12; onClicked: picker.open = false }
            Pill { kind: "primary"; text: "Set"; size: 13; verticalPadding: 6; horizontalPadding: 14; enabled: picker.ready; onClicked: picker.set() }
          }
        }
      }
      Item {
        id: tail
        activeFocusOnTab: picker.open
        onActiveFocusChanged: if (activeFocus) head.nextItemInFocusChain(true).forceActiveFocus(Qt.TabFocusReason)
      }
    }
  }

  // The times a reminder can be, the default among them, and Off.
  PopupMenu {
    id: remindMenu
    anchorItem: remindLine
    panelWidth: 240
    name: "Remind me"
    items: !picker.at ? [] : Dates.remindChoices(picker.at, picker.chosen).map(function(choice) {
      return { label: choice.before, action: String(choice.minutes),
               detail: choice.minutes === picker.remindBefore ? "Default" : undefined,
               aside: choice.label,
               checked: picker.remind === String(choice.minutes) }
    }).concat(picker.remind === "keep" && picker.kept ? [{ label: Dates.remindAt(picker.kept, picker.chosen, picker.today), action: "keep", aside: "As set", checked: true }] : [])
      .concat([{ label: "Off", action: "off", checked: picker.remind === "off" }])
    onPicked: function(action) {
      if (action === "keep") return
      picker.remind = action
      picker.remindPicked = true
    }
  }
}
