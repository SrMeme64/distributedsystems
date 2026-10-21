let TOOLS = {}, current = null, openRun = null, poll = null;
const $ = (s) => document.querySelector(s);
const el = (html) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstChild; };
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const fmt = (ts) => new Date(ts * 1000).toLocaleString();

async function init() {
  TOOLS = await (await fetch('/api/tools')).json();
  current = Object.keys(TOOLS)[0];
  renderTabs(); renderTool(); refreshHistory();
  setInterval(refreshHistory, 4000);
}

function renderTabs() {
  const nav = $('#tabs'); nav.innerHTML = '';
  for (const [key, t] of Object.entries(TOOLS)) {
    const b = el(`<button class="${key === current ? 'active' : ''}">${esc(t.title)}</button>`);
    b.onclick = () => { current = key; renderTabs(); renderTool(); };
    nav.append(b);
  }
}

function renderTool() {
  const t = TOOLS[current];
  const fields = t.fields.map((f) => {
    const id = `f-${f.key}`;
    if (f.type === 'bool') return `<div class="check"><input type="checkbox" id="${id}" ${f.default ? 'checked' : ''}><label for="${id}">${esc(f.label)}</label></div>`;
    if (f.type === 'select') return `<div><label>${esc(f.label)}</label><select id="${id}">${f.options.map((o) => `<option ${o === f.default ? 'selected' : ''}>${esc(o)}</option>`).join('')}</select></div>`;
    if (f.type === 'textarea') return `<div class="wide"><label>${esc(f.label)}</label><textarea id="${id}">${esc(f.default)}</textarea></div>`;
    return `<div><label>${esc(f.label)}</label><input id="${id}" type="${f.type}" value="${esc(f.default)}" ${f.min !== undefined ? `min="${f.min}" max="${f.max}"` : ''}></div>`;
  }).join('');
  const presets = Object.keys(t.presets).map((p) => `<button class="ghost" data-preset="${esc(p)}">${esc(p)}</button>`).join('');
  $('#tool').innerHTML = `<h2>${esc(t.title)}</h2><p>${esc(t.description)}</p>
    <div class="grid">${fields}</div>
    <div class="actions"><button class="primary" id="launch">Launch test</button><span>Presets:</span>${presets}<span id="msg" class="err"></span></div>
    <details><summary>Runbook</summary><ol>${t.runbook.map((s) => `<li>${esc(s)}</li>`).join('')}</ol></details>`;
  $('#launch').onclick = launch;
  document.querySelectorAll('[data-preset]').forEach((b) => b.onclick = () => {
    for (const [k, v] of Object.entries(t.presets[b.dataset.preset])) { const i = $(`#f-${k}`); if (i) i.value = v; }
  });
}

function collect() {
  const params = {};
  for (const f of TOOLS[current].fields) {
    const i = $(`#f-${f.key}`);
    params[f.key] = f.type === 'bool' ? i.checked : i.value;
  }
  return params;
}

async function launch() {
  $('#msg').textContent = '';
  const r = await fetch('/api/runs', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ tool: current, params: collect() }) });
  const data = await r.json();
  if (!r.ok) { $('#msg').textContent = data.error; return; }
  showRun(data.id);
  refreshHistory();
}

function showRun(id) {
  openRun = id; clearInterval(poll);
  const load = async () => {
    const r = await fetch(`/api/runs/${id}`); if (!r.ok) return;
    const run = await r.json(); renderRun(run);
    if (!['running', 'stopping'].includes(run.status)) clearInterval(poll);
  };
  load(); poll = setInterval(load, 2000);
}

function bars(p, unit) {
  const max = Math.max(...Object.values(p), 1);
  return Object.entries(p).map(([k, v]) => `<div class="bar"><span>${esc(k)}</span><i style="width:${Math.max(2, 70 * v / max)}%"></i><em>${v} ${unit || ''}</em></div>`).join('');
}

