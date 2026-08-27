// Pure helpers for the Proton VPN panel.
//
// Everything here is side-effect free and Node-testable, matching the shape
// the first-party panels use (see panels/network/Model.js). The QML side does
// process handling and rendering; parsing and formatting live here so they can
// be exercised without a compositor.

// ---------------------------------------------------------------------------
// Probe output
// ---------------------------------------------------------------------------

// bin/protonvpn-probe emits "key\tvalue" lines, the same wire format
// `omarchy-network-status` uses.
function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var idx = line.indexOf("\t")
    if (idx === -1) continue
    next[line.substring(0, idx)] = line.substring(idx + 1).trim()
  }
  return next
}

// The four states the bar can be in, in order of how much they should worry
// you. "leaking" is the whole reason this widget reads the routing table
// instead of just asking whether an interface exists: a tunnel that is up but
// is not carrying the default route, or is not answering DNS, looks protected
// and is not. Painting that the same green as a healthy tunnel would be worse
// than showing nothing at all.
function connectionState(info) {
  var value = info || {}
  var state = String(value.state || "disconnected")

  if (state === "disconnected") {
    // A kill switch up with no tunnel behind it is not the same thing as being
    // disconnected, and calling both "Disconnected" hides the one state the
    // user actually has to act on. Traffic is contained, which is the kill
    // switch working -- but the network is gone, and so is the route to the
    // API needed to sign in and get it back. That is the deadlock, and it is
    // what greets you after a reboot with no readable session.
    return value.killswitch === "on" ? "blocked" : "off"
  }
  if (state === "connecting") return "connecting"
  if (value.routed === "0" || value.dns_ok === "0") return "leaking"
  return "protected"
}

// Which of the two integrity checks failed, so the banner can say *what* is
// leaking rather than just that something is.
function leakReason(info) {
  var value = info || {}
  var routed = value.routed !== "0"
  var dnsOk = value.dns_ok !== "0"

  if (!routed && !dnsOk) return "Traffic and DNS are bypassing the tunnel"
  if (!routed) return "Traffic is not routing through the tunnel"
  if (!dnsOk) return "DNS is resolving outside the tunnel"
  return ""
}

// Nerd Font shield glyphs. Filled when protected, outline while connecting,
// struck through when off, and the alert shield when the tunnel is lying.
function stateIcon(state) {
  if (state === "protected") return "󰦝"    // nf-md-shield_lock, filled
  if (state === "leaking") return "󰻌"      // nf-md-shield_alert, filled with "!"
  if (state === "connecting") return "󰒙"   // nf-md-shield_outline, hollow
  // Deliberately not a shield: nothing is being shielded, the door is just
  // bolted. A padlock reads that way at a glance and cannot be mistaken for
  // one of the four shield states at bar size.
  if (state === "blocked") return "󰌾"      // nf-md-lock
  return "󰦞"                               // nf-md-shield_off, struck through
}

function stateLabel(state) {
  if (state === "protected") return "Protected"
  if (state === "leaking") return "Not protected"
  if (state === "connecting") return "Connecting"
  if (state === "blocked") return "Network blocked"
  return "Disconnected"
}

// ---------------------------------------------------------------------------
// `protonvpn status`
// ---------------------------------------------------------------------------

// The CLI prints a human block, and prefixes it with progress chatter
// ("Server list is outdated, updating...") whenever its cache has aged out.
// Parse by label and ignore anything that isn't a line we asked for, so a new
// progress message upstream never breaks the panel.
//
//   Status: Connected
//   Server: US-WA#155 in Seattle, United States
//   Load: 41%
//   Protocol: wireguard
function parseStatus(raw) {
  var out = { connected: false, server: "", city: "", country: "", load: -1, protocol: "" }
  var lines = String(raw || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    var idx = line.indexOf(":")
    if (idx === -1) continue

    var key = line.substring(0, idx).trim().toLowerCase()
    var value = line.substring(idx + 1).trim()

    if (key === "status") out.connected = /connected/i.test(value) && !/disconnected/i.test(value)
    else if (key === "server") {
      var place = value.split(/\s+in\s+/)
      out.server = (place[0] || "").trim()
      if (place.length > 1) {
        // "Seattle, United States" -- a country with no city reads as just the
        // country, so only split when there is a comma to split on.
        var parts = place[1].split(",")
        if (parts.length > 1) {
          out.city = parts[0].trim()
          out.country = parts.slice(1).join(",").trim()
        } else {
          out.country = parts[0].trim()
        }
      }
    }
    else if (key === "load") {
      var load = parseInt(value.replace("%", ""), 10)
      out.load = isFinite(load) ? load : -1
    }
    else if (key === "protocol") out.protocol = value
  }

  return out
}

