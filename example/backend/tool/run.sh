#!/usr/bin/env sh
# Starts the reference backend. If a .env file exists (in this directory or at
# the repo root), it is sourced into the environment WITHOUT echoing anything.
#
#   cp ../../env.template ../../.env   # fill in sandbox values, then:
#   tool/run.sh
set -eu
cd "$(dirname "$0")/.."

for candidate in ./.env ../../.env; do
  if [ -f "$candidate" ]; then
    # `set -a` exports every variable the file assigns; `set +a` stops that.
    # Nothing is printed: no `cat`, no `echo`, and xtrace stays off.
    set +x
    set -a
    . "$candidate"
    set +a
    echo "loaded environment from $candidate"
    break
  fi
done

exec dart run bin/server.dart
