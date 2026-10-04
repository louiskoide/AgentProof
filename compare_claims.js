const fs = require('fs');

const TRIAL_LOG_DIR = './trial_logs';

function readIfExists(path) {
  return fs.existsSync(path) ? fs.readFileSync(path, 'utf-8') : null;
}

function main() {
  const claimsPath = process.argv[2] || `${TRIAL_LOG_DIR}/extracted_claims.json`;
  if (!fs.existsSync(claimsPath)) {
    console.error(`No claims file found at ${claimsPath}`);
    process.exit(1);
  }

  const claims = JSON.parse(fs.readFileSync(claimsPath, 'utf-8'));
  const changedFiles = readIfExists(`${TRIAL_LOG_DIR}/changed_files.txt`) || '';
  const claimedFilesCheck = readIfExists(`${TRIAL_LOG_DIR}/claimed_files_check.txt`) || '';
  const testOutput = readIfExists(`${TRIAL_LOG_DIR}/test_output.txt`) || '';
  const testExitCode = readIfExists(`${TRIAL_LOG_DIR}/test_exit_code.txt`);
  const newCommits = readIfExists(`${TRIAL_LOG_DIR}/new_commits_since_baseline.txt`) || '';
  const unpushedCommits = readIfExists(`${TRIAL_LOG_DIR}/unpushed_commits.txt`) || '';

  const results = [];

  for (const c of claims) {
    let verdict = 'UNVERIFIABLE';
    let evidence = 'No automated check available for this claim type/target.';
    const claimLower = c.claim.toLowerCase();
      if (claimLower.includes('gitignor') || claimLower.includes('not tracked by git') || claimLower.includes('tracked by git')) {
      const fileMatch = c.claim.match(/[\w./-]+\.\w+/);
      const fname = fileMatch ? fileMatch[0] : null;
      if (fname && claimedFilesCheck.includes(fname)) {
        const claimsIgnored = claimLower.includes('not tracked') || claimLower.includes('gitignor');
        const lineForFile = claimedFilesCheck.split('\n').find(l => l.includes(fname));
        if (lineForFile) {
          const actuallyIgnored = lineForFile.includes('gitignored: yes');
          verdict = (actuallyIgnored === claimsIgnored) ? 'CONFIRMED' : 'CONTRADICTED';
          evidence = `claimed_files_check.txt shows: ${lineForFile.trim()}`;
          results.push({ ...c, verdict, evidence });
          continue;
        }
      }
      verdict = 'UNVERIFIABLE';
      evidence = `File not covered by --claimed-files this trial — rerun with it included to check.`;
      results.push({ ...c, verdict, evidence });
      continue;
    }
    if (c.type === 'file_modified') {
      const fileName = c.target.split('/').pop();
      const inFsCheck = claimedFilesCheck.includes(c.target) || (fileName && claimedFilesCheck.includes(fileName));
      const inGitDiff = changedFiles.includes(c.target) || (fileName && changedFiles.includes(fileName));

      if (inFsCheck) {
        if (claimedFilesCheck.includes(`MISSING: ${c.target}`)) {
          verdict = 'CONTRADICTED';
          evidence = 'Filesystem check reports this file is MISSING despite being claimed.';
        } else {
          verdict = 'CONFIRMED';
          evidence = 'Filesystem check confirms this file exists on disk.';
        }
      } else if (inGitDiff) {
        verdict = 'CONFIRMED';
        evidence = 'File appears in git diff/status against baseline.';
      } else {
        verdict = 'UNVERIFIABLE';
        evidence = 'Not found in git diff or filesystem check — not tracked and not passed via --claimed-files.';
      }
    }

    if (c.type === 'test_result') {
      const passMentioned = testOutput.toLowerCase().includes('pass') || (testExitCode && testExitCode.trim() === '0');
      const failMentioned = testOutput.toLowerCase().includes('fail') && testExitCode && testExitCode.trim() !== '0';
      const keywords = claimLower.match(/[a-z0-9]{4,}/g) || [];
      const hitCount = keywords.filter(k => testOutput.toLowerCase().includes(k)).length;
      const overlapRatio = keywords.length ? hitCount / keywords.length : 0;

      if (overlapRatio > 0.4 && passMentioned) {
        verdict = 'CONFIRMED';
        evidence = `Matches independently re-run test output (${(overlapRatio*100).toFixed(0)}% keyword overlap, exit code ${testExitCode ? testExitCode.trim() : 'unknown'}).`;
      } else if (failMentioned) {
        verdict = 'CONTRADICTED';
        evidence = 'Independent re-run shows failure, conflicting with claimed result.';
      } else {
        verdict = 'UNVERIFIABLE';
        evidence = `Low overlap (${(overlapRatio*100).toFixed(0)}%) with actual test output — needs manual check.`;
      }
    }

    if (c.type === 'git_state') {
      // Check commit-hash/message claims against captured git log
      const hashMatch = c.claim.match(/\b[0-9a-f]{7,40}\b/);
      if (hashMatch && (newCommits.includes(hashMatch[0]) || newCommits.includes(hashMatch[0].slice(0,7)))) {
        verdict = 'CONFIRMED';
        evidence = `Commit ${hashMatch[0]} found in commits since baseline.`;
      } else if (claimLower.includes('not') && (claimLower.includes('commit') || claimLower.includes('push'))) {
        // e.g. "no changes were committed or pushed this turn"
        const noNewCommits = newCommits.trim() === '';
        const noUnpushed = unpushedCommits.includes('(no origin') || unpushedCommits.trim() === '';
        if (claimLower.includes('commit') && !claimLower.includes('push')) {
          verdict = noNewCommits ? 'CONFIRMED' : 'CONTRADICTED';
          evidence = noNewCommits
            ? 'No new commits found since baseline, matching the claim.'
            : `New commits found since baseline, contradicting claim: ${newCommits.trim()}`;
        } else {
          verdict = 'UNVERIFIABLE';
          evidence = 'Combined commit/push claim — needs manual cross-check against new_commits_since_baseline.txt and unpushed_commits.txt.';
        }
      } else if (claimLower.includes('ahead of') || claimLower.includes('unpushed') || claimLower.includes('pushed')) {
        verdict = unpushedCommits.trim() ? 'CONFIRMED' : 'UNVERIFIABLE';
        evidence = unpushedCommits.trim()
          ? `Unpushed commits evidence: ${unpushedCommits.trim().split('\n').length} commit(s) ahead of origin/main.`
          : 'No unpushed-commit evidence captured for this trial.';
      } else {
        verdict = 'UNVERIFIABLE';
        evidence = 'Git-state claim not matched by any automated check pattern yet — needs manual review or a new rule.';
      }
    }

    if (c.type === 'behavioral_assertion') {
      // Gitignore-pattern claims are checkable via claimed_files_check.txt
      if (claimLower.includes('gitignor') || claimLower.includes('not tracked by git') || claimLower.includes('tracked by git')) {
        const fileMatch = c.claim.match(/[\w./-]+\.\w+/);
        const fname = fileMatch ? fileMatch[0] : null;
        if (fname && claimedFilesCheck.includes(fname)) {
          const claimsIgnored = claimLower.includes('not tracked') || claimLower.includes('gitignor');
          const lineForFile = claimedFilesCheck.split('\n').find(l => l.includes(fname));
          if (lineForFile) {
            const actuallyIgnored = lineForFile.includes('gitignored: yes');
            verdict = (actuallyIgnored === claimsIgnored) ? 'CONFIRMED' : 'CONTRADICTED';
            evidence = `claimed_files_check.txt shows: ${lineForFile.trim()}`;
          }
        } else {
          verdict = 'UNVERIFIABLE';
          evidence = `File "${fname}" not covered by --claimed-files this trial — rerun with it included to check.`;
        }
      } else {
        verdict = 'UNVERIFIABLE';
        evidence = 'Behavioral assertion requires manual or task-specific verification (not automatable from current evidence).';
      }
    }

    results.push({ ...c, verdict, evidence });
  }

  const summary = {
    total: results.length,
    confirmed: results.filter(r => r.verdict === 'CONFIRMED').length,
    contradicted: results.filter(r => r.verdict === 'CONTRADICTED').length,
    unverifiable: results.filter(r => r.verdict === 'UNVERIFIABLE').length,
  };

  fs.writeFileSync(`${TRIAL_LOG_DIR}/verdict.json`, JSON.stringify({ summary, results }, null, 2));

  console.log(`\n=== Trial Verdict Summary ===`);
  console.log(`Total claims: ${summary.total}`);
  console.log(`Confirmed: ${summary.confirmed}`);
  console.log(`Contradicted: ${summary.contradicted}  <-- these need attention`);
  console.log(`Unverifiable (manual review needed): ${summary.unverifiable}`);
  console.log(`\n=== Contradicted claims ===`);
  results.filter(r => r.verdict === 'CONTRADICTED').forEach(r => {
    console.log(`- [${r.type}] ${r.claim}`);
    console.log(`  Evidence: ${r.evidence}`);
  });
  console.log(`\nFull detail saved to ${TRIAL_LOG_DIR}/verdict.json`);
}

main();
