#!/usr/bin/env bash
set -euo pipefail

# run_batch.sh — drives task specs (JSON) through the full harness:
# run_trial.sh (baseline) -> Claude Code headless -> extract_claims.js ->
# run_trial.sh (result) -> compare_claims.js, archiving evidence per task
# per repeat.
#
# Requires: ANTHROPIC_API_KEY set (extract_claims.js calls the API directly).
#
# Known quirks of the underlying scripts (see chat), worked around here rather
# than by editing them:
#   - run_trial.sh writes some evidence relative to $REPO_DIR's parent, not to
#     wherever it's invoked from -> everything below runs from
#     $(dirname "$REPO_PATH") so it all lands in one ./trial_logs.
#   - compare_claims.js hardcodes ./trial_logs relative to its own invocation
#     cwd, with no per-task isolation -> that folder is wiped at the start of
#     every repeat so stale evidence from a prior repeat/task can't leak in.
#   - extract_claims.js classifies claims into 5 types but compare_claims.js
#     only scores 4 of them — any "test_run" claim will always come back
#     UNVERIFIABLE regardless of actual test evidence. Known gap, not fixed
#     here; factor it in when reading verdicts.
#
# Usage-limit auto-resume: on a 429/session-limit hit (terminal_reason
# "api_error"), this no longer hard-aborts the batch. It parses the reset
# time out of the CLI's own message ("...resets 6:50pm (America/Los_Angeles)"),
# sleeps until just past that time, and retries the SAME repeat automatically
# — up to MAX_RATE_LIMIT_RETRIES times (default 20) before giving up on that
# repeat and aborting for real, so a persistently broken auth/key doesn't
# sleep-loop forever. If the reset time can't be parsed from the message, it
# falls back to a fixed 30-minute retry interval instead. This makes an
# unattended multi-hour batch survive a session-limit reset on its own; no
# manual relaunch needed for that case anymore.
#
# Repeats: each task now runs REPEATS times (default 10) from the SAME
# pinned baseline commit every time. "Clean tree" alone isn't enough for
# repeat 2+: a prior repeat may have *committed* its changes, which leaves
# the tree clean but HEAD advanced. So the baseline commit is captured once
# per task, before the repeat loop, and every repeat does an unconditional
# `reset --hard` back to that exact commit (not just when dirty) so all N
# repeats start from byte-identical code. Evidence for repeat r of a task
# lands in trial_logs_archive/<task_id>/repeat_NN/ — this is a new
# subdirectory, so it does not collide with any pre-existing flat
# trial_logs_archive/<task_id>/*.json from earlier single-run calibration
# trials.
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   REPEATS=10 ./run_batch.sh tasks_all25.json
#   START_REPEAT=3 REPEATS=5 ./run_batch.sh tasks_subset.json   # resume from repeat 3, applies to every task in the file

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ARCHIVE_ROOT="$ROOT_DIR/results/trial_logs_archive"
mkdir -p "$ARCHIVE_ROOT"

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set — extract_claims.js calls the API directly}"

TASKS_FILE="${1:?usage: run_batch.sh tasks.json}"
N=$(jq 'length' "$TASKS_FILE")
REPEATS="${REPEATS:-10}"
START_REPEAT="${START_REPEAT:-1}"  # resume support: skip repeats < this for every task in the file
MAX_RATE_LIMIT_RETRIES="${MAX_RATE_LIMIT_RETRIES:-20}"

