const fs = require('fs')
const M = require('../Model.js')
const D = __dirname + '/fixtures'
const read = f => fs.readFileSync(`${D}/${f}`, 'utf8')

let fail = 0
const eq = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g !== w) { console.log(`FAIL ${label}\n  got  ${g}\n  want ${w}`); fail++ }
  else console.log(`ok   ${label} = ${g}`)
}

// --- probe ---
const info = M.parseKeyValue(read('probe.txt'))
eq('probe.state', info.state, 'connected')
eq('probe.server', info.server, 'US-WA#155')
eq('probe.routed', info.routed, '1')
eq('connectionState(live)', M.connectionState(info), 'protected')
eq('leakReason(live)', M.leakReason(info), '')

// synthetic leak cases
eq('state(no route)', M.connectionState({state:'connected', routed:'0', dns_ok:'1'}), 'leaking')
eq('reason(no route)', M.leakReason({state:'connected', routed:'0', dns_ok:'1'}), 'Traffic is not routing through the tunnel')
eq('state(no dns)', M.connectionState({state:'connected', routed:'1', dns_ok:'0'}), 'leaking')
eq('reason(no dns)', M.leakReason({state:'connected', routed:'1', dns_ok:'0'}), 'DNS is resolving outside the tunnel')
eq('reason(both)', M.leakReason({state:'connected', routed:'0', dns_ok:'0'}), 'Traffic and DNS are bypassing the tunnel')
eq('state(off)', M.connectionState({state:'disconnected'}), 'off')
eq('state(connecting)', M.connectionState({state:'connecting'}), 'connecting')
eq('state(empty)', M.connectionState({}), 'off')

// --- status ---
const st = M.parseStatus(read('status.txt'))
eq('status.connected', st.connected, true)
eq('status.server', st.server, 'US-WA#155')
eq('status.city', st.city, 'Seattle')
eq('status.country', st.country, 'United States')
eq('status.protocol', st.protocol, 'wireguard')
eq('status.load>=0', st.load >= 0, true)
eq('loadSeverity(41)', M.loadSeverity(41), 'low')
eq('loadSeverity(80)', M.loadSeverity(80), 'medium')
eq('loadSeverity(95)', M.loadSeverity(95), 'high')
eq('loadSeverity(-1)', M.loadSeverity(-1), 'unknown')
eq('formatLoad(-1)', M.formatLoad(-1), '--')

// disconnected form + country with no city
eq('status disconnected', M.parseStatus('Status: Disconnected').connected, false)
const noCity = M.parseStatus('Server: CH#1 in Switzerland')
eq('status no-city.country', noCity.country, 'Switzerland')
eq('status no-city.city', noCity.city, '')

// --- config ---
const cfg = M.parseConfig(read('config.txt'))
eq('config.netshield', cfg.netshield, 'malware-only')
eq('config.kill-switch', cfg['kill-switch'], 'off')
eq('config.ipv6', cfg.ipv6, 'on')
eq('config has no header row', cfg.setting, undefined)
const rows = M.settingRows(cfg)
eq('rows count', rows.length, 6)
const ks = rows.find(r => r.key === 'kill-switch')
eq('kill-switch checked', ks.checked, false)
eq('kill-switch next', M.nextSettingValue(ks), 'standard')
const ns = rows.find(r => r.key === 'netshield')
eq('netshield label', M.settingValueLabel(ns), 'Malware')
eq('netshield next', M.nextSettingValue(ns), 'malware-ads-trackers')
eq('netshield wraps', M.nextSettingValue({...ns, index: 2, boolean: false, values: ns.values}), 'off')
eq('unknown value known=false', M.settingRows({ipv6: 'weird'}).find(r=>r.key==='ipv6').known, false)
eq('unknown value next', M.nextSettingValue(M.settingRows({ipv6:'weird'}).find(r=>r.key==='ipv6')), 'off')

