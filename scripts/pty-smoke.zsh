#!/usr/bin/env zsh
# Drives an interactive zsh in a zpty and checks the rendered ido braces.
# Usage: pty-smoke.zsh [input] — default "git ch".

zmodload zsh/zpty || exit 1
input=${1:-"git ch"}

zpty klam zsh -i || exit 1
sleep 1.5
zpty -n -w klam "$input"
sleep 1.5

out=""
while zpty -r -t klam chunk 2>/dev/null; do
    out+=$chunk
done
zpty -d klam

# Strip ANSI escapes, show the last interesting lines.
clean=$(print -r -- "$out" | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b[>=]//g' -e 's/\r//g')
print -r -- "$clean" | grep -v '^[[:space:]]*$' | tail -3