# Sleeps until just past the reset time parsed out of a CLI rate-limit
# message (e.g. "You've hit your session limit · resets 6:50pm
# (America/Los_Angeles)"), or a fixed fallback interval if it can't parse
# one. Echoes progress to stderr so it's visible in the batch log.
wait_for_rate_limit_reset() {
  local msg="$1"
  local wait_seconds=1800  # fallback: retry every 30 min if no reset time found
  local reset_epoch=""
  local re='resets ([0-9]{1,2}:[0-9]{2}(am|pm|AM|PM)) \(([^)]+)\)'

  if [[ "$msg" =~ $re ]]; then
    local time_upper tz today now_epoch
    time_upper=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
    tz="${BASH_REMATCH[3]}"
    today=$(TZ="$tz" date +%Y-%m-%d 2>/dev/null || true)
    if [[ -n "$today" ]]; then
      reset_epoch=$(TZ="$tz" date -j -f "%Y-%m-%d %I:%M%p" "$today $time_upper" +%s 2>/dev/null || true)
      now_epoch=$(date +%s)
      # The message only has minute granularity, so "now" can be a few
      # seconds past the parsed minute-mark even though the real reset
      # (anywhere in that 60s window) hasn't happened yet. Only treat it as
      # yesterday's time (roll to tomorrow) if we're more than 2 minutes
      # past it — a genuine rollover, not rounding noise.
      if [[ -n "$reset_epoch" && $((reset_epoch + 120)) -le "$now_epoch" ]]; then
        local tomorrow
        tomorrow=$(TZ="$tz" date -v+1d +%Y-%m-%d 2>/dev/null || true)
        reset_epoch=$(TZ="$tz" date -j -f "%Y-%m-%d %I:%M%p" "$tomorrow $time_upper" +%s 2>/dev/null || true)
      fi
    fi
  fi

  if [[ -n "$reset_epoch" ]]; then
    local now_epoch2
    now_epoch2=$(date +%s)
    wait_seconds=$(( reset_epoch - now_epoch2 + 90 ))  # +90s buffer past the stated reset
    [[ $wait_seconds -lt 30 ]] && wait_seconds=30
    [[ $wait_seconds -gt 28800 ]] && wait_seconds=28800  # sanity cap: 8h
    echo "  parsed reset time -> sleeping ${wait_seconds}s (until ~$(date -r $((now_epoch2 + wait_seconds)) 2>/dev/null))" >&2
  else
    echo "  could not parse a reset time from: \"$msg\" — falling back to ${wait_seconds}s retry interval" >&2
  fi

  sleep "$wait_seconds"
}

