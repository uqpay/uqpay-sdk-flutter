#!/usr/bin/env bash
# Lists the package's test files, split by whether they compare pixels.
#
#   .github/scripts/test_files.sh golden       # files with a golden compare
#   .github/scripts/test_files.sh non-golden   # every other *_test.dart
#
# Why: the golden PNGs are generated on macOS, and font
# rasterisation / anti-aliasing differs between macOS and Linux, so a
# golden compare is only meaningful on a macOS runner. ci.yaml runs the FULL
# suite (goldens included) on macos-latest and the non-golden files on
# ubuntu-latest.
#
# The split is by content, not by a hand-kept list, so a new golden test is
# picked up automatically: a file is "golden" when it calls
# `matchesGoldenFile` or is tagged `@Tags(['golden'])`.
set -euo pipefail
cd "$(dirname "$0")/../.."

mode="${1:-}"
pattern="matchesGoldenFile|@Tags\\(.*'golden'"

all="$(find test -name '*_test.dart' -type f | LC_ALL=C sort)"
golden="$(grep -lE "$pattern" $all || true)"

case "$mode" in
  golden)
    printf '%s\n' "$golden" | sed '/^$/d'
    ;;
  non-golden)
    if [[ -z "$golden" ]]; then
      printf '%s\n' "$all"
    else
      grep -vxF -f <(printf '%s\n' "$golden") <<<"$all" || true
    fi
    ;;
  *)
    echo "usage: $0 golden|non-golden" >&2
    exit 2
    ;;
esac
