#!/usr/bin/env bash
# Runs everything still outstanding after batch 11-15 died mid-sleep:
#   1. footystock-falsepremise-01 repeats 4-5 (repeat_04 was an api_error stub,
#      moved aside to _aborted_repeat_04_ratelimit_stub)
#   2. footystock-longsession-01 repeats 1-5 (never started)
#   3. tasks 16-20, repeats 1-5
# Stops at the first step whose run_batch.sh exits nonzero.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

echo "##### step 1/3: footystock-falsepremise-01 repeats 4-5 #####"
START_REPEAT=4 REPEATS=5 ./run_batch.sh tasks_resume_fs_falsepremise01.json 2>&1 | tee batch_resume_fs_falsepremise01.log

echo "##### step 2/3: footystock-longsession-01 repeats 1-5 #####"
REPEATS=5 ./run_batch.sh tasks_resume_fs_longsession01.json 2>&1 | tee batch_resume_fs_longsession01.log

echo "##### step 3/3: tasks 16-20 repeats 1-5 #####"
REPEATS=5 ./run_batch.sh tasks_16to20.json 2>&1 | tee batch_16to20_run.log

echo "##### all remaining 11-20 work done #####"
