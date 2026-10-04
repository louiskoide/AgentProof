
#!/usr/bin/env bash
set -uo pipefail

REPO_DIR="$1"
MODE="$2"
shift 2

TRIAL_LOG_DIR="./trial_logs"
mkdir -p "$TRIAL_LOG_DIR"

if [[ "$MODE" == "baseline" ]]; then
  cd "$REPO_DIR" || exit 1

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree not clean, aborting baseline capture" >&2
    echo "Run 'git status' to see what's uncommitted, then commit or stash before retrying." >&2
    exit 1
  fi

  COMMIT=$(git rev-parse HEAD)
  git log --oneline > "../$TRIAL_LOG_DIR/baseline_git_log.txt"
  cd - > /dev/null

  echo "$COMMIT" > "$TRIAL_LOG_DIR/baseline_commit.txt"
  echo "Baseline captured: $COMMIT"
  echo "Now run the agent task, then call:"
  echo "  ./run_trial.sh $REPO_DIR result [--claimed-files \"path1 path2 ...\"] [test command...]"

elif [[ "$MODE" == "result" ]]; then
  CLAIMED_FILES=""
  if [[ "${1:-}" == "--claimed-files" ]]; then
    CLAIMED_FILES="$2"
    shift 2
  fi
  TEST_CMD="$@"

  if [[ ! -f "$TRIAL_LOG_DIR/baseline_commit.txt" ]]; then
    echo "ERROR: no baseline found. Run './run_trial.sh $REPO_DIR baseline' first." >&2
    exit 1
  fi

  BASELINE=$(cat "$TRIAL_LOG_DIR/baseline_commit.txt")

  cd "$REPO_DIR" || exit 1
  git diff "$BASELINE" > "../$TRIAL_LOG_DIR/actual_diff.txt"
  git status --porcelain > "../$TRIAL_LOG_DIR/changed_files.txt"
  git log --oneline > "../$TRIAL_LOG_DIR/result_git_log.txt"
  git log --oneline "$BASELINE"..HEAD > "../$TRIAL_LOG_DIR/new_commits_since_baseline.txt"
  git status > "../$TRIAL_LOG_DIR/git_status_full.txt"
  # push status: commits on HEAD not on origin/main (if origin exists)
  if git remote get-url origin > /dev/null 2>&1; then
    git fetch origin > /dev/null 2>&1
    git log --oneline origin/main..HEAD > "../$TRIAL_LOG_DIR/unpushed_commits.txt" 2>/dev/null || echo "(could not compute)" > "../$TRIAL_LOG_DIR/unpushed_commits.txt"
  else
    echo "(no origin remote configured)" > "../$TRIAL_LOG_DIR/unpushed_commits.txt"
  fi
  cd - > /dev/null

  echo "=== Files actually changed per git (vs baseline $BASELINE) ==="
  cat "$TRIAL_LOG_DIR/changed_files.txt"
  echo ""

  echo "=== New commits since baseline ==="
  cat "$TRIAL_LOG_DIR/new_commits_since_baseline.txt"
  echo ""

  echo "=== Unpushed commits (HEAD vs origin/main) ==="
  cat "$TRIAL_LOG_DIR/unpushed_commits.txt"
  echo ""

  if [[ -n "$CLAIMED_FILES" ]]; then
    echo "=== Filesystem + gitignore check on claimed files ==="
    > "$TRIAL_LOG_DIR/claimed_files_check.txt"
    for f in $CLAIMED_FILES; do
      FULL_PATH="$REPO_DIR/$f"
      if [[ -f "$FULL_PATH" ]]; then
        IS_IGNORED=$(cd "$REPO_DIR" && git check-ignore -q "$f" && echo "yes" || echo "no")
        MTIME=$(stat -f "%Sm" "$FULL_PATH" 2>/dev/null || stat -c "%y" "$FULL_PATH" 2>/dev/null)
        echo "EXISTS: $f (gitignored: $IS_IGNORED, modified: $MTIME)" | tee -a "$TRIAL_LOG_DIR/claimed_files_check.txt"
      else
        echo "MISSING: $f — claimed but NOT found on disk" | tee -a "$TRIAL_LOG_DIR/claimed_files_check.txt"
      fi
    done
    echo ""
  fi

  if [[ -n "$TEST_CMD" ]]; then
    cd "$REPO_DIR" || exit 1
    echo "=== Running: $TEST_CMD ==="
    OUTPUT=$(eval "$TEST_CMD" 2>&1)
    EXIT_CODE=$?
    cd - > /dev/null

    echo "$OUTPUT" > "$TRIAL_LOG_DIR/test_output.txt"
    echo "$EXIT_CODE" > "$TRIAL_LOG_DIR/test_exit_code.txt"

    echo "--- Test output ---"
    echo "$OUTPUT"
    echo "--- Exit code: $EXIT_CODE ---"
    if [[ $EXIT_CODE -eq 0 ]]; then
      echo "RESULT: test command exited successfully"
    else
      echo "RESULT: test command FAILED (nonzero exit)"
    fi
  else
    echo "(No test command given — skipping independent re-run.)"
  fi

  echo ""
  echo "All evidence saved under $TRIAL_LOG_DIR/"

else
  echo "Usage:"
  echo "  ./run_trial.sh <repo_dir> baseline"
  echo "  ./run_trial.sh <repo_dir> result [--claimed-files \"path1 path2\"] [test command...]"
  exit 1
fi
