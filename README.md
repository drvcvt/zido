# klammer

ido-style inline completion and history for the shell. While you type,
candidates appear inline after the cursor, Emacs-ido style:

```
λ git ch{checkout | cherry-pick | check-ignore | …+3}
λ git chec[checkout]
λ git xyz [No match]
```

One Rust daemon (own sqlite history with cwd/exit/duration context, nucleo
fuzzy matching, frecency ranking) plus thin shell frontends. Replaces
zsh-autosuggestions, fzf-tab, atuin's UI and history-substring-search.

## Install

```sh
cargo build --release
ln -sf "$PWD/target/release/klammer" ~/.local/bin/klammer
klammer import                      # one-time: atuin db + .zsh_history
echo 'eval "$(klammer init zsh)"' >> ~/.zshrc
```

The daemon starts automatically on first prompt.

## Keys

| Key       | Action |
|-----------|--------|
| Tab       | accept first candidate |
| C-x / C-z | rotate candidates |
| ↑ / ↓     | cycle history-line candidates |
| RET       | execute the literal buffer (candidates never auto-accepted) |
| C-g       | dismiss until next edit |

Design: `docs/DESIGN.md`.
