#!/bin/sh
set -e

# Split args: everything before -- goes to analyzer, everything after to tui
# The shell script passes analyzer args first, tui args (--append-*) after.
# We separate them by scanning for known tui flags.

ANALYZER_ARGS=""
TUI_ARGS=""
mode="analyzer"

for arg in "$@"; do
  case "$arg" in
    --append-bash|--append-fish) mode="tui" ;;
  esac
  if [ "$mode" = "tui" ]; then
    TUI_ARGS="$TUI_ARGS $arg"
  else
    ANALYZER_ARGS="$ANALYZER_ARGS $arg"
  fi
done

# --json: skip TUI entirely
for arg in "$@"; do
  if [ "$arg" = "--json" ]; then
    python /app/analyzer.py $ANALYZER_ARGS
    exit $?
  fi
done

python /app/analyzer.py $ANALYZER_ARGS > /tmp/suggestions.ndjson
python /app/tui.py /tmp/suggestions.ndjson --output-dir /output $TUI_ARGS
