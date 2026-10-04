#!/usr/bin/env node
'use strict';

// aggregate_results.js — pools every repeat's verdict.json across a batch
// run and reports per-failure-class stats: n (claim count), CONFIRMED rate,
// and a Wilson 95% CI on that rate. Kept separate from compare_claims.js
// (which scores ONE trial's claims against that trial's own evidence)
// rather than folding this in — this script only reads many already-scored
// verdict.json files and aggregates them; it doesn't score anything itself.
//
// Reads trial_logs_archive/<task_id>/repeat_NN/verdict.json for every
// task/repeat run_batch.sh has archived — NOT ./trial_logs/verdict.json,
// since that path only ever holds the most recent repeat (run_batch.sh
// wipes and rewrites it every iteration); the per-repeat archive directory
// is the only place all repeats persist.
//
// Failure class is derived from task_id's slug (vacuous / conflation /
// scopedrift / falsepremise / longsession), matching failure_class_target
// in the task-specs-*.md files and the task_id naming convention already
// used throughout tasks_batch*.json.
//
// "n" below is a claim count (every extracted claim across every pooled
// trial in that class), not a trial count — trial counts are reported
// alongside as n_trials for context, since a handful of trials can carry
// very different numbers of claims.
//
// Usage:
//   node aggregate_results.js [archive_root]   # default ./trial_logs_archive

const fs = require('fs');
const path = require('path');

const ARCHIVE_ROOT = process.argv[2] || path.join(__dirname, 'trial_logs_archive');

const CLASS_MAP = {
  vacuous: 'vacuous_success',
  conflation: 'conflation',
  scopedrift: 'scope_drift',
  falsepremise: 'false_premise',
  longsession: 'long_session_degradation',
};
const CLASS_RE = new RegExp(`-(${Object.keys(CLASS_MAP).join('|')})-\\d+$`);

function classifyTaskId(taskId) {
  const m = taskId.match(CLASS_RE);
  return m ? CLASS_MAP[m[1]] : 'unknown';
}

// z for a 95% two-sided normal interval
const Z = 1.959963984540054;

function wilson95(confirmed, n) {
  if (n === 0) return { point: null, low: null, high: null };
  const p = confirmed / n;
  const z2 = Z * Z;
  const denom = 1 + z2 / n;
  const center = (p + z2 / (2 * n)) / denom;
  const margin = (Z * Math.sqrt((p * (1 - p)) / n + z2 / (4 * n * n))) / denom;
  return { point: p, low: Math.max(0, center - margin), high: Math.min(1, center + margin) };
}

function round4(x) {
  return Math.round(x * 10000) / 10000;
}

function findRepeatDirs(archiveRoot) {
  const taskDirs = fs.readdirSync(archiveRoot, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name);

  const repeats = [];
  for (const taskId of taskDirs) {
    const taskPath = path.join(archiveRoot, taskId);
    const entries = fs.readdirSync(taskPath, { withFileTypes: true })
      .filter(d => d.isDirectory() && /^repeat_\d+$/.test(d.name));
    for (const e of entries) {
      repeats.push({ taskId, repeatLabel: e.name, dir: path.join(taskPath, e.name) });
    }
  }
  return repeats;
}

function emptyBucket() {
  return { confirmed: 0, contradicted: 0, unverifiable: 0, total: 0, trials: 0, incompleteTrials: 0, tasks: new Set() };
}

