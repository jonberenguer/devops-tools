#!/usr/bin/env python3
"""
Interactive review for alias suggestions.
Works over any terminal - no curses, no /dev/tty requirement.
"""

import json
import os
import re
import sys
from dataclasses import dataclass


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

@dataclass
class Suggestion:
    pattern: str
    alias: str
    count: int
    score: float
    examples: list
    decision: str = "pending"
    final_alias: str = ""

    def __post_init__(self):
        if not self.final_alias:
            self.final_alias = self.alias


def load_suggestions(path: str) -> list:
    suggestions = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                suggestions.append(Suggestion(
                    pattern=d["pattern"],
                    alias=d["alias"],
                    count=d["count"],
                    score=d["score"],
                    examples=d.get("examples", []),
                ))
            except (json.JSONDecodeError, KeyError):
                pass
    return suggestions


# ---------------------------------------------------------------------------
# ANSI helpers
# ---------------------------------------------------------------------------

RESET   = "\033[0m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
GREEN   = "\033[32m"
RED     = "\033[31m"
YELLOW  = "\033[33m"
CYAN    = "\033[36m"
MAGENTA = "\033[35m"


def c(code, text):
    return f"{code}{text}{RESET}"


def clear():
    print("\033[2J\033[H", end="", flush=True)


def print_suggestion(s: Suggestion, idx: int, total: int):
    clear()

    pct = int(100 * idx / max(total, 1))
    bar_width = 40
    filled = int(bar_width * idx / max(total, 1))
    bar = "█" * filled + "░" * (bar_width - filled)
    print(c(CYAN + BOLD, f" alias-advisor  [{idx}/{total}]  {pct}%"))
    print(c(DIM, f" {bar}"))
    print()

    print(c(BOLD, "  alias   ") + c(YELLOW + BOLD, s.final_alias))
    print(c(BOLD, "  pattern ") + s.pattern)
    print(c(BOLD, "  count   ") + str(s.count) + c(DIM, f"  (weighted score: {s.score:.1f})"))
    if s.examples:
        print(c(BOLD, "  examples"))
        for ex in s.examples[:3]:
            print(c(DIM, "    $ ") + ex)
    print()

    print(c(CYAN, "  [a]") + " accept    " +
          c(CYAN, "[s]") + " skip    " +
          c(CYAN, "[e]") + " edit name    " +
          c(CYAN, "[b]") + " back    " +
          c(CYAN, "[q]") + " quit & save")
    print()
    print("  > ", end="", flush=True)


def prompt_edit(current_name: str) -> str:
    print(f"\n  Current name: {c(YELLOW, current_name)}")
    print("  New name (enter to keep): ", end="", flush=True)
    try:
        val = input().strip()
    except EOFError:
        return current_name
    if not val:
        return current_name
    val = re.sub(r"[^a-zA-Z0-9_\-]", "", val)
    return val if val else current_name


# ---------------------------------------------------------------------------
# Main review loop
# ---------------------------------------------------------------------------

def run_review(suggestions: list) -> list:
    total = len(suggestions)
    idx = 0

    while idx < total:
        s = suggestions[idx]
        print_suggestion(s, idx + 1, total)

        try:
            key = input().strip().lower()
        except EOFError:
            break

        if key in ("a", ""):
            s.decision = "accept"
            idx += 1
        elif key in ("s", " "):
            s.decision = "skip"
            idx += 1
        elif key == "e":
            s.final_alias = prompt_edit(s.final_alias)
            s.decision = "accept"
            idx += 1
        elif key == "b":
            if idx > 0:
                idx -= 1
                suggestions[idx].decision = "pending"
        elif key == "q":
            break

    return suggestions


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def append_to_file(path: str, lines: list, header: str):
    """Append alias lines to an existing shell config file."""
    with open(path, "a") as f:
        f.write(f"\n# alias-advisor additions\n")
        for line in lines:
            f.write(line + "\n")
    print(f"  appended {len(lines)} lines → {path}")


def write_output(suggestions: list, output_dir: str,
                 append_bash: str = None, append_fish: str = None):
    accepted = [s for s in suggestions if s.decision == "accept"]

    if not accepted:
        print("\n  No aliases accepted.\n")
        return

    clear()
    print(c(GREEN + BOLD, f"\n  ✓ {len(accepted)} aliases accepted\n"))

    bash_lines = [f"alias {s.final_alias}='{s.pattern}'" for s in accepted]
    fish_lines = [f"abbr --add {s.final_alias} '{s.pattern}'" for s in accepted]

    # Direct append mode
    if append_bash:
        append_to_file(append_bash, bash_lines, "alias-advisor")
        print(c(DIM, f"  To reload: source {append_bash}"))
    if append_fish:
        append_to_file(append_fish, fish_lines, "alias-advisor")
        print(c(DIM, f"  To reload: source {append_fish}"))

    # Always write staging files too
    os.makedirs(output_dir, exist_ok=True)
    bash_path = os.path.join(output_dir, "suggested_aliases.bash")
    fish_path = os.path.join(output_dir, "suggested_aliases.fish")

    with open(bash_path, "w") as f:
        f.write("# Generated by alias-advisor\n# Add to ~/.bashrc or ~/.bash_aliases\n\n")
        for line in bash_lines:
            f.write(line + "\n")

    with open(fish_path, "w") as f:
        f.write("# Generated by alias-advisor\n# Source or add to ~/.config/fish/config.fish\n\n")
        for line in fish_lines:
            f.write(line + "\n")

    if not append_bash and not append_fish:
        print(f"  bash → {bash_path}")
        print(f"  fish → {fish_path}")
        print()
        print(c(DIM, "  To apply (bash):  source /output/suggested_aliases.bash"))
        print(c(DIM, "  To apply (fish):  source /output/suggested_aliases.fish"))
    else:
        print()
        print(f"  Staging files also written to {output_dir}/")

    print()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("suggestions_file")
    parser.add_argument("--output-dir",   default="/output")
    parser.add_argument("--append-bash",  metavar="FILE",
                        help="Append accepted aliases directly to this bash config file")
    parser.add_argument("--append-fish",  metavar="FILE",
                        help="Append accepted abbrs directly to this fish config file")
    args = parser.parse_args()

    suggestions = load_suggestions(args.suggestions_file)
    if not suggestions:
        print("No suggestions to review.")
        sys.exit(0)

    final = run_review(suggestions)
    write_output(final, args.output_dir,
                 append_bash=args.append_bash,
                 append_fish=args.append_fish)


if __name__ == "__main__":
    main()
