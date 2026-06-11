#!/usr/bin/env zsh
# Integration tests for the zle frontend. Drives a real interactive zsh in a
# zpty and asserts on BUFFER/CURSOR/POSTDISPLAY via a dump widget bound to ^T
# inside the test session (no ANSI scraping). Requires the zido binary in
# PATH; spawns the daemon if needed. Run: zsh scripts/zle-test.zsh

emulate -L zsh
zmodload zsh/zpty || { print "zpty unavailable"; exit 1 }

typeset -gi pass=0 fail=0
typeset -g state=/tmp/zido-zletest.$$

cleanup() {
    zpty -d zsess 2>/dev/null
    rm -f $state /tmp/zido-zletest-setup.$$
}
trap cleanup EXIT

send() { zpty -n -w zsess "$1" }
drain() { local c; while zpty -r -t zsess c 2>/dev/null; do :; done }

# Press ^T in the session; the dump widget writes the state file.
dump() {
    rm -f $state
    send $'\x14'
    local -i i
    for i in {1..60}; do
        [[ -s $state ]] && { sleep 0.1; return 0 }
        sleep 0.05
    done
    print "FAIL dump: state file never appeared"
    (( fail++ ))
    return 1
}

field() { local l; l=$(grep -m1 "^$1=" $state); print -r -- "${l#$1=}" }

check() {
    local name=$1 pat=$2 val=$3
    if [[ $val == ${~pat} ]]; then
        (( pass++ )); print "PASS $name"
    else
        (( fail++ )); print "FAIL $name: got '${val}' want pattern '${pat}'"
    fi
}

check_eq() {
    local name=$1 want=$2 got=$3
    if [[ $got == "$want" ]]; then
        (( pass++ )); print "PASS $name"
    else
        (( fail++ )); print "FAIL $name: got '${got}' want '${want}'"
    fi
}

check_ne() {
    local name=$1 a=$2 b=$3
    if [[ $a != $b ]]; then
        (( pass++ )); print "PASS $name"
    else
        (( fail++ )); print "FAIL $name: '$a' should differ from '$b'"
    fi
}

new_line() {
    send $'\x03'      # ^C: abort current line, fresh prompt
    sleep 0.5
    drain
}

# ---- session setup -----------------------------------------------------------

setup=/tmp/zido-zletest-setup.$$
cat > $setup <<EOF
_kt() {
    {
        print -r -- "BUF=\$BUFFER"
        print -r -- "CUR=\$CURSOR"
        print -r -- "PD=\$POSTDISPLAY"
        print -r -- "PDF=\${POSTDISPLAY//\$'\n'/@@}"
        print -r -- "SEL=\$_zido_sel"
        print -r -- "OFF=\$_zido_off"
        print -r -- "MODE=\$_zido_mode"
        print -r -- "C1=\${_zido_cands[1]}"
    } >| $state
}
zle -N _kt
bindkey "^T" _kt
bindkey -M zido-search "^T" _kt 2>/dev/null
_zidotest_completer() { compadd alpha-one alpha-two beta-three }
compdef _zidotest_completer zidotestcmd 2>/dev/null
print KLAMTEST-READY
EOF

zpty zsess env ZIDO_NO_RECORD=1 zsh -i || { print "cannot spawn zsh"; exit 1 }
sleep 1.5
drain
send "source $setup"
send $'\r'
# wait for the marker so tests never start against a half-initialised session
ready=0
for i in {1..60}; do
    if zpty -r -t zsess c 2>/dev/null && [[ $c == *KLAMTEST-READY* ]]; then
        ready=1; break
    fi
    sleep 0.1
done
(( ready )) || { sleep 1; drain }
drain

# ---- tests --------------------------------------------------------------------

# T1: braces render while typing, best candidate first
send 'git ch'; sleep 1.0
dump && {
    check "T1-braces-render" ' {*\|*}' "$(field PD)"
    check "T1-buffer-intact" 'git ch' "$(field BUF)"
}
typeset -g pd_before=$(field PD)

# T2: ^X moves the selection right (buffer/cursor untouched)
send $'\x18'; sleep 0.4
dump && {
    check "T2-selection-moves" '2' "$(field SEL)"
    check "T2-buffer-untouched" 'git ch' "$(field BUF)"
    check "T2-cursor-untouched" '6' "$(field CUR)"
}

# T3: rapid double ^X must NOT trigger old ^X-prefix combos
# (^X^X = exchange-point-and-mark would warp CURSOR to 0, ^Xu = undo)
send $'\x18\x18'; sleep 0.5
dump && {
    check "T3-selection-at-4" '4' "$(field SEL)"
    check "T3-no-prefix-combo-buffer" 'git ch' "$(field BUF)"
    check "T3-no-cursor-warp" '6' "$(field CUR)"
}

