#!/usr/bin/env bash
# alias-advisor: analyze shell history and suggest aliases interactively.
# All logic runs inside a Docker container — zero host dependencies.

set -euo pipefail

IMAGE="local/alias-advisor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
DOCKERFILE="${SCRIPT_DIR}/docker/Dockerfile"

DEFAULT_BASH="${HOME}/.bash_history"
DEFAULT_ZSH="${HOME}/.zsh_history"
DEFAULT_FISH="${HOME}/.local/share/fish/fish_history"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Analyze shell history and suggest aliases interactively.

History sources (local - full weight):
  --bash-history FILE    Bash history file (default: ~/.bash_history if present)
  --zsh-history  FILE    Zsh history file  (default: ~/.zsh_history if present)
  --fish-history FILE    Fish history file (default: ~/.local/share/fish/fish_history if present)

History sources (imported - 50% weight):
  --extra-bash FILE      Imported bash history from another machine
  --extra-zsh  FILE      Imported zsh history from another machine
  --extra-fish FILE      Imported fish history from another machine

Filtering:
  --alias-files FILE     Shell config file(s) to scan for existing aliases (skip duplicates)
  --top N                Max suggestions to show (default: 30)
  --min-count N          Min occurrences required (default: 5)
  --min-tokens N         Min tokens in pattern (default: 2)

Output:
  --output-dir DIR       Staging output directory (default: ./output)
  --append-bash FILE     Append accepted aliases directly to this bash config file
  --append-fish FILE     Append accepted abbrs directly to this fish config file

Other:
  --rebuild              Force rebuild the Docker image
  --json                 Dump suggestions as JSON and exit (no TUI)
  -h, --help             Show this help

Examples:
  # Basic - auto-detects local history
  $(basename "$0")

  # Write directly to bashrc
  $(basename "$0") --append-bash ~/.bashrc

  # Merge local + imported, skip existing aliases
  $(basename "$0") --extra-bash ~/imported/server_bash_history \\
                   --extra-zsh  ~/imported/server_zsh_history  \\
                   --alias-files ~/.bashrc ~/.bash_aliases

  # Only suggest commands seen 10+ times with 3+ tokens
  $(basename "$0") --min-count 10 --min-tokens 3

USAGE
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

REBUILD=0
ANALYZER_ARGS=()
TUI_ARGS=()
MOUNTS=()

add_mount_arg() {
  local host_path="$1"
  local flag="$2"
  local target="$3"  # "analyzer" or "tui"
  local container_path="/hist/$(basename "$host_path")-$$-${#MOUNTS[@]}"

  if [[ ! -f "$host_path" ]]; then
    echo "[warn] file not found, skipping: $host_path" >&2
    return
  fi

  MOUNTS+=("-v" "${host_path}:${container_path}:ro")
  if [[ "$target" == "tui" ]]; then
    TUI_ARGS+=("$flag" "$container_path")
  else
    ANALYZER_ARGS+=("$flag" "$container_path")
  fi
}

add_mount_rw_arg() {
  local host_path="$1"
  local flag="$2"
  local container_path="/cfg/$(basename "$host_path")-$$"

  if [[ ! -f "$host_path" ]]; then
    echo "[warn] append target not found, skipping: $host_path" >&2
    return
  fi

  MOUNTS+=("-v" "${host_path}:${container_path}:rw")
  TUI_ARGS+=("$flag" "$container_path")
}

has_analyzer_flag() {
  local f="$1"
  for a in "${ANALYZER_ARGS[@]:-}"; do [[ "$a" == "$f" ]] && return 0; done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bash-history)  add_mount_arg "$2" "--bash-history" analyzer; shift 2 ;;
    --zsh-history)   add_mount_arg "$2" "--zsh-history"  analyzer; shift 2 ;;
    --fish-history)  add_mount_arg "$2" "--fish-history" analyzer; shift 2 ;;
    --extra-bash)    add_mount_arg "$2" "--extra-bash"   analyzer; shift 2 ;;
    --extra-zsh)     add_mount_arg "$2" "--extra-zsh"    analyzer; shift 2 ;;
    --extra-fish)    add_mount_arg "$2" "--extra-fish"   analyzer; shift 2 ;;
    --alias-files)   add_mount_arg "$2" "--alias-files"  analyzer; shift 2 ;;
    --append-bash)   add_mount_rw_arg "$2" "--append-bash";        shift 2 ;;
    --append-fish)   add_mount_rw_arg "$2" "--append-fish";        shift 2 ;;
    --top)           ANALYZER_ARGS+=("--top"        "$2");         shift 2 ;;
    --min-count)     ANALYZER_ARGS+=("--min-count"  "$2");         shift 2 ;;
    --min-tokens)    ANALYZER_ARGS+=("--min-tokens" "$2");         shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2";                              shift 2 ;;
    --rebuild)       REBUILD=1;                                    shift   ;;
    --json)          ANALYZER_ARGS+=("--json");                    shift   ;;
    -h|--help)       usage ;;
    *) echo "[error] unknown option: $1" >&2; usage ;;
  esac
done

# Auto-detect local history files if none specified
if ! has_analyzer_flag "--bash-history" && ! has_analyzer_flag "--extra-bash"; then
  [[ -f "$DEFAULT_BASH" ]] && add_mount_arg "$DEFAULT_BASH" "--bash-history" analyzer || true
fi

if ! has_analyzer_flag "--zsh-history" && ! has_analyzer_flag "--extra-zsh"; then
  [[ -f "$DEFAULT_ZSH" ]] && add_mount_arg "$DEFAULT_ZSH" "--zsh-history" analyzer || true
fi

if ! has_analyzer_flag "--fish-history" && ! has_analyzer_flag "--extra-fish"; then
  [[ -f "$DEFAULT_FISH" ]] && add_mount_arg "$DEFAULT_FISH" "--fish-history" analyzer || true
fi

if [[ ${#ANALYZER_ARGS[@]} -eq 0 ]]; then
  echo "[error] No history files found. Pass --bash-history, --zsh-history, or --fish-history." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build image
# ---------------------------------------------------------------------------

needs_build() {
  [[ "$REBUILD" -eq 1 ]] && return 0
  docker image inspect "$IMAGE" &>/dev/null || return 0
  return 1
}

if needs_build; then
  echo "[info] Building container image..."
  docker build -t "$IMAGE" -f "$DOCKERFILE" "${SCRIPT_DIR}"
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

mkdir -p "$OUTPUT_DIR"

if has_analyzer_flag "--json"; then
  docker run --rm \
    "${MOUNTS[@]}" \
    "$IMAGE" \
    "${ANALYZER_ARGS[@]}"
  exit 0
fi

docker run --rm -it \
  "${MOUNTS[@]}" \
  -v "${OUTPUT_DIR}:/output" \
  "$IMAGE" \
  "${ANALYZER_ARGS[@]}" \
  "${TUI_ARGS[@]}"
