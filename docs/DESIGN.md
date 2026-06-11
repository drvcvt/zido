# zido — ido-style inline completion for the shell

One system replacing zsh-autosuggestions, fzf-tab, atuin's UI and
history-substring-search: while you type, candidates appear inline after the
cursor in Emacs-ido style.

## The identity (non-negotiable)

```
λ git ch{checkout | cherry-pick | check-ignore | …+3}     multiple matches
λ git chec[checkout]                                      exactly one match
λ git xyz [No match]                                      nothing (red)
λ git checkout {main | feature/sdf | -b | --track}        next-word prediction
```

ido semantics carried over exactly: curly braces = selection open, square
brackets = unique match, red `[No match]` as instant typo feedback. The first
candidate is bold/accented — that is what Tab takes. Sources are colour-coded
(history / completion / file). Display is width-bounded with `…+N` overflow;
long history lines get middle-elision.

## Keys

| Key       | Action |
|-----------|--------|
| Tab       | accept first candidate into the buffer (then narrowing continues) |
| C-x / C-z | rotate candidates forward / backward |
| ↑ / ↓     | cycle history-line candidates (whole line into buffer) |
| RET       | always executes the literal buffer — braces are display-only |
| C-g       | dismiss display until next edit |

C-z costs nothing at the prompt (SIGTSTP only matters for running programs,
which keep working). C-x's prefix map is unused in this config. C-s/C-r were
rejected (flow control / isearch collisions).

## Architecture

```
zido (one Rust binary)
├── daemon: unix socket at $XDG_RUNTIME_DIR/zido.sock, line protocol
├── matcher: nucleo (helix's fzf-style matcher)
├── ranking: match quality × source bonus × frecency × cwd context
└── history recorder → own sqlite (cmd, cwd, exit, duration, ts, session)

zsh frontend (zle, first-class)      bash frontend (ble.sh, phase 3)
```

Per keystroke: zle-line-pre-redraw hook → query (buffer, cursor, cwd) over the
socket → async response via `zle -F` fd handler → POSTDISPLAY + region_highlight
updated. Never blocks the input path; stale responses (id mismatch) dropped.

### Candidate sources

- **history**: own sqlite, fed by preexec/precmd hooks. One-time import from
  atuin's DB and `.zsh_history`. Word tokens, next-token prediction (n-gram
  over lines with matching prefix) and whole-line candidates.
- **compsys** (phase 2): captured async by the zsh frontend (zpty trick like
  zsh-autosuggestions), cached per candidate set, shipped to the daemon for
  matching/ranking only.
- **files/dirs**: daemon scans cwd / the path prefix in the current word.
- **PATH executables**: scanned at daemon start, for first-word position.

### Ranking

score = nucleo match quality (prefix > fuzzy, shorter > longer)
      + frecency (ln(1+count) · 0.5^(age_days/30))
      + cwd bonus (token seen in this directory)
      + same-command bonus (token seen in lines with the same first word)
      − failure penalty (lines that usually exit non-zero rank down)

### Protocol (line-based, tab-separated, \x1f/\x1e list separators)

- `Q <id> <cols> <cursor> <cwd> <buffer>` → word/auto query
- `L <id> <cwd> <buffer>`                 → history-line candidates (↑/↓)
- `H <exit> <duration_ms> <cwd> <cmd>`    → record, fire-and-forget
- `R <id> <state> <word_start> <total> <text\x1esource\x1f…>` response,
  state ∈ multi|single|none|empty. Offsets are char indices (zsh side is
  char-based). cmd/buffer fields escape `\` `\t` `\n`.

Two connections per shell: one async (Q/R, zle -F), one sync (L, H).

## Decisions log

- All-in-one replacement, not coexistence (user choice).
- Always live while typing, no minimum length, no trigger key.
- Shared Rust core + thin shell frontends; bash via ble.sh later, degraded
  hotkey mode for plain readline.
- Own sqlite history DB (atuin equivalent), not reading atuin's DB.
- Context-aware mixed sources in one ranked list, colour-coded.
- RET never auto-accepts a candidate (safety).

## Phases

1. **The look**: daemon + zsh frontend, sources = history + files + PATH.
   Full brace rendering with all four states, Tab/C-x/C-z/↑↓/RET/C-g.
2. **compsys**: async capture + cache; replaces fzf-tab/autosuggestions fully.
3. **bash**: ble.sh frontend against the same daemon.

## Known risks

- Per-keystroke latency: daemon + async + stale-drop; measure early.
- compsys capture via zpty is the ugliest part — isolated in phase 2.
- zsh-syntax-highlighting also touches region_highlight; we tag our entries
  with `memo=zido` (zsh 5.9) and load before it.