for ((i=0; i<N; i++)); do
  TASK_ID=$(jq -r ".[$i].task_id" "$TASKS_FILE")
  REPO_PATH=$(jq -r ".[$i].repo_path" "$TASKS_FILE")
  PROMPT=$(jq -r ".[$i].prompt" "$TASKS_FILE")
  TEST_CMD=$(jq -r ".[$i].test_command // empty" "$TASKS_FILE")
  PARENT_DIR="$(dirname "$REPO_PATH")"
  TRIAL_LOG_DIR="$PARENT_DIR/trial_logs"

  # Pin the baseline ONCE per task, before any repeat runs. If the tree is
  # dirty (leftover from something outside this harness), reset to HEAD
  # first; then whatever HEAD is at that point becomes the pinned commit
  # every repeat below resets back to, regardless of what repeats commit.
  if [[ -n "$(git -C "$REPO_PATH" status --porcelain)" ]]; then
    echo "!! $TASK_ID: dirty tree, resetting to HEAD before running" >&2
    git -C "$REPO_PATH" reset --hard HEAD
    git -C "$REPO_PATH" clean -fd
  fi
  TASK_BASELINE_COMMIT=$(git -C "$REPO_PATH" rev-parse HEAD)

  for ((r=START_REPEAT; r<=REPEATS; r++)); do
    REPEAT_LABEL=$(printf "repeat_%02d" "$r")
    ARCHIVE_DIR="$ARCHIVE_ROOT/$TASK_ID/$REPEAT_LABEL"
    mkdir -p "$ARCHIVE_DIR"

    echo "=== [$((i+1))/$N] $TASK_ID ($REPEAT_LABEL, $r/$REPEATS) ==="

    # 0. Wipe leftover trial_logs from a prior repeat/task sharing this
    #    parent dir — compare_claims.js has no per-task isolation of its own.
    rm -rf "$TRIAL_LOG_DIR"

    # 1. Fresh, committed baseline — unconditionally pinned back to the
    #    commit captured above, not just reset when dirty. A repeat that
    #    committed its changes would otherwise leave HEAD advanced with a
    #    clean tree, which the dirty-check alone would miss.
    git -C "$REPO_PATH" reset --hard "$TASK_BASELINE_COMMIT"
    git -C "$REPO_PATH" clean -fd
    ( cd "$PARENT_DIR" && "$HARNESS_DIR/run_trial.sh" "$REPO_PATH" baseline )

    # 2. Headless agent run. Fresh session every time. The real CLI has no --cwd
    #    flag (that only exists on a third-party wrapper) — cd into the repo instead.
    #    env -u ANTHROPIC_API_KEY: strip the key back out here so the CLI falls
    #    back to your normal claude.ai login instead of switching to API billing —
    #    the key below is only needed for extract_claims.js's direct API call.
    # Some tasks (esp. the harder ones) legitimately hit max-turns/max-budget
    # before producing a final `.result` text, and the CLI exits nonzero in
    # that case. Don't let one repeat's incompletion abort the whole batch
    # under set -e — capture the exit code, note it, and still gather
    # whatever partial diff evidence exists for that repeat.
    # max-turns default 65 (was 40): tasks 16/17 (15-0-longsession-02/03)
    # were found to legitimately need more than 40 turns and still hit the
    # cap at 65 without finishing — 65 is the calibrated floor, not a fix
    # for those two specifically, so no per-task override is needed here.
    #
    # Retries the SAME repeat's agent call on a session-limit hit (see the
    # usage-limit auto-resume note at the top of this file) — up to
    # MAX_RATE_LIMIT_RETRIES times — instead of aborting the batch.
    rl_attempt=0
    while true; do
      set +e
      ( cd "$REPO_PATH" && env -u ANTHROPIC_API_KEY claude -p "$PROMPT" \
        --allowedTools "Bash,Edit,Read,Grep,Glob" \
        --permission-mode acceptEdits \
        --max-turns "${MAX_TURNS:-65}" \
        --max-budget-usd 3 \
        --output-format json ) \
        > "$ARCHIVE_DIR/agent_raw.json" 2> "$ARCHIVE_DIR/agent.err"
      AGENT_EXIT=$?
      set -e

      # A non-null `.result` is not sufficient on its own: a 429/rate-limit hit
      # (terminal_reason "api_error") still populates `.result` with a CLI status
      # string like "You've hit your session limit · resets ..." — that is not an
      # agent summary and must not be fed to extract_claims.js as if it were one.
      IS_ERROR=$(jq -r '.is_error // false' "$ARCHIVE_DIR/agent_raw.json" 2>/dev/null || echo true)
      TERMINAL_REASON=$(jq -r '.terminal_reason // "unknown"' "$ARCHIVE_DIR/agent_raw.json" 2>/dev/null || echo unknown)
      HAS_RESULT=$(jq -r 'has("result") and (.result != null)' "$ARCHIVE_DIR/agent_raw.json" 2>/dev/null || echo false)

      if [[ "$TERMINAL_REASON" != "api_error" ]]; then
        break
      fi

      rl_attempt=$((rl_attempt + 1))
      RATE_LIMIT_MSG=$(jq -r '.result // "(no message)"' "$ARCHIVE_DIR/agent_raw.json" 2>/dev/null)
      if [[ $rl_attempt -gt $MAX_RATE_LIMIT_RETRIES ]]; then
        echo "!! $TASK_ID $REPEAT_LABEL: API error persisted after $MAX_RATE_LIMIT_RETRIES auto-retries: $RATE_LIMIT_MSG" >&2
        echo "!! Giving up on this repeat and aborting the rest of the batch — this doesn't look like an ordinary session-limit reset." >&2
        exit 1
      fi
      echo "!! $TASK_ID $REPEAT_LABEL: hit usage limit (auto-retry $rl_attempt/$MAX_RATE_LIMIT_RETRIES): $RATE_LIMIT_MSG" >&2
      wait_for_rate_limit_reset "$RATE_LIMIT_MSG"
      echo "!! $TASK_ID $REPEAT_LABEL: resuming automatically after wait" >&2
    done

    if [[ "$HAS_RESULT" == "true" && "$IS_ERROR" != "true" ]]; then
      jq -r '.result' "$ARCHIVE_DIR/agent_raw.json" > "$ARCHIVE_DIR/summary.txt"
    else
      ERRORS=$(jq -r '(.errors // []) | join("; ")' "$ARCHIVE_DIR/agent_raw.json" 2>/dev/null || echo "")
      echo "!! $TASK_ID $REPEAT_LABEL: agent run did not finish (exit $AGENT_EXIT, terminal_reason=$TERMINAL_REASON${ERRORS:+, errors: $ERRORS}) — no summary text; capturing diff evidence only" >&2
      echo "AGENT_INCOMPLETE: exit=$AGENT_EXIT terminal_reason=$TERMINAL_REASON errors=$ERRORS" > "$ARCHIVE_DIR/summary.txt"
    fi

    # 3. Extract claims (real signature: <summary_path> [output_path]).
    #    Point output_path straight at $TRIAL_LOG_DIR so compare_claims.js's
    #    hardcoded default finds it later — no cwd juggling needed here since
    #    both args are absolute paths.
    #    Skipped when the agent never produced a real summary — there's no
    #    prose to extract claims from, and it isn't worth an API call.
    if [[ "$HAS_RESULT" == "true" ]]; then
      node "$HARNESS_DIR/extract_claims.js" \
        "$ARCHIVE_DIR/summary.txt" \
        "$TRIAL_LOG_DIR/extracted_claims.json"

      # extract_claims.js sometimes emits "path:lineno" as the target for
      # file_modified claims. Both run_trial.sh's -f check and compare_claims.js's
      # own target-matching treat the whole string as a literal filename, so an
      # untouched ":lineno" suffix reads back as MISSING/UNVERIFIABLE even when
      # the file was genuinely modified. Sanitize the claims file itself here
      # (not the two scripts already documented as not-edited) so every
      # downstream consumer of extracted_claims.json sees the clean path.
      # Broadened from a numeric-only suffix match after finding a
      # ":functionName()" variant (footystock-scopedrift-02, batch 4) — no
      # filename in this project ever contains a literal colon, so strip
      # everything from the first colon onward unconditionally.
      jq '[.[] | if .type == "file_modified" then .target |= sub(":.*$"; "") else . end]' \
        "$TRIAL_LOG_DIR/extracted_claims.json" > "$TRIAL_LOG_DIR/extracted_claims.json.tmp"
      mv "$TRIAL_LOG_DIR/extracted_claims.json.tmp" "$TRIAL_LOG_DIR/extracted_claims.json"

      CLAIMED_FILES=$(jq -r '[.[] | select(.type=="file_modified") | .target] | unique | join(" ")' \
        "$TRIAL_LOG_DIR/extracted_claims.json")
    else
      echo "[]" > "$TRIAL_LOG_DIR/extracted_claims.json"
      CLAIMED_FILES=""
    fi

    # 4. Evidence capture. Real run_trial.sh CLI: positional repo_dir + mode,
    #    --claimed-files takes ONE space-separated string, trailing args = test command.
    RESULT_ARGS=("$REPO_PATH" result)
    [[ -n "$CLAIMED_FILES" ]] && RESULT_ARGS+=(--claimed-files "$CLAIMED_FILES")
    [[ -n "$TEST_CMD" ]] && RESULT_ARGS+=($TEST_CMD)
    ( cd "$PARENT_DIR" && "$HARNESS_DIR/run_trial.sh" "${RESULT_ARGS[@]}" ) | tee "$ARCHIVE_DIR/result_console.txt"

    # 5. Comparator. No path args for evidence — must run from PARENT_DIR so its
    #    hardcoded ./trial_logs matches where everything above just wrote.
    ( cd "$PARENT_DIR" && node "$HARNESS_DIR/compare_claims.js" ) | tee "$ARCHIVE_DIR/compare_console.txt" || true

    # 6. Archive everything for this trial before the next repeat wipes it.
    cp -r "$TRIAL_LOG_DIR/." "$ARCHIVE_DIR/" 2>/dev/null || true

    echo "    -> evidence archived to $ARCHIVE_DIR"
  done
done

echo "Done. $N tasks x $REPEATS repeats archived under $ARCHIVE_ROOT"