# T4a: selection hits the right edge, then the window scrolls (left … marker
# appears, OFF > 1)
send $'\x18\x18\x18\x18'; sleep 0.6
dump && {
    check "T4a-selection-at-8" '8' "$(field SEL)"
    check "T4a-window-scrolled" '<2->' "$(field OFF)"
    check "T4a-left-ellipsis" ' {… | *' "$(field PD)"
}

# T4b: ^Z walks back to the start, original window restored
send $'\x1a\x1a\x1a\x1a\x1a\x1a\x1a'; sleep 0.8
dump && {
    check "T4b-selection-back" '1' "$(field SEL)"
    check_eq "T4b-window-restored" "$pd_before" "$(field PD)"
}

# T5: Tab accepts the selected candidate (selection is back at 1) + space
send $'\t'; sleep 0.8
dump && check "T5-tab-accepts" 'git checkout ' "$(field BUF)"

# T5b: move selection then Tab — the selected (not the first) candidate lands
dump
typeset -g first_pred=$(field C1)
send $'\x18'; sleep 0.4
send $'\t'; sleep 0.8
dump && {
    check "T5b-accepts-selected" 'git checkout ?*' "$(field BUF)"
    check_ne "T5b-not-first" "$(field BUF)" "git checkout $first_pred "
}

# T6: ^G dismisses the display
send $'\x07'; sleep 0.4
dump && check "T6-dismiss" '' "$(field PD)"

# T7: typing again after dismiss brings the display back
send 'm'; sleep 1.0
dump && check_ne "T7-display-returns" "$(field PD)" ""

# T8: up-arrow pulls a whole history line, down-arrow restores typed input
new_line
send 'cargo b'; sleep 0.8
dump
typeset -g typed=$(field BUF)
send $'\e[A'; sleep 0.8
dump && {
    check "T8-up-pulls-line" 'cargo *' "$(field BUF)"
    check_ne "T8-line-differs" "$(field BUF)" "$typed"
}
send $'\e[B'; sleep 0.6
dump && check "T8-down-restores" 'cargo b' "$(field BUF)"

# T9: RET executes the literal buffer, braces never auto-accepted
new_line
send 'echo zidotest-literal'; sleep 0.8
send $'\r'; sleep 0.8
out=""
while zpty -r -t zsess c 2>/dev/null; do out+=$c; done
clean=$(print -r -- "$out" | sed -e $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' -e $'s/\r//g')
if [[ $clean == *"zidotest-literal"* ]]; then
    (( pass++ )); print "PASS T9-ret-literal"
else
    (( fail++ )); print "FAIL T9-ret-literal: output was '$clean'"
fi

# T11: ^R opens the vertical search list (atuin-style, ido-framed)
new_line
send 'cargo'; sleep 0.6
send $'\x12'; sleep 1.0
dump && {
    check "T11-search-mode" 'search' "$(field MODE)"
    check "T11-vertical-list" '@@{ *' "$(field PDF)"
    check "T11-multiple-rows" '*@@\| *' "$(field PDF)"
    check "T11-query-kept" 'cargo' "$(field BUF)"
}

# T11b: arrow down moves the selection through the lines
send $'\e[B'; sleep 0.4
dump && check "T11b-selection-down" '2' "$(field SEL)"

# T11c: RET accepts the selected line into the buffer and returns to inline
send $'\r'; sleep 0.8
dump && {
    check "T11c-back-inline" 'inline' "$(field MODE)"
    check "T11c-line-accepted" '*cargo*' "$(field BUF)"
}

# T11d: ^G cancels search and restores the typed buffer
new_line
send 'zzqq'; sleep 0.4
send $'\x12'; sleep 0.8
send $'\x07'; sleep 0.4
dump && {
    check "T11d-canceled-inline" 'inline' "$(field MODE)"
    check "T11d-buffer-restored" 'zzqq' "$(field BUF)"
}

# T12: compsys capture — words from zsh's real completion system show up even
# though they were never typed (custom completer, fully deterministic)
new_line
send 'zidotestcmd '; sleep 2.0
send 'al'; sleep 1.5
dump && {
    check "T12-comp-candidates" '*alpha-one*' "$(field PD)"
    check_eq "T12-comp-no-beta" "$(field PD)" "${$(field PD)/beta/XX}"
}

# T10: exactly one ^X binding — any surviving ^X-prefix combo makes zsh wait
# KEYTIMEOUT (~400ms) before dispatching rotation. Runs last because it types
# and executes a real command line in the session.
new_line
rm -f $state
send 'bindkey | grep -c "\"\^X" >| '$state
send $'\r'; sleep 1.0
check "T10-single-xbind" '1' "$(head -1 $state 2>/dev/null | tr -d '[:space:]')"

# ---- report --------------------------------------------------------------------

print "----"
print "$pass passed, $fail failed"
(( fail == 0 ))