function renderRun(run) {
  const s = run.summary || {}, panel = $('#result'); panel.hidden = false;
  const active = ['running', 'stopping'].includes(run.status);
  let html = `<h2>${esc(TOOLS[run.tool].title)} <span class="badge ${run.status}">${run.status}</span> <small>${esc(run.id)}</small></h2>`;
  html += `<div class="actions">${active ? '<button class="danger" id="stop">Stop</button>' : ''}</div>`;
  if (s.error) html += `<p class="err">${esc(s.error)}</p>`;
  const m = Object.entries(s.metrics || {});
  if (m.length) html += `<h3>Output data</h3><div class="cards">${m.map(([k, v]) => `<div class="card"><b>${esc(v ?? 'n/a')}</b><span>${esc(k)}</span></div>`).join('')}</div>`;
  if (s.percentiles && Object.keys(s.percentiles).length) html += `<h3>Latency percentiles</h3>${bars(s.percentiles, s.unit)}`;
  if (s.table) html += `<h3>Per request</h3><table><tr><th>Request</th><th>Samples</th><th>Errors</th><th>Avg ms</th></tr>${s.table.map((r) => `<tr><td>${esc(r.label)}</td><td>${r.samples}</td><td>${r.errors}</td><td>${r.avg_ms}</td></tr>`).join('')}</table>`;
  if (s.timeline && s.timeline.length) {
    const max = Math.max(...s.timeline.map((p) => p.ms), 1);
    html += `<h3>Availability probes (red = failed)</h3><div class="timeline">${s.timeline.map((p) => `<div class="${p.ok ? '' : 'bad'}" style="height:${Math.max(8, 100 * p.ms / max)}%" title="${p.t}s ${p.ms}ms"></div>`).join('')}</div>`;
  }
  if (s.events && s.events.length) html += `<h3>Chaos events</h3><table><tr><th>t (s)</th><th>Action</th><th>Service</th><th></th></tr>${s.events.map((e) => `<tr><td>${e.t}</td><td>${esc(e.action)}</td><td>${esc(e.service)}</td><td class="${e.ok ? '' : 'err'}">${esc(e.detail)}</td></tr>`).join('')}</table>`;
  html += `<h3>Input parameters</h3><pre>${esc(JSON.stringify(run.params, null, 2))}</pre>`;
  html += `<h3>Console</h3><pre id="console">${esc(run.console)}</pre>`;
  const links = (run.files || []).map((f) => `<a class="btn" href="/files/${run.id}/${f}?download=1">${esc(f)}</a>`);
  if (s.report) links.unshift(`<a class="btn" target="_blank" href="/files/${run.id}/report/index.html">Open JMeter HTML report</a>`);
  html += `<div class="links">${links.join('')}</div>`;
  panel.innerHTML = html;
  const c = $('#console'); c.scrollTop = c.scrollHeight;
  const stop = $('#stop'); if (stop) stop.onclick = async () => { await fetch(`/api/runs/${run.id}/stop`, { method: 'POST' }); };
}

function keyResult(r) {
  const m = (r.summary || {}).metrics || {};
  const pick = { ab: ['Requests/s', 'Failed requests'], siege: ['Availability %', 'Transactions/s'], jmeter: ['Throughput req/s', 'Error %'], chaosmonkey: ['Availability %', 'Faults injected'] }[r.tool];
  return pick.filter((k) => m[k] !== undefined).map((k) => `${k}: ${m[k]}`).join(' · ');
}

async function refreshHistory() {
  const runs = await (await fetch('/api/runs')).json();
  $('#history tbody').innerHTML = runs.map((r) => `<tr><td>${fmt(r.started)}</td><td>${esc(TOOLS[r.tool]?.title || r.tool)}</td><td><span class="badge ${r.status}">${r.status}</span></td><td>${esc(keyResult(r))}</td><td><button class="ghost" data-run="${r.id}">View</button></td></tr>`).join('');
  document.querySelectorAll('[data-run]').forEach((b) => b.onclick = () => showRun(b.dataset.run));
}

init();
