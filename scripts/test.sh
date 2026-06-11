#!/usr/bin/env zsh
set -e
cd "${0:a:h}/.."
cargo test --quiet
zsh scripts/zle-test.zsh
