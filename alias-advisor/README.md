# alias-advisor

Analyze bash, zsh, and fish shell history to suggest aliases, ranked by
frequency and recency. Everything runs inside a Docker container — no host
dependencies beyond Docker itself.

## Requirements

- Docker

## Quick start

```bash
chmod +x alias-advisor.sh
./alias-advisor.sh
```

Auto-detects `~/.bash_history`, `~/.zsh_history`, and
`~/.local/share/fish/fish_history` if present.

## TUI controls

| Key         | Action                        |
|-------------|-------------------------------|
| `a` / Enter | Accept suggestion             |
| `s` / Space | Skip suggestion               |
| `e`         | Edit alias name, then accept  |
| `b`         | Go back, reset decision       |
| `q`         | Quit and write output         |

## Output

After quitting the TUI, two staging files are written to `./output/`
(or `--output-dir`):

- `suggested_aliases.bash` — `alias foo='...'` lines for bash/zsh
- `suggested_aliases.fish` — `abbr --add foo '...'` lines for fish

**To apply (bash/zsh):**
```bash
source ~/alias-advisor/output/suggested_aliases.bash
# or append permanently:
cat ~/alias-advisor/output/suggested_aliases.bash >> ~/.bashrc
```

**To apply (fish):**
```bash
source ~/alias-advisor/output/suggested_aliases.fish
# abbr changes persist in fish automatically after sourcing
```

**Or write directly during the session** using `--append-bash` /
`--append-fish` — accepted aliases are appended to your config file
immediately when you quit the TUI (staging files are still written too):

```bash
./alias-advisor.sh --append-bash ~/.bashrc
./alias-advisor.sh --append-fish ~/.config/fish/config.fish
```

## Cross-machine import

Copy history files from another machine and pass them via `--extra-*`.
Imported history is weighted at 50% relative to local history, so your
current machine's patterns take precedence.

```bash
# Single imported file
./alias-advisor.sh --extra-bash ~/imported/server_bash_history

# Merge all shells, local + remote
./alias-advisor.sh \
  --extra-bash ~/imported/server_bash_history \
  --extra-zsh  ~/imported/server_zsh_history  \
  --extra-fish ~/imported/server_fish_history
```

Source files are always volume-mounted read-only — they are never modified.

## All options

```
History sources (local - full weight):
  --bash-history FILE    Bash history (default: ~/.bash_history)
  --zsh-history  FILE    Zsh history  (default: ~/.zsh_history)
  --fish-history FILE    Fish history (default: ~/.local/share/fish/fish_history)

History sources (imported - 50% weight):
  --extra-bash FILE      Imported bash history from another machine
  --extra-zsh  FILE      Imported zsh history from another machine
  --extra-fish FILE      Imported fish history from another machine

Filtering:
  --alias-files FILE     Shell config(s) to scan for existing aliases (skip duplicates)
  --top N                Max suggestions to show (default: 30)
  --min-count N          Min occurrences required (default: 5)
  --min-tokens N         Min tokens in a pattern (default: 2)

Output:
  --output-dir DIR       Staging output directory (default: ./output)
  --append-bash FILE     Append accepted aliases directly to this bash config file
  --append-fish FILE     Append accepted abbrs directly to this fish config file

Other:
  --rebuild              Force rebuild the Docker image
  --json                 Dump ranked suggestions as JSON and exit (no TUI)
  -h, --help             Show help
```

## How scoring works

Each command occurrence is weighted by recency using exponential decay with a
30-day half-life — a command run today scores twice as high as the same command
run 30 days ago. Patterns seen fewer than `--min-count` times are excluded.

Imported history (`--extra-*`) is additionally discounted to 50% so your local
machine's habits dominate the rankings.

Variable arguments (file paths, git SHAs, IPs, quoted strings, numbers) are
stripped before pattern matching, so `git commit -m "foo"` and
`git commit -m "bar"` both collapse to the pattern `git commit -m`.

Use `--min-tokens` to raise the bar — `--min-tokens 3` means a pattern must
have at least 3 tokens (e.g. `docker compose up`) to qualify, filtering out
two-word patterns like `git status` that may not need an alias.
