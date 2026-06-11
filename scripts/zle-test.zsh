#!/usr/bin/env zsh
# Integration tests for the zle frontend. Drives a real interactive zsh in a
# zpty and asserts on BUFFER/CURSOR/POSTDISPLAY via a dump widget bound to ^T
# inside the test session (no ANSI scraping). Requires the klammer binary in
# PATH; spawns the daemon if needed. Run: zsh scripts/zle-test.zsh

emulate -L zsh
zmodload zsh/zpty || { print "zpty unavailable"; exit 1 }

typeset -gi pass=0 fail=0
typeset -g state=/tmp/klammer-zletest.$$

cleanup() {
    zpty -d klam 2>/dev/null
    rm -f $state
}
trap cleanup EXIT

send() { zpty -n -w klam "$1" }
drain() { local c; while zpty -r -t klam c 2>/dev/null; do :; done }

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

zpty klam env KLAMMER_NO_RECORD=1 zsh -i || { print "cannot spawn zsh"; exit 1 }
sleep 1.5
drain
send '_kt() { { print -r -- "BUF=$BUFFER"; print -r -- "CUR=$CURSOR"; print -r -- "PD=$POSTDISPLAY"; print -r -- "SEL=$_klammer_sel"; print -r -- "OFF=$_klammer_off"; print -r -- "C1=${_klammer_cands[1]}" } >| '$state' }; zle -N _kt; bindkey "^T" _kt'
send $'\r'
sleep 0.8
drain

# ---- tests --------------------------------------------------------------------

# T1: braces render while typing, best candidate first
send 'git ch'; sleep 1.0
dump && {
    check "T1-braces-render" ' {*|*}' "$(field PD)"
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
send 'echo klamtest-literal'; sleep 0.8
send $'\r'; sleep 0.8
out=""
while zpty -r -t klam c 2>/dev/null; do out+=$c; done
clean=$(print -r -- "$out" | sed -e $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' -e $'s/\r//g')
if [[ $clean == *"klamtest-literal"* ]]; then
    (( pass++ )); print "PASS T9-ret-literal"
else
    (( fail++ )); print "FAIL T9-ret-literal: output was '$clean'"
fi

# ---- report --------------------------------------------------------------------

print "----"
print "$pass passed, $fail failed"
(( fail == 0 ))
