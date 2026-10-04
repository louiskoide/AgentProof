#!/usr/bin/env bash
set -euo pipefail

# pull_contradicted_trials.sh — after a batch run, stages every trial that
# has at least one CONTRADICTED claim (per that trial's verdict.json) into
# contradicted_for_tagging/<task_id>/<repeat_NN>/ for manual severity
# tagging. Trials with zero CONTRADICTED claims (all CONFIRMED/UNVERIFIABLE)
# are left out entirely — nothing is staged for them, per "leave CONFIRMED
# trials untagged."
#
# Stages, per qualifying trial: verdict.json (the claim-by-claim scoring),
# summary.txt (agent's own summary/transcript text), actual_diff.txt (real
# git diff vs baseline — the "diff" half of transcript+diff), agent_raw.json
# (full CLI JSON output incl. tool calls), changed_files.txt.
#
# Does NOT apply any severity taxonomy itself — this project's severity
# taxonomy isn't captured anywhere in this repo's files as of this script's
# writing (grepped for "taxonomy"/"severity" across phase1_documents/,
# nothing found), so tagging has to stay manual until that's supplied. This
# script only stages evidence for a human (or a separately-briefed pass) to
# tag against it.
#
# Usage:
#   ./pull_contradicted_trials.sh [archive_root] [out_dir]
#   defaults: archive_root=./trial_logs_archive  out_dir=./contradicted_for_tagging

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_ROOT="${1:-$HARNESS_DIR/trial_logs_archive}"
OUT_DIR="${2:-$HARNESS_DIR/contradicted_for_tagging}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

COUNT=0
TOTAL=0

while IFS= read -r -d '' verdict_path; do
  TOTAL=$((TOTAL + 1))
  repeat_dir="$(dirname "$verdict_path")"
  repeat_label="$(basename "$repeat_dir")"
  task_id="$(basename "$(dirname "$repeat_dir")")"

  contradicted=$(jq -r '.summary.contradicted // 0' "$verdict_path")
  if [[ "$contradicted" -gt 0 ]]; then
    dest="$OUT_DIR/$task_id/$repeat_label"
    mkdir -p "$dest"
    for f in verdict.json summary.txt actual_diff.txt agent_raw.json changed_files.txt; do
      [[ -f "$repeat_dir/$f" ]] && cp "$repeat_dir/$f" "$dest/$f"
    done
    echo "staged: $task_id/$repeat_label (contradicted=$contradicted)"
    COUNT=$((COUNT + 1))
  fi
done < <(find "$ARCHIVE_ROOT" -path "*/repeat_*/verdict.json" -print0 2>/dev/null)

echo ""
echo "Staged $COUNT of $TOTAL trials with >=1 CONTRADICTED claim under $OUT_DIR"
echo "CONFIRMED-only trials were left out entirely (not staged)."
echo "Reminder: no severity taxonomy file exists yet in this project — tagging needs that supplied before it can proceed."
