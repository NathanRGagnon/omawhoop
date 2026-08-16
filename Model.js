function parseStatus(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    return (data && typeof data === "object") ? data : null
  } catch (e) {
    return null
  }
}

function isAuthError(status) {
  return !!(status && status.error === "not_authenticated")
}

function formatStrain(value) {
  if (value === undefined || value === null) return "—"
  var n = parseFloat(value)
  return isNaN(n) ? "—" : n.toFixed(1)
}

function formatPercent(value) {
  if (value === undefined || value === null) return "—"
  var n = parseFloat(value)
  return isNaN(n) ? "—" : Math.round(n) + "%"
}

function formatHrv(value) {
  if (value === undefined || value === null) return "—"
  var n = parseFloat(value)
  return isNaN(n) ? "—" : Math.round(n) + " ms"
}

function formatBpm(value) {
  if (value === undefined || value === null) return "—"
  var n = parseFloat(value)
  return isNaN(n) ? "—" : Math.round(n) + " bpm"
}

function formatRespiratoryRate(value) {
  if (value === undefined || value === null) return "—"
  var n = parseFloat(value)
  return isNaN(n) ? "—" : n.toFixed(1) + " br/min"
}

// WHOOP reports energy expenditure in kilojoules; the app itself shows kcal.
function formatCalories(kilojoules) {
  if (kilojoules === undefined || kilojoules === null) return "—"
  var n = parseFloat(kilojoules)
  return isNaN(n) ? "—" : Math.round(n * 0.239006) + " cal"
}

function formatTemperature(celsius) {
  if (celsius === undefined || celsius === null) return "—"
  var n = parseFloat(celsius)
  return isNaN(n) ? "—" : n.toFixed(1) + "°C"
}

function formatDuration(ms) {
  if (ms === undefined || ms === null) return "—"
  var n = parseFloat(ms)
  if (isNaN(n) || n <= 0) return "—"
  var totalMinutes = Math.round(n / 60000)
  var hours = Math.floor(totalMinutes / 60)
  var minutes = totalMinutes % 60
  return hours + "h " + minutes + "m"
}

// PENDING_SCORE / UNSCORABLE explain why a value reads "—"; SCORED needs no label.
function scoreStateLabel(state) {
  if (state === "PENDING_SCORE") return "Scoring…"
  if (state === "UNSCORABLE") return "Not enough data"
  return ""
}

// WHOOP's own recovery banding, per the Brand & Design Guidelines color
// palette: High 100-67% #16EC06, Medium 66-34% #FFDE00, Low 33-0% #FF0026.
function recoveryColor(value, fallback) {
  if (value === undefined || value === null) return fallback
  var n = parseFloat(value)
  if (isNaN(n)) return fallback
  if (n >= 67) return "#16EC06"
  if (n >= 34) return "#FFDE00"
  return "#FF0026"
}

// WCAG relative luminance — same formula qs's agents/Panel.qml uses to pick
// a light- or dark-surface icon variant per background.
function colorChannelLuminance(value) {
  var channel = Number(value)
  if (!isFinite(channel)) return 0
  return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
}

function colorLuminance(color) {
  return 0.2126 * colorChannelLuminance(color.r)
    + 0.7152 * colorChannelLuminance(color.g)
    + 0.0722 * colorChannelLuminance(color.b)
}

// The WHOOP brand guidelines require the logo to stay pure black or pure
// white — never recolored to an arbitrary theme color — so this picks
// between those two rather than tinting to root.barForeground.
function brandMarkColor(surfaceColor) {
  return colorLuminance(surfaceColor) >= 0.5 ? "#000000" : "#ffffff"
}

function parseHistory(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    return (data && typeof data === "object" && Array.isArray(data.days)) ? data : null
  } catch (e) {
    return null
  }
}

// Maps a values array (same length as the day list, index-aligned) onto an
// evenly-spaced x axis and a [minValue, maxValue] -> [height, 0] y axis
// (pixel y grows downward, so higher values sit nearer the top). A null in
// `values` produces a null y, marking a gap the line shouldn't bridge.
function chartPoints(values, minValue, maxValue, width, height) {
  var n = values.length
  if (n === 0) return []
  var range = maxValue - minValue
  var points = []
  for (var i = 0; i < n; i++) {
    var x = n === 1 ? width / 2 : (i / (n - 1)) * width
    var raw = values[i]
    var n2 = (raw === null || raw === undefined) ? NaN : parseFloat(raw)
    var y = null
    if (!isNaN(n2)) {
      var frac = range > 0 ? (n2 - minValue) / range : 0
      frac = Math.max(0, Math.min(1, frac))
      y = height - frac * height
    }
    points.push({ x: x, y: y })
  }
  return points
}

// Splits a chartPoints() array into runs of consecutive non-null points, so
// a missing day breaks the line instead of being interpolated across.
function chartSegments(points) {
  var segments = []
  var current = []
  for (var i = 0; i < points.length; i++) {
    if (points[i].y === null) {
      if (current.length > 0) { segments.push(current); current = [] }
    } else {
      current.push(points[i])
    }
  }
  if (current.length > 0) segments.push(current)
  return segments
}

// CLI error text can be a raw API response — long unbroken tokens/URLs in it
// would blow past Text.Wrap's line width, so cap length as well as wrapping.
function truncateMessage(text, maxLen) {
  var s = String(text || "")
  return s.length > maxLen ? s.slice(0, maxLen - 1) + "…" : s
}

function relativeUpdated(fetchedAtSeconds, nowSeconds) {
  if (!fetchedAtSeconds) return ""
  var deltaMin = Math.max(0, Math.round((nowSeconds - fetchedAtSeconds) / 60))
  if (deltaMin < 1) return "just now"
  if (deltaMin === 1) return "1 min ago"
  if (deltaMin < 60) return deltaMin + " min ago"
  var deltaHr = Math.round(deltaMin / 60)
  return deltaHr === 1 ? "1 hr ago" : deltaHr + " hr ago"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
    isAuthError: isAuthError,
    formatStrain: formatStrain,
    formatPercent: formatPercent,
    formatHrv: formatHrv,
    formatBpm: formatBpm,
    formatRespiratoryRate: formatRespiratoryRate,
    formatDuration: formatDuration,
    formatCalories: formatCalories,
    formatTemperature: formatTemperature,
    scoreStateLabel: scoreStateLabel,
    recoveryColor: recoveryColor,
    colorLuminance: colorLuminance,
    brandMarkColor: brandMarkColor,
    parseHistory: parseHistory,
    chartPoints: chartPoints,
    chartSegments: chartSegments,
    truncateMessage: truncateMessage,
    relativeUpdated: relativeUpdated
  }
}