function main() {
  if (!fs.existsSync(ARCHIVE_ROOT)) {
    console.error(`No archive found at ${ARCHIVE_ROOT}`);
    process.exit(1);
  }

  const repeats = findRepeatDirs(ARCHIVE_ROOT);
  if (repeats.length === 0) {
    console.error(`No repeat_NN/ directories found under ${ARCHIVE_ROOT}.`);
    console.error('This aggregator expects run_batch.sh\'s per-repeat archive layout (trial_logs_archive/<task_id>/repeat_NN/) — pre-repeat single-run archives from earlier calibration trials are not picked up.');
    process.exit(1);
  }

  const byClass = {};
  const overall = emptyBucket();

  for (const { taskId, repeatLabel, dir } of repeats) {
    const verdictPath = path.join(dir, 'verdict.json');
    const summaryPath = path.join(dir, 'summary.txt');

    const cls = classifyTaskId(taskId);
    if (!byClass[cls]) byClass[cls] = emptyBucket();
    const bucket = byClass[cls];

    bucket.tasks.add(taskId);
    bucket.trials++;
    overall.trials++;

    let incomplete = false;
    if (fs.existsSync(summaryPath)) {
      incomplete = fs.readFileSync(summaryPath, 'utf-8').startsWith('AGENT_INCOMPLETE:');
    }
    if (incomplete) {
      bucket.incompleteTrials++;
      overall.incompleteTrials++;
    }

    if (!fs.existsSync(verdictPath)) {
      console.error(`!! missing verdict.json for ${taskId}/${repeatLabel} — trial counted, claims skipped`);
      continue;
    }

    let verdict;
    try {
      verdict = JSON.parse(fs.readFileSync(verdictPath, 'utf-8'));
    } catch (e) {
      console.error(`!! unparseable verdict.json for ${taskId}/${repeatLabel}: ${e.message} — skipping`);
      continue;
    }

    const s = verdict.summary || {};
    bucket.confirmed += s.confirmed || 0;
    bucket.contradicted += s.contradicted || 0;
    bucket.unverifiable += s.unverifiable || 0;
    bucket.total += s.total || 0;
    overall.confirmed += s.confirmed || 0;
    overall.contradicted += s.contradicted || 0;
    overall.unverifiable += s.unverifiable || 0;
    overall.total += s.total || 0;
  }

  const report = { generated_at: new Date().toISOString(), archive_root: ARCHIVE_ROOT, classes: {} };

  console.log('=== Aggregate results by failure class ===\n');
  for (const cls of Object.keys(byClass).sort()) {
    const b = byClass[cls];
    const ci = wilson95(b.confirmed, b.total);
    report.classes[cls] = {
      n_claims: b.total,
      n_trials: b.trials,
      n_incomplete_trials: b.incompleteTrials,
      n_tasks: b.tasks.size,
      confirmed: b.confirmed,
      contradicted: b.contradicted,
      unverifiable: b.unverifiable,
      confirmed_rate: ci.point,
      wilson_95_ci: ci.low === null ? null : [round4(ci.low), round4(ci.high)],
    };

    console.log(`${cls}:`);
    console.log(`  tasks=${b.tasks.size}  trials=${b.trials} (incomplete=${b.incompleteTrials})  claims(n)=${b.total}`);
    console.log(`  confirmed=${b.confirmed}  contradicted=${b.contradicted}  unverifiable=${b.unverifiable}`);
    if (ci.point === null) {
      console.log('  CONFIRMED rate: n/a (no claims)');
    } else {
      console.log(`  CONFIRMED rate: ${(ci.point * 100).toFixed(1)}%  Wilson 95% CI: [${(ci.low * 100).toFixed(1)}%, ${(ci.high * 100).toFixed(1)}%]`);
    }
    console.log('');
  }

  const overallCi = wilson95(overall.confirmed, overall.total);
  report.overall = {
    n_claims: overall.total,
    n_trials: overall.trials,
    n_incomplete_trials: overall.incompleteTrials,
    confirmed: overall.confirmed,
    contradicted: overall.contradicted,
    unverifiable: overall.unverifiable,
    confirmed_rate: overallCi.point,
    wilson_95_ci: overallCi.low === null ? null : [round4(overallCi.low), round4(overallCi.high)],
  };

  console.log('=== Overall ===');
  console.log(`trials=${overall.trials} (incomplete=${overall.incompleteTrials})  claims(n)=${overall.total}`);
  console.log(`confirmed=${overall.confirmed}  contradicted=${overall.contradicted}  unverifiable=${overall.unverifiable}`);
  if (overallCi.point !== null) {
    console.log(`CONFIRMED rate: ${(overallCi.point * 100).toFixed(1)}%  Wilson 95% CI: [${(overallCi.low * 100).toFixed(1)}%, ${(overallCi.high * 100).toFixed(1)}%]`);
  }

  const outPath = path.join(ARCHIVE_ROOT, 'aggregate_report.json');
  fs.writeFileSync(outPath, JSON.stringify(report, null, 2));
  console.log(`\nFull detail saved to ${outPath}`);
}

main();
