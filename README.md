# zido

**Emacs ido for your shell.** Inline completion, history and search — one
daemon, one aesthetic, zero popups.

While you type, candidates appear right in the line, ido-style:

```
λ git ch{checkout | cherry-pick | check-ignore | …+3}
           ▲ selection block (grey bg) — Tab takes it, C-x/C-z walks it
```

zido replaces zsh-autosuggestions, fzf-tab, atuin's UI and
history-substring-search with a single mechanism: a Rust daemon holding your
history (with cwd, exit code and duration context) and a thin zle frontend
that renders everything inline.

## The look

ido's display states, carried over exactly:

```
λ git ch{checkout | cherry-pick | check-ignore | …+3}     several matches
λ git chec[checkout]                                      exactly one match
λ git xyz [No match]                                      nothing — typo feedback
λ git checkout {main | -b | --track | feature/x}          next-word prediction
λ cd ba{bash-kurs/ | boltsnap/ | binja-re-assist/}        cd offers dirs only
```

Curly braces mean the selection is open, square brackets mean unique, red
`[No match]` flags a typo as you make it. The selected candidate renders as a
block (light grey background); `C-x`/`C-z` walk the block through the list,
at the right edge the window scrolls and eats into the `…+N` overflow.

## Search (Ctrl-R)

`^R` opens history search as a *vertical* ido list — the atuin idea in the
zido identity:

```
λ crgo rel▮
{ cargo run --release
| cargo run --release --example galaxy
| command cargo build --release
| cargo run --release --example forms …+155 }
```

The buffer doubles as the live query. Matched characters are highlighted in
every row, the selection block walks the rows, ranking is context-aware:
commands you ran *in this directory* come first, commands that usually fail
rank down. `RET`/`Tab` puts the selected line into your buffer — it never
executes anything by itself.

## Candidates, ranked like you'd want

One mixed, ranked list per keystroke:

- **history tokens** — frecency-weighted, boosted when seen in this cwd or
  with the same command
- **next-word prediction** — n-grams over your history (`git checkout ` →
  `{main | -b | …}`)
- **whole history lines** — `↑`/`↓` cycles them, `^R` searches them
- **files & dirs** — history tokens naming a real directory complete as
  directories (trailing `/`, no dead space); after `cd` only dirs are offered
- **PATH executables** for the first word

Matching is [nucleo](https://github.com/helix-editor/nucleo) (Helix's
fzf-style matcher). Secret-looking tokens (`TOKEN=…`, long base64 blobs) and
escape-sequence residue are never indexed.

## Keys

| Key       | Action |
|-----------|--------|
| `Tab`     | accept the selected candidate (then narrowing continues) |
| `C-x` / `C-z` | move the selection block right / left |
| `↑` / `↓` | cycle whole history lines |
| `^R`      | search mode (vertical list, live query, match highlighting) |
| `RET`     | **always executes the literal buffer** — candidates are display-only |
| `C-g`     | dismiss until the next edit |

`RET` never auto-accepts a candidate. What you typed is what runs.

## Install

Requires zsh 5.9+ and Rust.

```sh
git clone https://github.com/drvcvt/zido && cd zido
cargo build --release
ln -s "$PWD/target/release/zido" ~/.local/bin/zido

zido import           # one-time: pulls atuin's db and/or ~/.zsh_history
echo 'eval "$(zido init zsh)"' >> ~/.zshrc
```

The daemon starts automatically on the first prompt (unix socket under
`$XDG_RUNTIME_DIR`, sqlite under `~/.local/share/zido/`). New commands are
recorded with cwd, exit code and duration via preexec/precmd hooks.

If you run zsh-autosuggestions, fzf-tab or atuin's shell init, disable them —
zido takes over their jobs (and their keybindings).

## Configuration

Colours live in one association — define it before the eval (or override
single keys after):

```zsh
typeset -gA _zido_color=(
    hist 'fg=3'  exec 'fg=2'  file 'fg=4'  dir 'fg=4,bold'
    line 'fg=3'  frame 'fg=8' nomatch 'fg=1'
    sel 'fg=0,bg=250'  match 'fg=3,bold'  selmatch 'fg=0,bg=250,bold,underline'
)
```

`ZIDO_NO_RECORD=1` disables history recording for a session. `zido gc`
scrubs polluted rows (escape residue) from the db. `zido query "git ch"`
inspects ranking from the command line.

## Architecture

```
zido (one Rust binary)
├── daemon: unix socket, line protocol, in-memory index
├── matcher: nucleo + frecency + cwd/same-command bonuses − failure penalty
├── sqlite: cmd, cwd, exit, duration, ts  (imports atuin / .zsh_history)
└── init zsh: emits the zle frontend (POSTDISPLAY + region_highlight,
    async via zle -F — the input path never blocks)
```

Per keystroke: buffer + cursor + cwd go to the daemon, the ranked reply
renders asynchronously. Stale replies are dropped. Measured end-to-end:
~0.5 ms per interaction.

Tested by a zpty-driven integration suite (`scripts/test.sh`) asserting on
real BUFFER/CURSOR/POSTDISPLAY state — 32 zle checks + 21 unit tests.

## Roadmap

- **compsys capture** — feed zsh's real completions (flags, subcommands)
  through the same ranked display
- **bash frontend** via ble.sh against the same daemon

## License

MIT
