.pragma library
// The bar draws its widgets once per monitor, so the shell holds one copy of
// OmaFlow.qml for each. Every copy shows its own bar icon, but the work that
// must happen once (reminders, notes, the card, the window, commands from
// keybindings) is done by the first copy still standing. This file is shared
// by every copy, which is how they know about each other.

var copies = []

function join(copy) {
  copies.push(copy)
  elect()
}

// Only forgets it: the shell may be tearing every copy down, and touching
// one that is half gone crashes it. The others look again each second.
function leave(copy) {
  copies = copies.filter(function(other) { return other !== copy })
}

function elect() {
  for (var i = 0; i < copies.length; i++) copies[i].leader = i === 0
}

function leader() {
  return copies.length > 0 ? copies[0] : null
}
