.pragma library
// English calendar words, so dates read the same whatever the system locale.

var WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var MONTHS = ["January", "February", "March", "April", "May", "June", "July",
              "August", "September", "October", "November", "December"]

function parse(iso) {
  var parts = String(iso).split("-")
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2] || 1))
}

function iso(date) {
  return date.getFullYear() + "-" + String(date.getMonth() + 1).padStart(2, "0")
    + "-" + String(date.getDate()).padStart(2, "0")
}

// "Friday, 25 September", with the year when it is not this year's.
function long(isoDate, todayIso) {
  var date = parse(isoDate)
  var text = WEEKDAYS[date.getDay()] + ", " + date.getDate() + " " + MONTHS[date.getMonth()]
  if (String(isoDate).slice(0, 4) !== String(todayIso).slice(0, 4)) text += " " + date.getFullYear()
  return text
}

// "Thursday, 25 September 2025"
function full(isoDate) {
  var date = parse(isoDate)
  return WEEKDAYS[date.getDay()] + ", " + date.getDate() + " " + MONTHS[date.getMonth()] + " " + date.getFullYear()
}

// "Today", "Yesterday", "Wed 16 Sep", "Wed 16 Sep 2025"
function short(isoDate, todayIso) {
  if (isoDate === todayIso) return "Today"
  var date = parse(isoDate)
  var today = parse(todayIso)
  if (Math.round((today - date) / 86400000) === 1) return "Yesterday"
  var text = WEEKDAYS[date.getDay()].slice(0, 3) + " " + date.getDate() + " " + MONTHS[date.getMonth()].slice(0, 3)
  if (date.getFullYear() !== today.getFullYear()) text += " " + date.getFullYear()
  return text
}

function monthTitle(isoMonth) {
  var date = parse(isoMonth + "-01")
  return MONTHS[date.getMonth()] + " " + date.getFullYear()
}

function shiftMonth(isoMonth, delta) {
  var date = parse(isoMonth + "-01")
  date.setMonth(date.getMonth() + delta)
  return iso(date).slice(0, 7)
}

// Monday-first weeks for one month: rows of ISO dates, "" for padding.
function weeks(isoMonth) {
  var first = parse(isoMonth + "-01")
  var lead = (first.getDay() + 6) % 7
  var days = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate()
  var cells = []
  for (var i = 0; i < lead; i++) cells.push("")
  for (var d = 1; d <= days; d++) cells.push(isoMonth + "-" + String(d).padStart(2, "0"))
  while (cells.length % 7 !== 0) cells.push("")
  var rows = []
  for (var r = 0; r < cells.length; r += 7) rows.push(cells.slice(r, r + 7))
  return rows
}

function clock(ms) {
  var seconds = Math.max(0, Math.floor(Number(ms || 0) / 1000))
  return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
}

// "14:02", "Yesterday 18:05", "Wed 16 Sep 09:12" for a timestamp in ms.
function stamp(ms, nowMs) {
  var date = new Date(Number(ms))
  var time = String(date.getHours()).padStart(2, "0") + ":" + String(date.getMinutes()).padStart(2, "0")
  return time
}

// History groups: "Today", "Yesterday", or the short date.
function group(ms, nowMs) {
  return short(iso(new Date(Number(ms))), iso(new Date(Number(nowMs))))
}

// When a to-do is due, said the short way: "Today", "Tomorrow", "Friday"
// within the week, "Yesterday", or "9 Oct".
function due(isoDate, todayIso) {
  var days = Math.round((parse(isoDate) - parse(todayIso)) / 86400000)
  if (days === 0) return "Today"
  if (days === 1) return "Tomorrow"
  if (days === -1) return "Yesterday"
  var date = parse(isoDate)
  if (days > 1 && days < 7) return WEEKDAYS[date.getDay()]
  var text = date.getDate() + " " + MONTHS[date.getMonth()].slice(0, 3)
  if (date.getFullYear() !== parse(todayIso).getFullYear()) text += " " + date.getFullYear()
  return text
}

function addDays(isoDate, days) {
  var date = parse(isoDate)
  date.setDate(date.getDate() + days)
  return iso(date)
}

// The dates to offer for a to-do: today, tomorrow, the rest of the week by
// name, and next Monday.
function dueChoices(todayIso) {
  var today = parse(todayIso)
  var choices = [{ label: "Today", value: todayIso }, { label: "Tomorrow", value: addDays(todayIso, 1) }]
  for (var d = 2; d < 7; d++) {
    var value = addDays(todayIso, d)
    var date = parse(value)
    choices.push({ label: WEEKDAYS[date.getDay()], detail: date.getDate() + " " + MONTHS[date.getMonth()].slice(0, 3), value: value })
  }
  var toMonday = (8 - today.getDay()) % 7 || 7
  if (toMonday >= 7) choices.push({ label: "Next week", detail: "Monday", value: addDays(todayIso, toMonday) })
  return choices
}

// "Today", or with a time, "Today 15:00" and "Friday 09:30".
function dueAt(isoDate, time, todayIso) {
  return due(isoDate, todayIso) + (time ? " " + time : "")
}

// A typed time as HH:MM: "15:00", "9", "9:30", "3pm", "3:30 pm". "" for none,
// null when it is not a time.
function clockTime(text) {
  var value = String(text || "").trim().toLowerCase().replace(/\./g, "").replace(/\s+/g, "")
  if (value.length === 0) return ""
  var match = value.match(/^(\d{1,2})(?::?(\d{2}))?(am|pm)?$/)
  if (!match) return null
  var hours = Number(match[1])
  var minutes = Number(match[2] || 0)
  if (match[3]) {
    if (hours < 1 || hours > 12) return null
    hours = hours % 12 + (match[3] === "pm" ? 12 : 0)
  }
  if (hours > 23 || minutes > 59) return null
  return String(hours).padStart(2, "0") + ":" + String(minutes).padStart(2, "0")
}
