# zido zsh frontend. Emitted by `zido init zsh`; @ZIDO_BIN@ is
# replaced with the absolute binary path at init time.
# Requires zsh 5.9 (region_highlight memo= field).

[[ -o interactive ]] || return 0
zmodload zsh/net/socket 2>/dev/null || return 0
zmodload zsh/zselect 2>/dev/null
zmodload zsh/datetime 2>/dev/null
zmodload zsh/system 2>/dev/null
zmodload zsh/zpty 2>/dev/null
autoload -Uz add-zle-hook-widget

typeset -g ZIDO_SOCK="${XDG_RUNTIME_DIR:-/tmp}/zido.sock"
typeset -g ZIDO_BIN="@ZIDO_BIN@"

typeset -g _zido_fd="" _zido_fd_sync=""
typeset -gi _zido_id=0 _zido_wstart=0 _zido_total=0
typeset -gi _zido_suppress=0 _zido_inhist=0 _zido_lidx=0
typeset -gi _zido_sel=1 _zido_off=1
typeset -g _zido_state=empty _zido_lastkey="<reset>" _zido_origin=""
typeset -ga _zido_cands _zido_srcs _zido_inds _zido_lines
typeset -g _zido_prompt_w=3
# inline = braces while typing; search = ^R atuin-style vertical list
typeset -g _zido_mode=inline _zido_saved=""
typeset -gi _zido_saved_cur=0 _zido_pending=0

# Colours per source; frame = braces and separators; sel = the selection
# block (light grey background, black text). Define the association before
# sourcing this file (or override single keys after) to customise.
(( ${+_zido_color} )) || typeset -gA _zido_color=(
    hist    'fg=3'
    line    'fg=3'
    exec    'fg=2'
    file    'fg=4'
    dir     'fg=4,bold'
    frame    'fg=8'
    nomatch  'fg=1'
    sel      'fg=0,bg=250'
    match    'fg=3,bold'
    selmatch 'fg=0,bg=250,bold,underline'
    comp     'fg=6'
)

# ----- daemon / connections -------------------------------------------------

# Connect, spawning the daemon if needed; fd lands in REPLY. A stale socket
# file (daemon died) must not block the respawn, so the test is a real
# connect, never just [[ -S ]]. After a failed spawn we back off for 5s —
# otherwise every keystroke would block in the wait loop.
typeset -gF _zido_retry_at=0

_zido_open_conn() {
    zsocket "$ZIDO_SOCK" 2>/dev/null && return 0
    (( EPOCHREALTIME < _zido_retry_at )) && return 1
    # setsid detaches from this terminal: the daemon must survive the shell
    # and must not die from SIGHUP when the pty closes.
    setsid -f "$ZIDO_BIN" daemon </dev/null >>"${TMPDIR:-/tmp}/zido-$UID.log" 2>&1
    local -i i
    for i in {1..100}; do
        zsocket "$ZIDO_SOCK" 2>/dev/null && return 0
        zselect -t 2 2>/dev/null
    done
    _zido_retry_at=$(( EPOCHREALTIME + 5 ))
    return 1
}

_zido_connect() {
    _zido_open_conn || return 1
    _zido_fd=$REPLY
    zle -F $_zido_fd _zido_io_handler
    return 0
}

_zido_sync_connect() {
    [[ -n $_zido_fd_sync ]] && return 0
    _zido_open_conn || return 1
    _zido_fd_sync=$REPLY
    return 0
}

# ----- protocol helpers -----------------------------------------------------

