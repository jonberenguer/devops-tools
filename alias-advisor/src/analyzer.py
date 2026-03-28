#!/usr/bin/env python3
"""
alias-advisor: Analyze shell history and suggest aliases.
"""

import re
import sys
import math
import time
import argparse
from pathlib import Path
from collections import defaultdict
from dataclasses import dataclass
from typing import Optional


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class HistoryEntry:
    command: str
    timestamp: Optional[float] = None  # unix epoch, may be None
    imported: bool = False             # True = came from --extra-* (remote machine)


@dataclass
class PatternResult:
    pattern: str
    examples: list
    raw_score: float
    alias_name: str
    count: int


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def parse_bash_history(path: Path, imported: bool = False) -> list:
    """
    Supports plain bash history and HISTTIMEFORMAT-stamped history.
    Stamped lines look like: #1700000000
    Also handles zsh extended_history format: ': 1700000000:0;command'
    """
    entries = []
    current_ts = None
    try:
        text = path.read_text(errors="replace")
    except OSError as e:
        print(f"[warn] cannot read {path}: {e}", file=sys.stderr)
        return entries

    for line in text.splitlines():
        line = line.rstrip()
        if not line:
            continue
        # bash timestamp marker
        if line.startswith("#") and line[1:].isdigit():
            current_ts = float(line[1:])
            continue
        entries.append(HistoryEntry(command=line, timestamp=current_ts, imported=imported))
        current_ts = None
    return entries


def parse_zsh_history(path: Path, imported: bool = False) -> list:
    """
    Handles both plain zsh history and extended_history format:
      : 1700000000:0;git status
    Plain lines are treated as commands with no timestamp.
    """
    entries = []
    try:
        text = path.read_text(errors="replace")
    except OSError as e:
        print(f"[warn] cannot read {path}: {e}", file=sys.stderr)
        return entries

    extended_re = re.compile(r"^:\s*(\d+):\d+;(.*)$")

    for line in text.splitlines():
        line = line.rstrip()
        if not line:
            continue
        m = extended_re.match(line)
        if m:
            ts = float(m.group(1))
            cmd = m.group(2)
        else:
            ts = None
            cmd = line
        entries.append(HistoryEntry(command=cmd, timestamp=ts, imported=imported))
    return entries


def parse_fish_history(path: Path, imported: bool = False) -> list:
    """
    Fish history format:
      - cmd: git status
        when: 1700000000
    """
    entries = []
    try:
        text = path.read_text(errors="replace")
    except OSError as e:
        print(f"[warn] cannot read {path}: {e}", file=sys.stderr)
        return entries

    current_cmd = None
    current_ts = None

    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("- cmd:"):
            if current_cmd:
                entries.append(HistoryEntry(command=current_cmd, timestamp=current_ts, imported=imported))
            current_cmd = stripped[len("- cmd:"):].strip()
            current_ts = None
        elif stripped.startswith("when:"):
            try:
                current_ts = float(stripped[len("when:"):].strip())
            except ValueError:
                current_ts = None

    if current_cmd:
        entries.append(HistoryEntry(command=current_cmd, timestamp=current_ts, imported=imported))

    return entries


# ---------------------------------------------------------------------------
# Pattern extraction
# ---------------------------------------------------------------------------

_VARIABLE_RE = re.compile(
    r"^("
    r"/"                                      # absolute path
    r"|\.{0,2}/"                              # relative path
    r"|https?://"                             # URL
    r"|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"  # IP
    r"|[0-9a-f]{7,40}"                        # git SHA
    r"|\d+$"                                  # plain number
    r"|.*\.(py|sh|js|ts|go|rb|yaml|yml|json|toml|conf|cfg|log|txt|md|csv)$"
    r")"
)

_QUOTED_RE = re.compile(r'^["\'].*["\']$')


def is_variable_token(tok: str) -> bool:
    return bool(_VARIABLE_RE.match(tok) or _QUOTED_RE.match(tok))


def extract_pattern(command: str, min_tokens: int = 2) -> Optional[str]:
    command = command.strip()
    if not command or command.startswith("#"):
        return None

    first_seg = re.split(r"\s*[|;&]\s*", command)[0].strip()
    tokens = first_seg.split()
    if not tokens:
        return None

    # Strip leading env vars
    while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
        tokens = tokens[1:]
    if not tokens:
        return None

    kept = []
    for tok in tokens:
        if is_variable_token(tok) and len(kept) >= 2:
            break
        kept.append(tok)

    if len(kept) < min_tokens:
        return None

    return " ".join(kept)


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

NOW = time.time()
HALF_LIFE_DAYS = 30.0
HALF_LIFE_SECS = HALF_LIFE_DAYS * 86400
IMPORT_DISCOUNT = 0.5  # imported history counts at 50% weight


def recency_weight(ts: Optional[float], imported: bool) -> float:
    if ts is None:
        base = 0.5
    else:
        age = max(0.0, NOW - ts)
        base = math.exp(-math.log(2) * age / HALF_LIFE_SECS)
    return base * (IMPORT_DISCOUNT if imported else 1.0)