// Server load drives a colour band, the same way the network panel colours
// packet loss. Under half is unremarkable; a server past 90% is the reason
// your connection feels slow, and the panel should say so.
function loadSeverity(load) {
  var value = parseInt(load, 10)
  if (!isFinite(value) || value < 0) return "unknown"
  if (value >= 90) return "high"
  if (value >= 75) return "medium"
  return "low"
}

function formatLoad(load) {
  var value = parseInt(load, 10)
  if (!isFinite(value) || value < 0) return "--"
  return value + "%"
}

// Signed-out is not an error state to show in red -- it is a thing the user
// has to go do, and the panel offers the button for it. Detected from the
// CLI's own wording rather than an exit code, which it reuses for everything.
function needsSignIn(text) {
  var value = String(text || "")
  return /not\s+(signed|logged)\s+in/i.test(value)
    || /please\s+(sign|log)\s*in/i.test(value)
    || /\bsignin\b/i.test(value)
    || /session\s+expired/i.test(value)
    // What `connect` says, and the only one some dead sessions ever emit:
    // `status` can look perfectly healthy right up until a connect is refused.
    || /authentication\s+required/i.test(value)
}

// The CLI refuses to run at all while the Proton VPN desktop app is open. That
// takes out the whole slow tier and every action at once, so without detecting
// it the panel sits in a silent, permanent "loading" state and the buttons do
// nothing. The fast tier is unaffected, so the bar icon stays correct.
function guiConflict(text) {
  var value = String(text || "")
  return /desktop app is currently running/i.test(value)
    || /cannot run simultaneously/i.test(value)
}

// ---------------------------------------------------------------------------
// `protonvpn config list`
// ---------------------------------------------------------------------------

// A two-column table with a dashed rule under the header:
//
//   Setting                  Value
//   -----------------------  ------------
//   netshield                malware-only
//
// Keys are single tokens with no spaces, so the first run of whitespace is
// always the column break.
function parseConfig(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "" || line.charAt(0) === "-") continue

    var match = line.match(/^([a-z0-9-]+)\s{2,}(\S.*)$/i)
    if (!match) continue

    var key = match[1].toLowerCase()
    if (key === "setting") continue
    out[key] = match[2].trim()
  }

  return out
}

// The settings worth putting in a bar panel, in the order they matter.
//
// Deliberately not everything `protonvpn config set` accepts: custom-dns needs
// a list of addresses typed in and belongs in the CLI, and crash reporting is
// not a networking control. A panel that surfaces every flag a CLI has is a
// worse panel than one that picks.
function settingDefinitions() {
  return [
    {
      key: "kill-switch",
      label: "Kill switch",
      description: "Block traffic if the tunnel drops",
      values: ["off", "standard"],
      labels: ["Off", "On"],
      boolean: true,
      // The CLI refuses `config set kill-switch` while a tunnel is up, even
      // when the value would not change: "Disconnect before changing Kill
      // Switch." It is the only setting that does this -- netshield,
      // vpn-accelerator, port-forwarding, moderate-nat and ipv6 all apply
      // while connected. Offering a control that cannot succeed and then
      // printing the CLI's refusal in red is worse than not offering it, so
      // the row goes read-only while connected and says why.
      requiresDisconnect: true
    },
    {
      key: "netshield",
      label: "NetShield",
      description: "Block malware, ads and trackers",
      values: ["off", "malware-only", "malware-ads-trackers"],
      labels: ["Off", "Malware", "+ Ads"],
      boolean: false
    },
    {
      key: "vpn-accelerator",
      label: "VPN accelerator",
      description: "Proton's throughput optimisation",
      values: ["off", "on"],
      labels: ["Off", "On"],
      boolean: true
    },
    {
      key: "port-forwarding",
      label: "Port forwarding",
      description: "Request a forwarded port on P2P servers",
      values: ["off", "on"],
      labels: ["Off", "On"],
      boolean: true
    },
    {
      key: "moderate-nat",
      label: "Moderate NAT",
      description: "Looser NAT for gaming and P2P",
      values: ["off", "on"],
      labels: ["Off", "On"],
      boolean: true
    },
    {
      key: "ipv6",
      label: "IPv6",
      description: "Carry IPv6 inside the tunnel",
      values: ["off", "on"],
      labels: ["Off", "On"],
      boolean: true
    }
  ]
}