_zido_escape() {
    local s=${1//\\/\\\\}
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    REPLY=$s
}

# Order is technically wrong for literal "\\t" in candidates, but candidates
# containing backslash escapes are vanishingly rare in practice.
_zido_unescape() {
    local s=${1//\\t/$'\t'}
    s=${s//\\n/$'\n'}
    REPLY=${s//\\\\/\\}
}

# ----- async query path -----------------------------------------------------

_zido_send_query() {
    [[ -n ${_ZIDO_CAPTURE:-} ]] && return
    if [[ -z $_zido_fd ]]; then
        _zido_connect || { _zido_clear_display; return }
    fi
    (( ++_zido_id ))
    local cwd buf req
    _zido_escape "$PWD";    cwd=$REPLY
    _zido_escape "$BUFFER"; buf=$REPLY
    if [[ $_zido_mode == search ]]; then
        req="S"$'\t'"$_zido_id"$'\t'"50"$'\t'"$cwd"$'\t'"$buf"$'\n'
    else
        req="Q"$'\t'"$_zido_id"$'\t'"$COLUMNS"$'\t'"$CURSOR"$'\t'"$cwd"$'\t'"$buf"$'\n'
    fi
    _zido_pending=1
    if ! print -nu $_zido_fd -- "$req" 2>/dev/null; then
        local fd=$_zido_fd
        zle -F $fd 2>/dev/null
        exec {fd}>&- 2>/dev/null
        _zido_fd=""
        if _zido_connect; then
            _zido_send_query
        else
            _zido_clear_display
        fi
    fi
}

_zido_io_handler() {
    local fd=$1 line
    if ! IFS= read -r -u $fd line; then
        # Connection gone (daemon died): never leave stale braces on screen.
        zle -F $fd 2>/dev/null
        [[ $fd == $_zido_fd ]] && _zido_fd=""
        exec {fd}>&- 2>/dev/null
        zle _zido-clear 2>/dev/null
        zle -R 2>/dev/null
        return
    fi
    [[ $line == R$'\t'* ]] || return
    local -a f
    f=("${(@ps:\t:)line}")
    (( f[2] == _zido_id )) || return
    # Never re-render an id we already displayed: the user may have rotated
    # the list since, and a late duplicate would snap it back.
    (( f[2] == _zido_rendered_id )) && return
    typeset -g _zido_rendered_id=$f[2]
    _zido_pending=0
    _zido_state=$f[3]
    _zido_wstart=$f[4]
    _zido_total=$f[5]
    _zido_sel=1
    _zido_off=1
    _zido_cands=()
    _zido_srcs=()
    _zido_inds=()
    if (( $#f >= 6 )) && [[ -n $f[6] ]]; then
        local p
        local -a cf
        for p in "${(@ps:\x1f:)f[6]}"; do
            cf=("${(@ps:\x1e:)p}")
            _zido_unescape "${cf[1]}"
            _zido_cands+=("$REPLY")
            _zido_srcs+=("${cf[2]:-hist}")
            _zido_inds+=("${cf[3]:-}")
        done
    fi
    zle _zido-render 2>/dev/null
    zle -R 2>/dev/null
}

# ----- rendering ------------------------------------------------------------

_zido_elide() {
    local s=$1
    if (( $#s > 36 )); then
        REPLY="${s[1,18]}…${s[-14,-1]}"
    else
        REPLY=$s
    fi
}

_zido_clear_display() {
    POSTDISPLAY=""
    region_highlight=("${(@)region_highlight:#*memo=zido*}")
    _zido_state=empty
}

_zido_render_apply() {
    if [[ $_zido_mode == search ]]; then
        _zido_render_search
        return
    fi
    region_highlight=("${(@)region_highlight:#*memo=zido*}")
    if (( _zido_suppress )) || [[ $_zido_state == empty ]]; then
        POSTDISPLAY=""
        return
    fi

    local -i base=$#BUFFER pos=0
    local pd=""
    local -a hl

    case $_zido_state in
        none)
            pd=" [No match]"
            hl+=("0 ${#pd} ${_zido_color[nomatch]}")
            ;;
        single)
            local c1; _zido_elide "$_zido_cands[1]"; c1=$REPLY
            pd=" [${c1}]"
            hl+=("0 2 ${_zido_color[frame]}")
            hl+=("2 $((2 + $#c1)) ${_zido_color[sel]}")
            hl+=("$((2 + $#c1)) $#pd ${_zido_color[frame]}")
            ;;
        multi)
            local -i avail=$(( COLUMNS - ( (_zido_prompt_w + base) % COLUMNS ) - 3 ))
            (( avail < 16 )) && avail=16
            # Selection block walks right through the visible window; once it
            # hits the right edge the window scrolls instead, eating into the
            # …+N overflow. off = first visible candidate.
            local -i off=$_zido_off i shown last
            local c spec
            (( off < 1 )) && off=1
            (( off > _zido_sel )) && off=$_zido_sel
            while true; do
                pd=" {"
                hl=("0 2 ${_zido_color[frame]}")
                if (( off > 1 )); then
                    hl+=("$#pd $(($#pd + 4)) ${_zido_color[frame]}")
                    pd+="… | "
                fi
                shown=0
                for (( i = off; i <= $#_zido_cands && shown < 5; i++ )); do
                    _zido_elide "$_zido_cands[i]"; c=$REPLY
                    if (( shown > 0 && $#pd + $#c + 9 > avail )); then
                        break
                    fi
                    if (( shown > 0 )); then
                        hl+=("$#pd $(($#pd + 3)) ${_zido_color[frame]}")
                        pd+=" | "
                    fi
                    pos=$#pd
                    if (( i == _zido_sel )); then
                        spec=${_zido_color[sel]}
                    else
                        spec=${_zido_color[${_zido_srcs[i]:-hist}]}
                    fi
                    hl+=("$pos $((pos + $#c)) $spec")
                    pd+="$c"
                    (( shown++ ))
                done
                last=$(( off + shown - 1 ))
                # Selection fell off the right edge: scroll one step, rebuild.
                if (( _zido_sel > last && off < $#_zido_cands )); then
                    (( off++ ))
                    continue
                fi
                break
            done
            _zido_off=$off
            local -i overflow=$(( _zido_total - last ))
            if (( overflow > 0 )); then
                local tail=" | …+${overflow}"
                hl+=("$#pd $(($#pd + $#tail)) ${_zido_color[frame]}")
                pd+=$tail
            fi
            hl+=("$#pd $(($#pd + 1)) ${_zido_color[frame]}")
            pd+="}"
            ;;
    esac

    POSTDISPLAY=$pd
    local h
    for h in "${hl[@]}"; do
        local -a parts=(${(s: :)h})
        region_highlight+=("$((base + parts[1])) $((base + parts[2])) ${parts[3]} memo=zido")
    done
}
# ^R search: atuin-like vertical list under the prompt, ido-styled —
# `{` opens, `|` leads each line, `…+N }` closes. The selection block walks
# the lines, matched chars are highlighted.
_zido_render_search() {
    region_highlight=("${(@)region_highlight:#*memo=zido*}")
    local -i base=$#BUFFER
    local pd=""
    local -a hl

    if (( ! $#_zido_cands )); then
        if (( _zido_pending )); then
            pd=$'\n'"{ … }"
        else
            pd=$'\n'"{ no matches }"
        fi
        hl+=("0 $#pd ${_zido_color[frame]}")
    else
        local -i rows=8 avail=$(( COLUMNS - 6 ))
        (( avail < 20 )) && avail=20
        local -i off=$_zido_off
        (( off < 1 )) && off=1
        (( _zido_sel < off )) && off=$_zido_sel
        (( _zido_sel > off + rows - 1 )) && off=$(( _zido_sel - rows + 1 ))
        _zido_off=$off

        local -i i n=0 lstart clipped p
        local line marker mspec
        for (( i = off; i <= $#_zido_cands && n < rows; i++ )); do
            line=${_zido_cands[i]//$'\n'/ }
            clipped=0
            if (( $#line > avail )); then
                line="${line[1,avail]}…"
                clipped=$avail
            fi
            if (( n == 0 )); then
                if (( off == 1 )); then marker="{ "; else marker="… "; fi
            else
                marker="| "
            fi
            pd+=$'\n'
            hl+=("$#pd $(($#pd + 2)) ${_zido_color[frame]}")
            pd+=$marker
            lstart=$#pd
            if (( i == _zido_sel )); then
                hl+=("$lstart $((lstart + $#line)) ${_zido_color[sel]}")
                mspec=${_zido_color[selmatch]}
            else
                mspec=${_zido_color[match]}
            fi
            if [[ -n ${_zido_inds[i]} ]]; then
                for p in ${(s:,:)_zido_inds[i]}; do
                    (( clipped && p >= clipped )) && continue
                    (( p >= $#line )) && continue
                    hl+=("$((lstart + p)) $((lstart + p + 1)) $mspec")
                done
            fi
            pd+=$line
            (( n++ ))
        done
        local -i overflow=$(( _zido_total - (off + n - 1) ))
        local tail=" }"
        (( overflow > 0 )) && tail=" …+${overflow} }"
        hl+=("$#pd $(($#pd + $#tail)) ${_zido_color[frame]}")
        pd+=$tail
    fi

    POSTDISPLAY=$pd
    local h
    for h in "${hl[@]}"; do
        local -a parts=(${(s: :)h})
        region_highlight+=("$((base + parts[1])) $((base + parts[2])) ${parts[3]} memo=zido")
    done
}

zle -N _zido-render _zido_render_apply
zle -N _zido-clear _zido_clear_display

# ----- compsys capture --------------------------------------------------------
# zsh's real completions (flags, subcommands, ...), harvested per context:
# a forked zpty inherits the user's full compinit world and runs the
# completion machinery once for the line prefix with an empty current word;
# a compadd wrapper collects every match. The daemon caches the set per
# (cwd, prefix) and narrows it per keystroke like any other source.
typeset -g _zido_cap_fd="" _zido_cap_key="" _zido_cap_buf="" _zido_cap_prefix=""

# Runs INSIDE the capture child. Always forwards to the builtin first so
# completion semantics stay intact; the copy of "$@" is parsed only to
# extract the match words.
_zido_cap_compadd() {
    builtin compadd "$@"
    local -i ret=$?
    (( ${#_zido_cap_words} >= 2000 )) && return ret
    local -a _zo _oad _aflag
    zparseopts -D -E -a _zo P: S: p: s: i: I: W: d: J: V: X: x: r: R: E: M+: F: o+: D:=_oad O:=_oad A:=_oad q e Q n U C f w l 1 2 a=_aflag k=_aflag 2>/dev/null || return ret
    (( ${#_oad} )) && return ret
    if (( ${#_aflag} )); then
        # -a/-k: the positional args are ARRAY NAMES, not words
        local n
        for n in "$@"; do
            _zido_cap_words+=(${(P)n})
        done
    else
        _zido_cap_words+=("$@")
    fi
    return ret
}

_zido_cap_widget() {
    typeset -ga _zido_cap_words=()
    functions[compadd]=$functions[_zido_cap_compadd]
    CURSOR=$#BUFFER
    # invoke compinit's own complete-word widget — _main_complete may only
    # run in completion-widget context
    zle -- ${(k)widgets[(r)completion:.complete-word:_main_complete]} 2>/dev/null
    print -rn -- $'\x00'"${(pj:\x1f:)_zido_cap_words}"$'\x00'
    exit 0
}

_zido_cap_child() {
    # We are a fork of the interactive shell: neutralise the inherited zido
    # state so the child never writes on the parent's daemon connections or
    # spawns captures of its own.
    typeset -g _ZIDO_CAPTURE=1
    typeset -g _zido_fd="" _zido_fd_sync="" _zido_cap_fd=""
    add-zle-hook-widget -d line-pre-redraw _zido_precheck 2>/dev/null
    add-zle-hook-widget -d line-init _zido_line_init 2>/dev/null
    # completion inside vared completes the variable VALUE; clearing the
    # vared flag inside the completer makes it behave like a command line
    autoload +X _complete 2>/dev/null
    functions[_zido_orig_complete]=$functions[_complete]
    _complete() { unset 'compstate[vared]'; _zido_orig_complete "$@" }
    zle -N _zido-cap-widget _zido_cap_widget
    bindkey '^I' _zido-cap-widget
    # the line prefix arrives via inherited variable: zpty re-splits command
    # arguments at whitespace and would truncate it
    local tmp=$_zido_cap_arg
    vared tmp 2>/dev/null
    exit 0
}

_zido_cap_maybe_spawn() {
    [[ -n ${_ZIDO_CAPTURE:-} ]] && return
    (( ${+functions[_main_complete]} )) || return
    (( ${+builtins[sysread]} && ${+builtins[zpty]} )) || return
    local before=${BUFFER[1,$CURSOR]}
    [[ $before == *$'\n'* ]] && return
    local word=${before##*[[:space:]]}
    [[ $word == */* || $word == \~* ]] && return
    local prefix=${before[1,$(( $#before - $#word ))]}
    # first word: PATH executables cover it, compsys command completion is slow
    [[ $prefix == *[^[:space:]]* ]] || return
    # explicit array: ${${(z)x}[1]} collapses to a scalar for one-word
    # prefixes and [1] would grab the first CHARACTER
    local -a pwords
    pwords=(${(z)prefix})
    case ${pwords[1]:-} in cd|z|pushd|rmdir) return ;; esac
    # compsys picks flags vs arguments by looking at the current word: a
    # word starting with '-' needs its own capture with a '-' stub
    [[ $word == -* ]] && prefix+="-"
    local key="$PWD"$'\x1e'"$prefix"
    [[ $key == $_zido_cap_key ]] && return
    _zido_cap_key=$key
    _zido_cap_prefix=$prefix
    _zido_cap_buf=""
    if [[ -n $_zido_cap_fd ]]; then
        zle -F $_zido_cap_fd 2>/dev/null
        exec {_zido_cap_fd}>&- 2>/dev/null
        _zido_cap_fd=""
    fi
    typeset -g _zido_cap_arg=$prefix
    # The zpty lives inside a process-substitution subshell: a fork straight
    # out of zle context inherits "zle active" and vared dies with "ZLE
    # cannot be used recursively". The subshell boundary resets that state;
    # the parent only reads the relay pipe.
    exec {_zido_cap_fd}< <(
        local out chunk
        integer i
        zpty -b zidocap _zido_cap_child 2>/dev/null || exit 0
        zpty -n -w zidocap $'\t' 2>/dev/null
        for (( i = 0; i < 300; i++ )); do
            if zpty -rt zidocap chunk 2>/dev/null; then
                out+=$chunk
                [[ $out == *$'\x00'*$'\x00'* ]] && break
            else
                zselect -t 2 2>/dev/null
            fi
        done
        zpty -d zidocap 2>/dev/null
        out=${out#*$'\x00'}
        print -rn -- $'\x00'"${out%%$'\x00'*}"$'\x00'
    ) 2>/dev/null
    if [[ -z $_zido_cap_fd ]]; then
        _zido_cap_key=""
        return
    fi
    zle -F $_zido_cap_fd _zido_cap_io
}

_zido_cap_io() {
    local fd=$1 chunk
    if ! sysread -i $fd chunk 2>/dev/null; then
        zle -F $fd 2>/dev/null
        exec {fd}>&- 2>/dev/null
        [[ $fd == $_zido_cap_fd ]] && _zido_cap_fd=""
        _zido_cap_finish
        return
    fi
    _zido_cap_buf+=$chunk
    if [[ $_zido_cap_buf == *$'\x00'*$'\x00'* ]]; then
        zle -F $fd 2>/dev/null
        exec {fd}>&- 2>/dev/null
        [[ $fd == $_zido_cap_fd ]] && _zido_cap_fd=""
        _zido_cap_finish
    fi
}

_zido_cap_finish() {
    local data=${_zido_cap_buf#*$'\x00'}
    [[ $data == $_zido_cap_buf ]] && { _zido_cap_buf=""; return }
    data=${data%%$'\x00'*}
    _zido_cap_buf=""
    [[ -n $data ]] || return
    _zido_sync_connect || return
    local cwd pfx words
    _zido_escape "$PWD";              cwd=$REPLY
    _zido_escape "$_zido_cap_prefix"; pfx=$REPLY
    _zido_escape "$data";             words=$REPLY
    print -nu $_zido_fd_sync -- "C"$'\t'"$cwd"$'\t'"$pfx"$'\t'"$words"$'\n' 2>/dev/null || return
    zle _zido-requery 2>/dev/null
    zle -R 2>/dev/null
}

_zido_requery_widget() {
    _zido_send_query
}
zle -N _zido-requery _zido_requery_widget

# ----- per-keystroke hook ----------------------------------------------------

_zido_precheck() {
    if [[ $BUFFER == *$'\n'* ]]; then
        _zido_clear_display
        return
    fi
    local key="$CURSOR:$BUFFER"
    [[ $key == $_zido_lastkey ]] && return
    _zido_lastkey=$key
    _zido_suppress=0
    if (( ! _zido_inhist )); then
        _zido_lines=()
        _zido_lidx=0
    fi
    _zido_inhist=0
    _zido_send_query
    [[ $_zido_mode == inline ]] && _zido_cap_maybe_spawn
}
add-zle-hook-widget line-pre-redraw _zido_precheck

_zido_line_init() {
    # Bump the id so in-flight responses for the PREVIOUS line are dropped —
    # otherwise they render that line's candidates onto the fresh prompt.
    (( ++_zido_id ))
    _zido_lastkey="<reset>"
    if [[ $_zido_mode == search ]]; then
        _zido_mode=inline
        zle -K main 2>/dev/null
    fi
    _zido_clear_display
}
add-zle-hook-widget line-init _zido_line_init

# ----- widgets ----------------------------------------------------------------

_zido_accept() {
    if (( $#_zido_cands )) && [[ $_zido_state == (multi|single) ]]; then
        local cand=$_zido_cands[$_zido_sel]
        local before=${BUFFER[1,$_zido_wstart]}
        local after=${BUFFER[$((CURSOR + 1)),-1]}
        BUFFER="${before}${cand}${after}"
        CURSOR=$(( _zido_wstart + $#cand ))
        if [[ $cand != */ ]] && (( CURSOR == $#BUFFER )); then
            BUFFER+=" "
            (( CURSOR++ ))
        fi
    else
        zle expand-or-complete
    fi
}
zle -N _zido_accept

_zido_next() {
    (( $#_zido_cands > 1 )) || return 0
    (( _zido_sel < $#_zido_cands )) && (( _zido_sel++ ))
    _zido_render_apply
}
zle -N _zido_next

_zido_prev() {
    (( $#_zido_cands > 1 )) || return 0
    (( _zido_sel > 1 )) && (( _zido_sel-- ))
    (( _zido_sel < _zido_off )) && _zido_off=$_zido_sel
    _zido_render_apply
}
zle -N _zido_prev

_zido_fetch_lines() {
    _zido_sync_connect || return 1
    local cwd buf line
    _zido_escape "$PWD";    cwd=$REPLY
    _zido_escape "$BUFFER"; buf=$REPLY
    print -nu $_zido_fd_sync -- "L"$'\t'"1"$'\t'"$cwd"$'\t'"$buf"$'\n' 2>/dev/null || {
        exec {_zido_fd_sync}>&- 2>/dev/null
        _zido_fd_sync=""
        return 1
    }
    IFS= read -r -t 1 -u $_zido_fd_sync line || return 1
    [[ $line == R$'\t'* ]] || return 1
    local -a f
    f=("${(@ps:\t:)line}")
    _zido_lines=()
    if (( $#f >= 6 )) && [[ -n $f[6] ]]; then
        local p
        for p in "${(@ps:\x1f:)f[6]}"; do
            _zido_unescape "${p%%$'\x1e'*}"
            _zido_lines+=("$REPLY")
        done
    fi
    (( $#_zido_lines ))
}

_zido_hist_up() {
    if (( ! $#_zido_lines )); then
        _zido_fetch_lines || { zle up-line-or-history; return }
        _zido_origin=$BUFFER
        _zido_lidx=0
    fi
    (( _zido_lidx < $#_zido_lines )) && (( _zido_lidx++ ))
    _zido_inhist=1
    BUFFER=$_zido_lines[_zido_lidx]
    CURSOR=$#BUFFER
}
zle -N _zido_hist_up

_zido_hist_down() {
    if (( _zido_lidx <= 0 )); then
        zle down-line-or-history
        return
    fi
    (( _zido_lidx-- ))
    _zido_inhist=1
    if (( _zido_lidx == 0 )); then
        BUFFER=$_zido_origin
    else
        BUFFER=$_zido_lines[_zido_lidx]
    fi
    CURSOR=$#BUFFER
}
zle -N _zido_hist_down

_zido_dismiss() {
    _zido_suppress=1
    _zido_clear_display
}
zle -N _zido_dismiss

# ----- ^R search mode -----------------------------------------------------------

_zido_search_enter() {
    [[ $_zido_mode == search ]] && return
    _zido_mode=search
    _zido_saved=$BUFFER
    _zido_saved_cur=$CURSOR
    zle -K zido-search
    # Entering changes nothing visible, so no redraw hook fires: query and
    # render explicitly. The stale inline word candidates must not leak into
    # the list.
    _zido_cands=() _zido_srcs=() _zido_inds=()
    _zido_total=0
    _zido_sel=1
    _zido_off=1
    _zido_lastkey="$CURSOR:$BUFFER"
    _zido_send_query
    _zido_render_search
}
zle -N _zido_search_enter

_zido_search_exit() {
    _zido_mode=inline
    zle -K main
    _zido_lastkey="<reset>"
    _zido_clear_display
}

_zido_search_accept() {
    if (( $#_zido_cands )); then
        BUFFER=$_zido_cands[$_zido_sel]
        CURSOR=$#BUFFER
    fi
    _zido_search_exit
}
zle -N _zido_search_accept

_zido_search_cancel() {
    BUFFER=$_zido_saved
    CURSOR=$_zido_saved_cur
    _zido_search_exit
}
zle -N _zido_search_cancel

_zido_search_down() {
    (( _zido_sel < $#_zido_cands )) && (( _zido_sel++ ))
    _zido_render_search
}
zle -N _zido_search_down

_zido_search_up() {
    (( _zido_sel > 1 )) && (( _zido_sel-- ))
    _zido_render_search
}
zle -N _zido_search_up

_zido_accept_line() {
    _zido_clear_display
    zle .accept-line
}
zle -N _zido_accept_line

# ----- recording ---------------------------------------------------------------

_zido_preexec() {
    typeset -g _zido_t0=$EPOCHREALTIME
    typeset -g _zido_lastcmd=$1
    typeset -g _zido_lastpwd=$PWD
}

_zido_precmd() {
    local -i ex=$?
    [[ -n ${_zido_lastcmd:-} ]] || return 0
    local -F dur_f=0
    [[ -n ${_zido_t0:-} ]] && dur_f=$(( (EPOCHREALTIME - _zido_t0) * 1000 ))
    local -i dur=$dur_f
    if _zido_sync_connect; then
        local cwd cmd
        _zido_escape "${_zido_lastpwd:-$PWD}"; cwd=$REPLY
        _zido_escape "$_zido_lastcmd";         cmd=$REPLY
        print -nu $_zido_fd_sync -- "H"$'\t'"$ex"$'\t'"$dur"$'\t'"$cwd"$'\t'"$cmd"$'\n' 2>/dev/null || {
            exec {_zido_fd_sync}>&- 2>/dev/null
            _zido_fd_sync=""
        }
    fi
    _zido_lastcmd=""
}

autoload -Uz add-zsh-hook
if [[ -z $ZIDO_NO_RECORD ]]; then
    add-zsh-hook preexec _zido_preexec
    add-zsh-hook precmd _zido_precmd
fi

# ----- key bindings --------------------------------------------------------------

bindkey '^I' _zido_accept
# zsh ships a whole ^X-prefix keymap (^X^X exchange-point-and-mark, ^Xu undo,
# ^Xr isearch, ...). With those alive, a plain ^X waits KEYTIMEOUT for a
# second key and swallows the next keystroke as a combo. Clear the prefix,
# then bind.
bindkey -rp '^X' 2>/dev/null
bindkey '^X' _zido_next
bindkey '^Z' _zido_prev

# Anything running after us (a second compinit appended by an installer, a
# plugin) can re-create ^X-prefixed bindings and bring the keytimeout lag
# back. Re-clear once after the whole startup is done.
_zido_bind_fix() {
    bindkey -rp '^X' 2>/dev/null
    bindkey '^X' _zido_next
    bindkey -M zido-search -rp '^X' 2>/dev/null
    bindkey -M zido-search '^X' _zido_search_down 2>/dev/null
    add-zsh-hook -d precmd _zido_bind_fix
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _zido_bind_fix
bindkey '^[[A' _zido_hist_up
bindkey '^[[B' _zido_hist_down
bindkey '^P'   _zido_hist_up
bindkey '^N'   _zido_hist_down
bindkey '^G'   _zido_dismiss
bindkey '^M'   _zido_accept_line
bindkey '^J'   _zido_accept_line
bindkey '^R'   _zido_search_enter

# Search-mode keymap: copy of main so typing edits the query, with the
# navigation/accept keys swapped. ^X prefix cleared in the copy too.
bindkey -N zido-search main
bindkey -M zido-search -rp '^X' 2>/dev/null
bindkey -M zido-search '^M' _zido_search_accept
bindkey -M zido-search '^J' _zido_search_accept
bindkey -M zido-search '^I' _zido_search_accept
bindkey -M zido-search '^G' _zido_search_cancel
bindkey -M zido-search '^R' _zido_search_cancel
bindkey -M zido-search '^[[A' _zido_search_up
bindkey -M zido-search '^[[B' _zido_search_down
bindkey -M zido-search '^P' _zido_search_up
bindkey -M zido-search '^N' _zido_search_down
bindkey -M zido-search '^X' _zido_search_down
bindkey -M zido-search '^Z' _zido_search_up

# Prompt width of the input line (last PROMPT line), for width budgeting.
_zido_prompt_w=${#${(%%)${PROMPT##*$'\n'}}}
(( _zido_prompt_w >= COLUMNS )) && _zido_prompt_w=3
