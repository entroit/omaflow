.pragma library

// Desktop notifications are public. Only fixed messages belong in their
// process arguments or notification history; details stay in OmaFlow.
function command(event) {
  var messages = {
    configuration: ["-A", "default=Open settings", "--", "config.toml was not applied",
      "Open OmaFlow to check your settings. The previous settings stay in use."],
    journal: ["-A", "default=Open the journal", "--", "A journal note is ready",
      "Open OmaFlow to read your note."],
    reminder: ["-u", "critical", "-A", "default=Open", "-A", "done=Done", "--",
      "A to-do needs your attention", "Open OmaFlow to see your reminder."],
    reminderFailed: ["--", "A to-do is still open", "Open OmaFlow to try again."]
  }
  return ["notify-send", "-a", "OmaFlow"].concat(messages[event])
}