function settingDefinition(key) {
  var defs = settingDefinitions()
  for (var i = 0; i < defs.length; i++) {
    if (defs[i].key === key) return defs[i]
  }
  return null
}

function settingRows(config, connected) {
  var values = config || {}
  var defs = settingDefinitions()
  var rows = []

  for (var i = 0; i < defs.length; i++) {
    var def = defs[i]
    var current = String(values[def.key] || "")
    var index = def.values.indexOf(current)
    var locked = def.requiresDisconnect === true && connected === true
    rows.push({
      key: def.key,
      label: def.label,
      description: locked ? "Disconnect to change this" : def.description,
      locked: locked,
      boolean: def.boolean,
      values: def.values,
      labels: def.labels,
      value: current,
      index: index,
      // An unrecognised value means the CLI grew an option we don't model.
      // Show it rather than silently rendering the row as "off".
      known: index !== -1,
      checked: index > 0
    })
  }

  return rows
}

// Booleans flip; NetShield walks its three values and wraps. Callers pass the
// row so an unknown current value still has somewhere sensible to go (the
// first value), instead of getting stuck.
function nextSettingValue(row) {
  if (!row || !row.values || row.values.length === 0) return ""
  if (row.locked) return ""
  if (row.index === -1) return row.values[0]
  if (row.boolean) return row.index > 0 ? row.values[0] : row.values[row.values.length - 1]
  return row.values[(row.index + 1) % row.values.length]
}

function settingValueLabel(row) {
  if (!row) return ""
  if (row.index === -1) return row.value || "--"
  return row.labels[row.index] || row.value
}

// ---------------------------------------------------------------------------
// `protonvpn countries list` / `protonvpn cities list <CC>`
// ---------------------------------------------------------------------------

//   Country                           Code
//   --------------------------------  ------
//   Afghanistan                       AF
function parseCountries(raw) {
  var out = []
  var lines = String(raw || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "" || line.charAt(0) === "-") continue

    var match = line.match(/^(.+?)\s{2,}([A-Z]{2})$/)
    if (!match) continue
    if (match[1].trim().toLowerCase() === "country") continue

    out.push({ name: match[1].trim(), code: match[2] })
  }

  return out
}

//   City            Features
//   --------------  ----------
//   Atlanta         P2P, Tor
function parseCities(raw) {
  var out = []
  var lines = String(raw || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "" || line.charAt(0) === "-") continue
    if (/^cities in /i.test(line)) continue

    var match = line.match(/^(.+?)(?:\s{2,}(\S.*))?$/)
    if (!match) continue

    var name = match[1].trim()
    if (name.toLowerCase() === "city") continue

    var features = []
    if (match[2]) {
      var tokens = match[2].split(",")
      for (var t = 0; t < tokens.length; t++) {
        var token = tokens[t].trim()
        if (token !== "") features.push(token)
      }
    }

    out.push({ name: name, features: features })
  }

  return out
}

// Country rows for the list: the connected country first so the panel opens
// showing where you actually are, then everything else alphabetically. Matches
// how the Wi-Fi list pins the connected network to the top.
function countryRows(countries, connectedCountry, query) {
  var list = Array.isArray(countries) ? countries : []
  var needle = String(query || "").trim().toLowerCase()
  var current = String(connectedCountry || "").trim().toLowerCase()
  var rows = []

  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry) continue

    var name = String(entry.name || "")
    var code = String(entry.code || "")
    if (needle !== "" && (name + " " + code).toLowerCase().indexOf(needle) === -1) continue

    rows.push({
      name: name,
      code: code,
      connected: current !== "" && name.toLowerCase() === current
    })
  }

  rows.sort(function(a, b) {
    if (a.connected !== b.connected) return a.connected ? -1 : 1
    return a.name.localeCompare(b.name)
  })

  return rows
}

