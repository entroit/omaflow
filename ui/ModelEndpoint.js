.pragma library

// The address rules used by omaflow-core's config::model_endpoint, before Save or Test.
function ipv4(host) {
  var parts = host.split(".")
  return parts.length === 4 && parts.every(function(part) {
    return /^(0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255
  }) ? parts.map(Number) : null
}

function ipv6(host) {
  if (host.indexOf(".") >= 0) {
    var at = host.lastIndexOf(":")
    var tail = ipv4(host.slice(at + 1))
    if (at < 0 || !tail) return null
    host = host.slice(0, at + 1) + (tail[0] * 256 + tail[1]).toString(16) + ":" + (tail[2] * 256 + tail[3]).toString(16)
  }
  var halves = host.split("::")
  if (halves.length > 2) return null
  var left = halves[0] ? halves[0].split(":") : []
  var right = halves.length === 2 && halves[1] ? halves[1].split(":") : []
  var words = left.concat(right)
  if (!words.every(function(word) { return /^[0-9a-f]{1,4}$/i.test(word) })
      || (halves.length === 1 ? words.length !== 8 : words.length >= 8)) return null
  return left.concat(new Array(8 - words.length).fill("0"), right).map(function(word) { return parseInt(word, 16) })
}

function problem(value) {
  var url = String(value).trim()
  if (url.length === 0) return "An address is required."
  try {
    if (encodeURIComponent(url).replace(/%[0-9A-F]{2}/g, ".").length > 2048) return "At most 2048 bytes."
  } catch (error) { return "The address contains invalid text." }
  if (/[\s\u0000-\u001f\u007f-\u009f]/.test(url)) return "Remove spaces and control characters from the address."
  if (/[\\?#]/.test(url)) return "Remove backslashes, queries and fragments. Put credentials in the API key field."
  var match = /^(https?):\/\/([^/]*)(?:\/|$)/.exec(url)
  if (!match) return "Start with http:// or https://."
  var authority = match[2], host = authority, port = "", words = null
  if (!authority || /[@%{}]/.test(authority)) return "Enter a host without credentials or encoded characters. Put credentials in the API key field."
  if (authority[0] === "[") {
    var bracketed = /^\[([^\]]+)\](?::([^:]*))?$/.exec(authority)
    if (!bracketed || !(words = ipv6(bracketed[1]))) return "Enter a valid IPv6 address in brackets."
    host = bracketed[1]
    port = bracketed[2] || ""
  } else {
    var separator = authority.lastIndexOf(":")
    if (separator >= 0) { host = authority.slice(0, separator); port = authority.slice(separator + 1) }
    if (host.indexOf(":") >= 0) return "Put IPv6 addresses in brackets."
  }
  if (!host || /[\[\]]/.test(host)) return "Enter a valid host."
  if (port !== "" && (!/^\+?[0-9]+$/.test(port) || Number(port) < 1 || Number(port) > 65535))
    return "The port must be between 1 and 65535."
  var v4 = ipv4(host)
  var loopback = host === "localhost" || v4 !== null && v4[0] === 127
    || words !== null && words.slice(0, 7).every(function(word) { return word === 0 }) && words[7] === 1
  if (match[1] === "http" && !loopback) return "Use HTTPS for another machine. HTTP is only allowed for localhost or a loopback IP address."
  return ""
}