// --- countries ---
const cs = M.parseCountries(read('countries.txt'))
eq('countries count > 100', cs.length > 100, true)
eq('countries[0]', cs[0], {name:'Afghanistan', code:'AF'})
eq('no header row', cs.some(c => c.name === 'Country'), false)
eq('multi-word name', cs.some(c => c.name === 'Bosnia and Herzegovina' && c.code === 'BA'), true)
const crows = M.countryRows(cs, 'United States', '')
eq('connected pinned first', crows[0].name, 'United States')
eq('connected flag', crows[0].connected, true)
eq('section title 0', M.countrySectionTitle(crows, 0), 'CONNECTED')
eq('section title 1', M.countrySectionTitle(crows, 1), 'ALL COUNTRIES')
eq('filter', M.countryRows(cs, '', 'switz').map(r=>r.name), ['Switzerland'])
eq('filter by code', M.countryRows(cs, '', 'jp').map(r=>r.code), ['JP'])

// --- cities ---
const ci = M.parseCities(read('cities.txt'))
eq('cities count > 5', ci.length > 5, true)
eq('no City header', ci.some(c => c.name === 'City'), false)
eq('no "Cities in" line', ci.some(c => /^Cities in/i.test(c.name)), false)
eq('Atlanta features', ci.find(c=>c.name==='Atlanta').features, ['P2P','Tor'])
eq('Ashburn features', ci.find(c=>c.name==='Ashburn').features, ['P2P'])

// --- throughput ---
const t0 = M.throughputState({}, {iface:'proton0', rx_bytes:'1000', tx_bytes:'500'}, 100)
eq('first sample no spike', [t0.downloadRate, t0.uploadRate], [0,0])
const t1 = M.throughputState(t0, {iface:'proton0', rx_bytes:'3000', tx_bytes:'1500'}, 102)
eq('rate over 2s', [t1.downloadRate, t1.uploadRate], [1000, 500])
const t2 = M.throughputState(t1, {iface:'proton1', rx_bytes:'10', tx_bytes:'10'}, 104)
eq('iface change resets', [t2.downloadRate, t2.uploadRate], [0,0])
const t3 = M.throughputState(t1, {iface:'proton0', rx_bytes:'0', tx_bytes:'0'}, 104)
eq('counter reset clamps to 0', [t3.downloadRate, t3.uploadRate], [0,0])
eq('formatBytes', [M.formatBytes(999), M.formatBytes(2048), M.formatBytes(5*1024*1024)], ['999 B','2.0 KB','5.0 MB'])

// --- errors ---
eq('failureMessage skips chatter', M.failureMessage('Server list is outdated, updating...\nCould not reach server', '', 'x'), 'Could not reach server')
eq('failureMessage prefers stderr', M.failureMessage('out', 'the real error', 'x'), 'the real error')
eq('failureMessage fallback', M.failureMessage('', '', 'nothing happened'), 'nothing happened')
eq('needsSignIn', M.needsSignIn('You are not logged in. Run protonvpn signin'), true)
eq('needsSignIn false', M.needsSignIn('Could not reach server'), false)
eq('elide', M.elide('a'.repeat(200)).length, 140)

// --- GUI conflict ---
const guiErr = "Error: Proton VPN desktop app is currently running\nThe CLI and GUI cannot run simultaneously. Please close the GUI application and try again."
eq('guiConflict detected', M.guiConflict(guiErr), true)
eq('guiConflict on second line alone', M.guiConflict('The CLI and GUI cannot run simultaneously.'), true)
eq('guiConflict false on normal status', M.guiConflict(read('status.txt')), false)
eq('guiConflict false on empty', M.guiConflict(''), false)
eq('guiConflict not confused with signin', M.guiConflict('You are not logged in'), false)
eq('signin not confused with gui', M.needsSignIn(guiErr), false)

// --- icons ---
eq('icons distinct', new Set(['protected','leaking','connecting','off'].map(M.stateIcon)).size, 4)

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`)
process.exit(fail === 0 ? 0 : 1)
