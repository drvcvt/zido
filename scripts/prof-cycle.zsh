#!/usr/bin/env zsh
# Measures cycling latency: wall-clock per C-x plus zprof hotspots, driven
# through a zpty session. Run: zsh scripts/prof-cycle.zsh

emulate -L zsh
zmodload zsh/zpty || exit 1

wrap=/tmp/zido-prof-wrap.zsh
times=/tmp/zido-prof-times.txt
prof=/tmp/zido-prof-zprof.txt
rm -f $times $prof

cat > $wrap <<'EOF'
zmodload zsh/zprof zsh/datetime
functions[_zido_next_orig]=$functions[_zido_next]
_zido_next() {
    local -F t0=$EPOCHREALTIME
    _zido_next_orig
    print -r -- $(( (EPOCHREALTIME - t0) * 1000 )) >>| /tmp/zido-prof-times.txt
}
EOF

zpty zsess env ZIDO_NO_RECORD=1 zsh -i || exit 1
sleep 1.2
zpty -w zsess "source $wrap"
sleep 0.8

zpty -n -w zsess "git ch"
sleep 1
local -i i
for i in {1..10}; do
    zpty -n -w zsess $'\x18'
    sleep 0.15
done
sleep 0.5
zpty -n -w zsess $'\x03'
sleep 0.4
zpty -w zsess "zprof | head -16 >| $prof"
sleep 0.8
zpty -d zsess

print "=== ms per C-x (widget body only) ==="
cat $times 2>/dev/null || print "no data"
print "=== zprof top ==="
cat $prof 2>/dev/null || print "no data"
