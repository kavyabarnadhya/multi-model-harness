#!/usr/bin/env node
// helper-usage.js: usage ledger and report for Claude Code, ask-grok and ask-gemini.
//   node helper-usage.js record <run-dir> <helper> <task> <model> <exit-code>   (called by the wrappers)
//   node helper-usage.js stats [--days N] [--brief] [--json]                      (run via helper-stats)
// Helper runs are read from the wrappers' run folders into a ledger (usage.jsonl), because only the last
// 30 run folders are kept. Claude Code usage is read from its local transcripts (~/.claude/projects).
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');

const STATE_DIR = process.env.HELPER_STATE_DIR || path.join(os.homedir(), '.cache', 'ask-helpers');
const LEDGER = path.join(STATE_DIR, 'usage.jsonl');
const RUNS = path.join(STATE_DIR, 'runs');
const CLAUDE_PROJECTS = path.join(os.homedir(), '.claude', 'projects');

// --- one helper run -> one ledger entry ---

function readLines(file) {
  try { return fs.readFileSync(file, 'utf8').split('\n'); } catch { return []; }
}

// Token totals from a run's raw stream: grok emits one "usage" event per turn, agy one "result" per turn.
function runTokens(dir) {
  const t = { input: 0, output: 0, reasoning: 0, cached: 0 };
  for (const line of readLines(path.join(dir, 'out'))) {
    if (!line.includes('usage')) continue;
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.type === 'usage' && e.usage) {
      t.input += e.usage.input_tokens || 0;
      t.output += e.usage.output_tokens || 0;
      t.reasoning += e.usage.reasoning_tokens || 0;
      t.cached += e.usage.cache_read_input_tokens || 0;
    } else if (e.event === 'result' && e.result && e.result.usage) {
      const u = e.result.usage;
      t.input += u.input_tokens || 0;
      t.output += u.output_tokens || 0;
      t.reasoning += u.thinking_tokens || 0;
      t.cached += u.cache_read_tokens || 0;
    }
  }
  return t;
}

// Run folder names look like 20261110-181117-grok-review-13719 or 20261109-205445-grok-code-crop-a11y-5274.
function parseRunName(name) {
  const m = /^(\d{8})-(\d{6})-(grok|gemini)-(review|read|code)-/.exec(name);
  if (!m) return null;
  const [d, t] = [m[1], m[2]];
  const ts = `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}T${t.slice(0, 2)}:${t.slice(2, 4)}:${t.slice(4, 6)}`;
  return { ts: new Date(ts).toISOString(), helper: m[3], task: m[4] };
}

function runEntry(dir, fields) {
  const run = path.basename(dir);
  const notes = readLines(path.join(dir, 'run.txt')).join('\n');
  const secs = Number((/after (\d+)s/.exec(notes) || [])[1] || 0);
  let ok = fields.exit != null ? fields.exit === 0 : /result: ok|result: status=SUCCESS(?! finished=print_timeout)/.test(notes);
  const reason = /stuck:/.test(notes) ? 'stuck' : /\(timeout\)|finished=print_timeout/.test(notes) ? 'timeout' : '';
  return { run, ...parseRunName(run), ...fields, ok, reason, secs, ...runTokens(dir) };
}

function ledgerRuns() {
  const seen = new Set();
  for (const line of readLines(LEDGER)) {
    try { seen.add(JSON.parse(line).run); } catch {}
  }
  return seen;
}

function append(entry) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.appendFileSync(LEDGER, JSON.stringify(entry) + '\n');
}

function record([dir, helper, task, model, exitCode, failReason]) {
  const seen = ledgerRuns();
  if (!dir || seen.has(path.basename(dir))) return;
  const entry = runEntry(dir, { helper, task, model, exit: Number(exitCode) });
  // The wrapper knows why it failed (quota, timeout, stuck, model-unavailable, ...); prefer that.
  if (!entry.ok && failReason) entry.reason = failReason;
  append(entry);
}

// Pick up run folders the ledger doesn't have yet (older runs, or runs from before the ledger existed).
function backfill() {
  const seen = ledgerRuns();
  let names = [];
  try { names = fs.readdirSync(RUNS); } catch {}
  for (const name of names.sort()) {
    if (seen.has(name) || !parseRunName(name)) continue;
    append(runEntry(path.join(RUNS, name), { model: '', exit: null }));
  }
}

// --- Claude Code transcripts ---

function* walk(dir) {
  let items = [];
  try { items = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const it of items) {
    const p = path.join(dir, it.name);
    if (it.isDirectory()) yield* walk(p);
    else if (it.name.endsWith('.jsonl')) yield p;
  }
}

