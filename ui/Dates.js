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

// What "when" can be in one choice, at the moment NOW ("YYYY-MM-DD HH:MM"):
// the moments that remind you, then days alone, whose time is "". Later
// today is gone by 15:00 and becomes This evening until 18:00; Monday
// morning is left out when it is tomorrow morning or next week.
function moments(now, todayIso) {
  var clock = String(now).slice(11, 16)
  var tomorrow = addDays(todayIso, 1)
  var monday = addDays(todayIso, (8 - parse(todayIso).getDay()) % 7 || 7)
  var nextWeek = addDays(todayIso, 7)
  var out = []
  if (clock < "15:00") out.push({ key: "later", label: "Later today", date: todayIso, time: "18:00" })
  else if (clock < "18:00") out.push({ key: "evening", label: "This evening", date: todayIso, time: "20:00" })
  out.push({ key: "tomorrow-morning", label: "Tomorrow morning", date: tomorrow, time: "09:00" })
  if (monday !== tomorrow && monday !== nextWeek) out.push({ key: "monday", label: "Monday morning", date: monday, time: "09:00" })
  out.push({ key: "next-week", label: "Next week", date: nextWeek, time: "09:00" })
  out.push({ key: "today", label: "Today", date: todayIso, time: "" })
  out.push({ key: "tomorrow", label: "Tomorrow", date: tomorrow, time: "" })
  return out
}

// What a moment means, beside its name: "18:00", "Sat 09:00",
// "Fri 2 Oct, 09:00", or for a day alone, "Fri 25 Sep".
function momentAside(entry, todayIso) {
  var date = parse(entry.date)
  var day = WEEKDAYS[date.getDay()].slice(0, 3)
  var dated = day + " " + date.getDate() + " " + MONTHS[date.getMonth()].slice(0, 3)
  if (!entry.time) return dated
  var days = Math.round((date - parse(todayIso)) / 86400000)
  return days === 0 ? entry.time : days < 7 ? day + " " + entry.time : dated + ", " + entry.time
}

// The Monday on or before a day, and the fortnight from it.
function weekStart(isoDate) {
  return addDays(isoDate, -((parse(isoDate).getDay() + 6) % 7))
}
function fortnight(mondayIso) {
  var days = []
  for (var d = 0; d < 14; d++) days.push(addDays(mondayIso, d))
  return days
}
// "September 2026", or across two months, "Sep – Oct 2026".
function fortnightTitle(mondayIso) {
  var first = parse(mondayIso)
  var last = parse(addDays(mondayIso, 13))
  if (first.getMonth() === last.getMonth()) return MONTHS[first.getMonth()] + " " + first.getFullYear()
  return MONTHS[first.getMonth()].slice(0, 3) + (first.getFullYear() !== last.getFullYear() ? " " + first.getFullYear() : "")
    + " \u2013 " + MONTHS[last.getMonth()].slice(0, 3) + " " + last.getFullYear()
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

// A moment, "YYYY-MM-DD HH:MM", as a local Date, and back.
function moment(text) {
  var parts = String(text).split(" ")
  var date = parse(parts[0])
  var clock = String(parts[1] || "00:00").split(":")
  date.setHours(Number(clock[0]), Number(clock[1]))
  return date
}
function momentText(date) {
  return iso(date) + " " + String(date.getHours()).padStart(2, "0") + ":" + String(date.getMinutes()).padStart(2, "0")
}

// `minutes` after a moment, which can be negative: earlier.
function later(text, minutes) {
  var date = moment(text)
  date.setMinutes(date.getMinutes() + minutes)
  return momentText(date)
}

// Minutes from one moment to another.
function minutesBetween(from, to) {
  return Math.round((moment(to) - moment(from)) / 60000)
}

// When a reminder goes off, said next to the to-do's date: only the time on
// the same day, "Yesterday 18:00" or "Friday 09:30" on another.
function remindAt(text, isoDate, todayIso) {
  var parts = String(text).split(" ")
  return parts[0] === isoDate ? parts[1] : dueAt(parts[0], parts[1], todayIso)
}

// The same, as a sentence goes on: "at 16:30", "yesterday at 18:00",
// "Friday at 09:30".
function remindSaid(text, isoDate, todayIso) {
  var parts = String(text).split(" ")
  if (parts[0] === isoDate) return "at " + parts[1]
  var day = due(parts[0], todayIso)
  if (["Today", "Tomorrow", "Yesterday"].indexOf(day) >= 0) day = day.toLowerCase()
  return day + " at " + parts[1]
}

// When a reminder can go off for a to-do at AT: at its time, then 5, 15,
// 30 and 60 minutes earlier, each as the clock reads then.
var EARLIER = [0, 5, 15, 30, 60]
// Each with the clock time it means, and how far ahead as people say it:
// "5 min" reads at a glance where 12:17 next to 12:22 has to be worked out.
function remindChoices(at, isoDate) {
  return EARLIER.map(function(minutes) {
    var clock = clockOn(later(at, -minutes), isoDate)
    return { minutes: minutes, label: clock, ahead: ahead(minutes), before: minutes === 0 ? "On time" : ahead(minutes) + " before",
             means: minutes === 0 ? "On time, at " + clock : ahead(minutes) + " before, at " + clock,
             said: minutes === 0 ? "On time, at " + clock : spokenAhead(minutes) + " before, at " + clock }
  })
}
function ahead(minutes) {
  return minutes === 0 ? "On time" : minutes % 60 === 0 ? minutes / 60 + (minutes === 60 ? " hour" : " hours") : minutes + " min"
}
function spokenAhead(minutes) {
  return minutes % 60 === 0 ? minutes / 60 + (minutes === 60 ? " hour" : " hours") : minutes + " minutes"
}

// When a to-do reminds you, "YYYY-MM-DD HH:MM", with BEFORE minutes as the
// default; "" for one with no time or no reminder.
function reminderOf(todo, before) {
  if (!todo.due || !todo.time || todo.reminder === "off") return ""
  return todo.reminder ? String(todo.reminder) : later(todo.due + " " + todo.time, -before)
}

// A moment as a short choice next to a day: "16:45", or with the weekday
// when it falls on another day, "Thu 23:30".
function clockOn(text, isoDate) {
  var parts = String(text).split(" ")
  return parts[0] === isoDate ? parts[1] : WEEKDAYS[parse(parts[0]).getDay()].slice(0, 3) + " " + parts[1]
}
