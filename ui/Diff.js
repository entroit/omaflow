.pragma library
// Word-level differences between what was said and what was pasted, for the
// Changes view. Longest common subsequence over words; fine for dictation
// lengths, and capped so a very long take cannot stall the window.

function words(text) {
  return String(text || "").split(/\s+/).filter(function(word) { return word.length > 0 })
}

// [{ kind: "same"|"removed"|"added", text }]
function segments(before, after) {
  var a = words(before), b = words(after)
  if (a.length * b.length > 250000) return [{ kind: "added", text: b.join(" ") }]
  var n = a.length, m = b.length
  var table = []
  for (var i = 0; i <= n; i++) { table.push(new Array(m + 1).fill(0)) }
  for (i = n - 1; i >= 0; i--)
    for (var j = m - 1; j >= 0; j--)
      table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1])
  var out = []
  function push(kind, word) {
    var last = out[out.length - 1]
    if (last && last.kind === kind) last.text += " " + word
    else out.push({ kind: kind, text: word })
  }
  i = 0; j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) { push("same", b[j]); i++; j++ }
    else if (table[i + 1][j] >= table[i][j + 1]) { push("removed", a[i]); i++ }
    else { push("added", b[j]); j++ }
  }
  while (i < n) push("removed", a[i++])
  while (j < m) push("added", b[j++])
  return out
}

function escapeHtml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

function html(before, after, colors) {
  return segments(before, after).map(function(segment) {
    if (segment.kind === "same") return escapeHtml(segment.text)
    if (segment.kind === "removed") return "<s><font color=\"" + colors.removed + "\">" + escapeHtml(segment.text) + "</font></s>"
    return "<u><font color=\"" + colors.added + "\">" + escapeHtml(segment.text) + "</font></u>"
  }).join(" ")
}