async function claudeUsage(since) {
  const t = { messages: 0, input: 0, cacheWrite: 0, cacheRead: 0, output: 0, models: {} };
  const seen = new Set(); // streamed messages repeat; count each message id once
  for (const file of walk(CLAUDE_PROJECTS)) {
    if (fs.statSync(file).mtime < since) continue;
    const rl = readline.createInterface({ input: fs.createReadStream(file, 'utf8'), crlfDelay: Infinity });
    for await (const line of rl) {
      if (!line.includes('"usage"') || !line.includes('"assistant"')) continue;
      let e; try { e = JSON.parse(line); } catch { continue; }
      const m = e.message;
      if (!m || !m.usage || !e.timestamp || new Date(e.timestamp) < since) continue;
      const key = m.id || e.requestId || e.uuid;
      if (seen.has(key)) continue;
      seen.add(key);
      const u = m.usage;
      t.messages++;
      t.input += u.input_tokens || 0;
      t.cacheWrite += u.cache_creation_input_tokens || 0;
      t.cacheRead += u.cache_read_input_tokens || 0;
      t.output += u.output_tokens || 0;
      const model = m.model || 'unknown';
      if (model !== '<synthetic>') t.models[model] = (t.models[model] || 0) + (u.output_tokens || 0);
    }
  }
  return t;
}

// --- report ---

function helperStatus() {
  const status = { grok: 'available', gemini: 'available' };
  const now = Date.now() / 1000;
  for (const line of readLines(path.join(STATE_DIR, 'state'))) {
    const [helper, until, reason] = line.trim().split(/\s+/);
    if (status[helper] && Number(until) > now) {
      const at = new Date(Number(until) * 1000);
      status[helper] = reason === 'auth'
        ? 'out (auth: sign in, then --reset)'
        : `out (${reason} until ${at.toTimeString().slice(0, 5)})`;
    }
  }
  return status;
}

const k = (n) => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? Math.round(n / 1e3) + 'K' : String(n);

async function stats(args) {
  const days = Number((args[args.indexOf('--days') + 1]) || 0) || 7;
  const brief = args.includes('--brief');
  const since = new Date(Date.now() - days * 86400e3);
  backfill();

  const helpers = {};
  for (const line of readLines(LEDGER)) {
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (!e.ts || new Date(e.ts) < since) continue;
    const h = helpers[e.helper] || (helpers[e.helper] = { runs: 0, ok: 0, secs: 0, input: 0, output: 0, tasks: {}, fails: {} });
    h.runs++; h.secs += e.secs || 0; h.input += e.input || 0; h.output += e.output || 0;
    h.tasks[e.task] = (h.tasks[e.task] || 0) + 1;
    if (e.ok) h.ok++; else { const r = e.reason || 'error'; h.fails[r] = (h.fails[r] || 0) + 1; }
  }
  const claude = await claudeUsage(since);
  const status = helperStatus();
  const helperOut = Object.values(helpers).reduce((s, h) => s + h.output, 0);
  const share = helperOut + claude.output ? Math.round(100 * helperOut / (helperOut + claude.output)) : 0;

  if (args.includes('--json')) {
    console.log(JSON.stringify({ days, since, claude, helpers, status, helperOutputShare: share }, null, 2));
    return;
  }
  const line = (name) => {
    const h = helpers[name];
    return h ? `${name} ${h.runs} runs (${h.ok} ok), out ${k(h.output)}` : `${name} 0 runs`;
  };
  if (brief) {
    console.log(`helpers now: grok ${status.grok}, gemini ${status.gemini} | last ${days}d: claude out ${k(claude.output)}, ${line('grok')}, ${line('gemini')} | helper share of output ${share}%`);
    return;
  }
  console.log(`Usage, last ${days} days (since ${since.toDateString()})\n`);
  console.log(`claude  ${claude.messages} replies | output ${k(claude.output)} | input ${k(claude.input)} + cache writes ${k(claude.cacheWrite)} | cache reads ${k(claude.cacheRead)}`);
  const models = Object.entries(claude.models).sort((a, b) => b[1] - a[1]).map(([m, n]) => `${m} ${k(n)}`).join(', ');
  if (models) console.log(`        output by model: ${models}`);
  for (const name of ['grok', 'gemini']) {
    const h = helpers[name];
    if (!h) { console.log(`${name.padEnd(7)} no runs`); continue; }
    const tasks = Object.entries(h.tasks).map(([t, n]) => `${t} ${n}`).join(', ');
    const fails = Object.entries(h.fails).map(([r, n]) => `${r} ${n}`).join(', ');
    console.log(`${name.padEnd(7)} ${h.runs} runs (${tasks}) | ${h.ok} ok${fails ? `, failed: ${fails}` : ''} | avg ${Math.round(h.secs / h.runs)}s | output ${k(h.output)} | input ${k(h.input)}`);
  }
  console.log(`\nHelper share of all output tokens: ${share}%`);
  console.log(`Helpers now: grok ${status.grok} | gemini ${status.gemini}`);
  console.log('Claude plan limits (5-hour / weekly %) are not visible from the shell: Claude reads them from the app.');
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === 'record') record(rest);
else if (cmd === 'stats') stats(rest).catch((e) => { console.error(e.message); process.exit(1); });
else { console.error('usage: helper-usage.js record <run-dir> <helper> <task> <model> <exit> | stats [--days N] [--brief] [--json]'); process.exit(2); }
