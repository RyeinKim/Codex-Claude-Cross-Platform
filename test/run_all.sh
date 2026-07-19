#!/usr/bin/env bash
#
# Run every test suite in the repo (zero real tokens — all suites use mock CLIs).
#   bash suites : orchestrator happy-path + failure/injection + opt-in resume
#   node suites : Stage A SSE push, Stage B interactive, cancellation, epoch/_i
#
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
fail=0

run() { echo; echo "━━ $1 ━━"; shift; "$@" || fail=1; }

run "bridge: happy path"        bash "$here/run_mock_test.sh"
run "bridge: failure + security" bash "$here/run_error_test.sh"
run "bridge: resume (opt-in)"    bash "$here/run_resume_test.sh"
run "dashboard: SSE push"        node "$root/dashboard/test/sse_test.js"
run "dashboard: interactive"     node "$root/dashboard/test/live_test.js"
run "dashboard: cancellation"    node "$root/dashboard/test/live_cancel_test.js"
run "dashboard: epoch + _i"      node "$root/dashboard/test/live_epoch_test.js"

echo
if [ "$fail" -eq 0 ]; then
  echo "✅ ALL SUITES PASSED"
else
  echo "❌ SOME SUITES FAILED"
  exit 1
fi