function countrySectionTitle(rows, index) {
  var list = Array.isArray(rows) ? rows : []
  if (index < 0 || index >= list.length) return ""

  var row = list[index]
  if (!row) return ""

  if (row.connected && index === 0) return "CONNECTED"
  if (!row.connected && (index === 0 || (list[index - 1] && list[index - 1].connected))) return "ALL COUNTRIES"
  return ""
}

// ---------------------------------------------------------------------------
// Quick connect
// ---------------------------------------------------------------------------

// Argument sets for `protonvpn connect`. Secure Core and Tor are plan-gated
// and simply fail with the CLI's own message when unavailable, which the
// panel surfaces verbatim rather than pretending to know the user's plan.
function quickConnectOptions() {
  return [
    { id: "fastest", label: "Fastest", args: [], hint: "Fastest server anywhere" },
    { id: "random", label: "Random", args: ["--random"], hint: "Random available server" },
    { id: "p2p", label: "P2P", args: ["--p2p"], hint: "Fastest P2P-optimised server" },
    { id: "securecore", label: "Secure", args: ["--securecore"], hint: "Secure Core routing" },
    { id: "tor", label: "Tor", args: ["--tor"], hint: "Tor over VPN" }
  ]
}

// ---------------------------------------------------------------------------
// Throughput
// ---------------------------------------------------------------------------

// Rates as deltas between successive probes. The previous sample is held with
// its timestamp so the first sample after a reconnect (or after the panel
// reopens) does not manufacture a spike out of a counter that reset.
function throughputState(previous, next, now) {
  var prev = previous || {}
  var sample = next || {}
  var iface = sample.iface || ""
  var rx = parseFloat(sample.rx_bytes || "0")
  var tx = parseFloat(sample.tx_bytes || "0")
  var previousTime = Number(prev.prevSampleTime || 0)

  if (iface !== (prev.prevIface || "") || previousTime === 0) {
    return { prevIface: iface, prevRxBytes: rx, prevTxBytes: tx, prevSampleTime: now, downloadRate: 0, uploadRate: 0 }
  }

  var downloadRate = Number(prev.downloadRate || 0)
  var uploadRate = Number(prev.uploadRate || 0)
  var dt = now - previousTime

  if (dt > 0) {
    downloadRate = Math.max(0, (rx - Number(prev.prevRxBytes || 0)) / dt)
    uploadRate = Math.max(0, (tx - Number(prev.prevTxBytes || 0)) / dt)
  }

  return { prevIface: iface, prevRxBytes: rx, prevTxBytes: tx, prevSampleTime: now, downloadRate: downloadRate, uploadRate: uploadRate }
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n < 1024) return Math.round(n) + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
  return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

// Keep the panel's own error line short enough not to reflow the popup.
function elide(text, limit) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  var max = parseInt(limit, 10) || 140
  return value.length > max ? value.substring(0, max - 1) + "…" : value
}

// The CLI is chatty on the way to an error. Take the last non-empty,
// non-progress line, which is where the actual failure is.
function failureMessage(stdout, stderr, fallback) {
  var text = String(stderr || "").trim() || String(stdout || "").trim()
  var lines = text.split("\n")

  for (var i = lines.length - 1; i >= 0; i--) {
    var line = lines[i].trim()
    if (line === "") continue
    if (/^server list is outdated/i.test(line)) continue
    if (/updating\.\.\./i.test(line)) continue
    return elide(line)
  }

  return String(fallback || "Proton VPN command failed")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseKeyValue: parseKeyValue,
    connectionState: connectionState,
    leakReason: leakReason,
    stateIcon: stateIcon,
    stateLabel: stateLabel,
    parseStatus: parseStatus,
    loadSeverity: loadSeverity,
    formatLoad: formatLoad,
    needsSignIn: needsSignIn,
    guiConflict: guiConflict,
    parseConfig: parseConfig,
    settingDefinitions: settingDefinitions,
    settingDefinition: settingDefinition,
    settingRows: settingRows,
    nextSettingValue: nextSettingValue,
    settingValueLabel: settingValueLabel,
    parseCountries: parseCountries,
    parseCities: parseCities,
    countryRows: countryRows,
    countrySectionTitle: countrySectionTitle,
    quickConnectOptions: quickConnectOptions,
    throughputState: throughputState,
    formatBytes: formatBytes,
    formatRate: formatRate,
    elide: elide,
    failureMessage: failureMessage
  }
}
