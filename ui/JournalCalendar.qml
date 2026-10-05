import QtQuick
import "Dates.js" as Dates

// One month, Monday first. A dot under a day means something was written;
// while searching, the days that mention the words are marked instead.
Column {
  id: calendar

  property string month: "2026-09"
  property string selected: ""
  property string today: ""
  property var counts: ({})        // iso date -> entries
  property var highlighted: []     // iso dates, while searching
  signal picked(string date)
  signal monthShifted(int delta)

  spacing: 6

  Item {
    width: parent.width
    height: 28
    UiText {
      anchors.left: parent.left
      anchors.leftMargin: 4
      anchors.verticalCenter: parent.verticalCenter
      text: Dates.monthTitle(calendar.month)
      font.pixelSize: 14
      weight: Font.DemiBold
    }
    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2
      Repeater {
        model: [{ icon: "left", delta: -1, name: "Previous month" }, { icon: "right", delta: 1, name: "Next month" }]
        Rectangle {
          required property var modelData
          width: 26; height: 24; radius: 12
          color: hover.containsMouse ? Theme.fill8 : "transparent"
          activeFocusOnTab: true
          border.width: activeFocus ? 2 : 0
          border.color: Theme.accent
          Icon { anchors.centerIn: parent; name: modelData.icon; size: 9; color: Theme.text }
          MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: calendar.monthShifted(modelData.delta) }
          Keys.onReturnPressed: calendar.monthShifted(modelData.delta)
          Accessible.role: Accessible.Button
          Accessible.name: modelData.name
        }
      }
    }
  }

  Row {
    width: parent.width
    spacing: (width - 7 * 30) / 6
    Repeater {
      model: ["M", "T", "W", "T", "F", "S", "S"]
      UiText {
        required property string modelData
        width: 30
        horizontalAlignment: Text.AlignHCenter
        text: modelData
        muted: true
        font.pixelSize: 11
        weight: Font.DemiBold
      }
    }
  }

  Repeater {
    model: Dates.weeks(calendar.month)
    Row {
      required property var modelData
      width: calendar.width
      spacing: (width - 7 * 30) / 6
      Repeater {
        model: modelData
        Item {
          id: cell
          required property string modelData
          readonly property bool isDay: modelData.length > 0
          readonly property bool isToday: modelData === calendar.today
          readonly property bool isSelected: modelData === calendar.selected
          readonly property bool future: isDay && modelData > calendar.today
          readonly property bool hit: calendar.highlighted.indexOf(modelData) >= 0
          readonly property bool written: (calendar.counts[modelData] || 0) > 0
          width: 30
          height: 34

          Rectangle {
            visible: cell.isDay
            width: 26; height: 26; radius: 13
            anchors.horizontalCenter: parent.horizontalCenter
            color: cell.isToday ? Theme.accent
              : cell.isSelected || cell.hit ? Theme.fill18
              : dayMouse.containsMouse ? Theme.fill8 : "transparent"
            UiText {
              anchors.centerIn: parent
              text: cell.isDay ? String(Number(cell.modelData.slice(8))) : ""
              font.pixelSize: 12
              weight: cell.isToday ? Font.Bold : Font.Normal
              color: cell.isToday ? Theme.onAccent : cell.future ? Theme.secondary : Theme.text
            }
          }
          Rectangle {
            visible: cell.isDay && (cell.hit || (calendar.highlighted.length === 0 && cell.written))
            width: 4; height: 4; radius: 2
            anchors.horizontalCenter: parent.horizontalCenter
            y: 28
            color: cell.hit ? Theme.accent : Theme.secondary
          }
          MouseArea {
            id: dayMouse
            anchors.fill: parent
            // Later days open too: a note written there waits for that day.
            enabled: cell.isDay
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: calendar.picked(cell.modelData)
          }
          Accessible.role: Accessible.Button
          Accessible.name: cell.isDay ? Dates.full(cell.modelData) + (cell.written ? ", " + calendar.counts[cell.modelData] + " entries" : "") : ""
        }
      }
    }
  }
}