def score_entries(entries: list, min_count: int = 5, min_tokens: int = 2) -> list:
    pattern_scores: dict = defaultdict(float)
    pattern_counts: dict = defaultdict(int)
    pattern_examples: dict = defaultdict(list)

    for entry in entries:
        pat = extract_pattern(entry.command, min_tokens=min_tokens)
        if pat is None:
            continue
        w = recency_weight(entry.timestamp, entry.imported)
        pattern_scores[pat] += w
        pattern_counts[pat] += 1
        if entry.command not in pattern_examples[pat] and len(pattern_examples[pat]) < 3:
            pattern_examples[pat].append(entry.command)

    results = []
    for pat, score in pattern_scores.items():
        count = pattern_counts[pat]
        if count < min_count:
            continue
        results.append(PatternResult(
            pattern=pat,
            examples=pattern_examples[pat],
            raw_score=score,
            alias_name=generate_alias_name(pat),
            count=count,
        ))

    results.sort(key=lambda r: r.raw_score, reverse=True)
    return results


# ---------------------------------------------------------------------------
# Alias name generation
# ---------------------------------------------------------------------------

def generate_alias_name(pattern: str) -> str:
    tokens = pattern.split()
    parts = []
    for tok in tokens:
        if tok.startswith("-"):
            letters = re.sub(r"[^a-z]", "", tok.lower())
            if letters:
                parts.append(letters[:3])
        else:
            clean = re.sub(r"[^a-z0-9]", "", tok.lower())
            if clean:
                parts.append(clean[:4])

    name = "".join(parts)
    if name and name[0].isdigit():
        name = "a" + name
    return name or "alias"


# ---------------------------------------------------------------------------
# Existing alias detection
# ---------------------------------------------------------------------------

def load_existing_aliases(paths: list) -> set:
    aliases = set()
    alias_re = re.compile(r"^\s*alias\s+([A-Za-z0-9_\-]+)\s*=")
    abbr_re  = re.compile(r"^\s*abbr\s+(?:--add\s+|-a\s+)?([A-Za-z0-9_\-]+)")

    for p in paths:
        if not p.exists():
            continue
        try:
            for line in p.read_text(errors="replace").splitlines():
                m = alias_re.match(line) or abbr_re.match(line)
                if m:
                    aliases.add(m.group(1))
        except OSError:
            pass
    return aliases


# ---------------------------------------------------------------------------
# History loading
# ---------------------------------------------------------------------------

def load_history(args) -> list:
    entries = []

    def load(paths, parser, label, imported):
        for p in (paths or []):
            loaded = parser(Path(p), imported=imported)
            print(f"[info] {p}: {len(loaded)} {label} entries", file=sys.stderr)
            entries.extend(loaded)

    load(args.bash_history, parse_bash_history, "bash",   imported=False)
    load(args.zsh_history,  parse_zsh_history,  "zsh",    imported=False)
    load(args.fish_history, parse_fish_history, "fish",   imported=False)
    load(args.extra_bash,   parse_bash_history, "bash",   imported=True)
    load(args.extra_zsh,    parse_zsh_history,  "zsh",    imported=True)
    load(args.extra_fish,   parse_fish_history, "fish",   imported=True)

    if not entries:
        print("[error] No history entries found.", file=sys.stderr)
        sys.exit(1)

    return entries


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Analyze shell history and suggest aliases.")
    # Local history
    parser.add_argument("--bash-history", nargs="+", metavar="FILE")
    parser.add_argument("--zsh-history",  nargs="+", metavar="FILE",
                        help="Zsh history file (plain or extended_history format)")
    parser.add_argument("--fish-history", nargs="+", metavar="FILE")
    # Imported history (discounted)
    parser.add_argument("--extra-bash", nargs="+", metavar="FILE",
                        help="Imported bash history (weighted at 50%%)")
    parser.add_argument("--extra-zsh",  nargs="+", metavar="FILE",
                        help="Imported zsh history (weighted at 50%%)")
    parser.add_argument("--extra-fish", nargs="+", metavar="FILE",
                        help="Imported fish history (weighted at 50%%)")
    # Config
    parser.add_argument("--alias-files", nargs="+", metavar="FILE",
                        help="Shell config files to scan for existing aliases")
    parser.add_argument("--top",        type=int, default=30)
    parser.add_argument("--min-count",  type=int, default=5)
    parser.add_argument("--min-tokens", type=int, default=2,
                        help="Minimum tokens in a pattern to be considered (default: 2)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    # Auto-detect common history file locations if nothing specified
    defaults = [
        ("bash_history", Path.home() / ".bash_history",                          parse_bash_history),
        ("zsh_history",  Path.home() / ".zsh_history",                           parse_zsh_history),
        ("fish_history", Path.home() / ".local/share/fish/fish_history",         parse_fish_history),
    ]
    for attr, default_path, _ in defaults:
        if not getattr(args, attr) and default_path.exists():
            setattr(args, attr, [str(default_path)])

    # Ensure extra_* attrs exist
    for attr in ("extra_bash", "extra_zsh", "extra_fish"):
        if not hasattr(args, attr):
            setattr(args, attr, None)

    entries  = load_history(args)
    existing = load_existing_aliases([Path(p) for p in (args.alias_files or [])])
    results  = score_entries(entries, min_count=args.min_count, min_tokens=args.min_tokens)

    # Filter already-aliased patterns
    results = [r for r in results if r.alias_name not in existing]
    results = results[:args.top]

    import json

    if args.json:
        print(json.dumps([
            {
                "pattern":  r.pattern,
                "alias":    r.alias_name,
                "count":    r.count,
                "score":    round(r.raw_score, 2),
                "examples": r.examples,
            }
            for r in results
        ], indent=2))
        return

    # NDJSON for TUI
    for r in results:
        print(json.dumps({
            "pattern":  r.pattern,
            "alias":    r.alias_name,
            "count":    r.count,
            "score":    round(r.raw_score, 2),
            "examples": r.examples,
        }))


if __name__ == "__main__":
    main()
