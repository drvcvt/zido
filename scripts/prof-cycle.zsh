#!/usr/bin/env zsh
# Measures cycling latency: wall-clock per C-x plus zprof hotspots, driven
# through a zpty session. Run: zsh scripts/prof-cycle.zsh

emulate -L zsh
zmodload zsh/zpty || exit 1

wrap=/tmp/klammer-prof-wrap.zsh
times=/tmp/klammer-prof-times.txt
prof=/tmp/klammer-prof-zprof.txt
rm -f $times $prof

cat > $wrap <<'EOF'
zmodload zsh/zprof zsh/datetime
functions[_klammer_next_orig]=$functions[_klammer_next]
_klammer_next() {
    local -F t0=$EPOCHREALTIME
    _klammer_next_orig
    print -r -- $(( (EPOCHREALTIME - t0) * 1000 )) >>| /tmp/klammer-prof-times.txt
}
EOF

zpty klam env KLAMMER_NO_RECORD=1 zsh -i || exit 1
sleep 1.2
zpty -w klam "source $wrap"
sleep 0.8

zpty -n -w klam "git ch"
sleep 1
local -i i
for i in {1..10}; do
    zpty -n -w klam $'\x18'
    sleep 0.15
done
sleep 0.5
zpty -n -w klam $'\x03'
sleep 0.4
zpty -w klam "zprof | head -16 >| $prof"
sleep 0.8
zpty -d klam

print "=== ms per C-x (widget body only) ==="
cat $times 2>/dev/null || print "no data"
print "=== zprof top ==="
cat $prof 2>/dev/null || print "no data"
