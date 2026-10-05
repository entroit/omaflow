import QtQuick
import QtQuick.Controls as Controls
import "Dates.js" as Dates

// Any day, and if you like a time, for a to-do: a month to pick from and a
// time field, under the date it changes. A time is when you are reminded.
Item {
  id: picker

  property bool open: false
  property Item anchorItem: null
  property string today: ""
  // What it opens on: the to-do's date and time, if it has them.
  property string date: ""
  property string time: ""
  signal picked(string date, string time)

  anchors.fill: parent
  visible: open
  z: 90

  property string month: ""
  property string chosen: ""
  readonly property var typedTime: Dates.clockTime(timeInput.text)
  readonly property bool ready: chosen.length > 0 && typedTime !== null

  onOpenChanged: if (open) {
    chosen = date || today
    month = chosen.slice(0, 7)
    timeInput.text = time
  }
  function set() {
    if (!ready) return
    open = false
    picked(chosen, typedTime)
  }

  MouseArea { anchors.fill: parent; onClicked: picker.open = false }

  Shadowed {
    id: panel
    readonly property point origin: picker.anchorItem && picker.open
      ? picker.anchorItem.mapToItem(picker, picker.anchorItem.width, picker.anchorItem.height + 6) : Qt.point(0, 0)
    x: Math.max(8, Math.min(picker.width - width - 8, origin.x - width))
    // Above the date when there is no room under it.
    y: origin.y + height + 8 > picker.height && picker.anchorItem
      ? Math.max(8, origin.y - height - picker.anchorItem.height - 12) : origin.y
    width: 262
    height: body.implicitHeight + 28
    radius: Theme.radiusCard + 2
    color: Theme.fill8
    shadowOpacity: 0.45
    MouseArea { anchors.fill: parent }

    Column {
      id: body
      x: 14; y: 14
      width: parent.width - 28
      spacing: 12
      JournalCalendar {
        width: parent.width
        month: picker.month
        selected: picker.chosen
        today: picker.today
        onPicked: function(date) { picker.chosen = date }
        onMonthShifted: function(delta) { picker.month = Dates.shiftMonth(picker.month, delta) }
      }
      Row {
        width: parent.width
        spacing: 10
        UiText { anchors.verticalCenter: parent.verticalCenter; text: "Time"; muted: true }
        Controls.TextField {
          id: timeInput
          anchors.verticalCenter: parent.verticalCenter
          width: 96; height: 32
          leftPadding: 10; rightPadding: 10
          color: Theme.text
          placeholderText: "None"
          placeholderTextColor: Theme.secondary
          selectionColor: Theme.alpha(Theme.accent, 0.4)
          font.family: Theme.sans
          font.pixelSize: 13
          selectByMouse: true
          background: Rectangle {
            radius: 8
            color: Theme.fill4
            border.width: timeInput.activeFocus ? 1.5 : 1
            border.color: picker.typedTime === null ? Theme.red : timeInput.activeFocus ? Theme.accent : Theme.divider
          }
          onAccepted: picker.set()
          Keys.onEscapePressed: picker.open = false
          Accessible.name: "Time, such as 15:00 or 3pm"
        }
        UiText {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - x
          wrapMode: Text.Wrap
          font.pixelSize: 12
          muted: picker.typedTime !== null
          color: picker.typedTime === null ? Theme.redText : Theme.secondary
          text: picker.typedTime === null ? "Like 15:00 or 3pm" : picker.typedTime ? "Reminds you" : "Optional"
        }
      }
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
          Pill { kind: "fill"; text: "Cancel"; size: 13; verticalPadding: 5; onClicked: picker.open = false }
          Pill { kind: "primary"; text: "Set"; size: 13; verticalPadding: 5; enabled: picker.ready; onClicked: picker.set() }
        }
      }
    }
  }
}
