#!/usr/bin/env bash
# The workspace test sweep — one owner, used by CI and locally alike:
#
#   ./tool/test_sweep.sh
#
# Runs `dart test` in every package that has test files. Suites with
# machine prerequisites degrade honestly rather than fail:
#   - llama suites self-skip without ~/models/*.gguf + libllama
#     (see docs/ZERO_COPY.md setup),
#   - gemini CLI integration is opt-in (VASTER_GEMINI_CLI_TESTS=1),
# so a green sweep means every runnable suite passed, and the skips are
# visible in the output.
set -u

fail=0
for dir in packages/*/; do
  name=$(basename "$dir")
  if ! find "$dir/test" -name '*_test.dart' -print -quit 2>/dev/null | grep -q .; then
    continue
  fi
  echo "── $name"
  if ! (cd "$dir" && dart test --reporter compact); then
    echo "✗ $name FAILED"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "SWEEP FAILED"
  exit 1
fi
echo "SWEEP GREEN"
