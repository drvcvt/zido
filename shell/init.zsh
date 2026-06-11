# klammer zsh frontend. Emitted by `klammer init zsh`; @KLAMMER_BIN@ is
# replaced with the absolute binary path at init time.
# Requires zsh 5.9 (region_highlight memo= field).

[[ -o interactive ]] || return 0
zmodload zsh/net/socket 2>/dev/null || return 0
zmodload zsh/zselect 2>/dev/null
zmodload zsh/datetime 2>/dev/null
autoload -Uz add-zle-hook-widget

typeset -g KLAMMER_SOCK="${XDG_RUNTIME_DIR:-/tmp}/klammer.sock"
typeset -g KLAMMER_BIN="@KLAMMER_BIN@"

typeset -g _klammer_fd="" _klammer_fd_sync=""
typeset -gi _klammer_id=0 _klammer_wstart=0 _klammer_total=0
typeset -gi _klammer_suppress=0 _klammer_inhist=0 _klammer_lidx=0
typeset -g _klammer_state=empty _klammer_lastkey="<reset>" _klammer_origin=""
typeset -ga _klammer_cands _klammer_srcs _klammer_lines
typeset -g _klammer_prompt_w=3

# Colours per source; frame = braces and separators.
typeset -gA _klammer_color=(
    hist    'fg=3'
    line    'fg=3'
    exec    'fg=2'
    file    'fg=4'
    dir     'fg=4,bold'
    frame   'fg=8'
    nomatch 'fg=1'
)

# ----- daemon / connections -------------------------------------------------

_klammer_spawn_daemon() {
    [[ -S $KLAMMER_SOCK ]] && return 0
    "$KLAMMER_BIN" daemon >>/tmp/klammer.log 2>&1 &!
    local -i i
    for i in {1..100}; do
        [[ -S $KLAMMER_SOCK ]] && return 0
        zselect -t 2 2>/dev/null || builtin read -t 0.02 -k 0 2>/dev/null
    done
    return 1
}

_klammer_connect() {
    _klammer_spawn_daemon || return 1
    zsocket "$KLAMMER_SOCK" 2>/dev/null || return 1
    _klammer_fd=$REPLY
    zle -F $_klammer_fd _klammer_io_handler
    return 0
}

_klammer_sync_connect() {
    [[ -n $_klammer_fd_sync ]] && return 0
    _klammer_spawn_daemon || return 1
    zsocket "$KLAMMER_SOCK" 2>/dev/null || return 1
    _klammer_fd_sync=$REPLY
    return 0
}

# ----- protocol helpers -----------------------------------------------------

_klammer_escape() {
    local s=${1//\\/\\\\}
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    REPLY=$s
}

# Order is technically wrong for literal "\\t" in candidates, but candidates
# containing backslash escapes are vanishingly rare in practice.
_klammer_unescape() {
    local s=${1//\\t/$'\t'}
    s=${s//\\n/$'\n'}
    REPLY=${s//\\\\/\\}
}

# ----- async query path -----------------------------------------------------

_klammer_send_query() {
    if [[ -z $_klammer_fd ]]; then
        _klammer_connect || return
    fi
    (( ++_klammer_id ))
    local cwd buf
    _klammer_escape "$PWD";    cwd=$REPLY
    _klammer_escape "$BUFFER"; buf=$REPLY
    if ! print -nu $_klammer_fd -- "Q"$'\t'"$_klammer_id"$'\t'"$COLUMNS"$'\t'"$CURSOR"$'\t'"$cwd"$'\t'"$buf"$'\n' 2>/dev/null; then
        zle -F $_klammer_fd 2>/dev/null
        _klammer_fd=""
        _klammer_connect && _klammer_send_query
    fi
}

_klammer_io_handler() {
    local fd=$1 line
    if ! IFS= read -r -u $fd line; then
        zle -F $fd 2>/dev/null
        [[ $fd == $_klammer_fd ]] && _klammer_fd=""
        exec {fd}>&- 2>/dev/null
        return
    fi
    [[ $line == R$'\t'* ]] || return
    local -a f
    f=("${(@ps:\t:)line}")
    (( f[2] == _klammer_id )) || return
    _klammer_state=$f[3]
    _klammer_wstart=$f[4]
    _klammer_total=$f[5]
    _klammer_cands=()
    _klammer_srcs=()
    if (( $#f >= 6 )) && [[ -n $f[6] ]]; then
        local p
        for p in "${(@ps:\x1f:)f[6]}"; do
            _klammer_unescape "${p%%$'\x1e'*}"
            _klammer_cands+=("$REPLY")
            _klammer_srcs+=("${p#*$'\x1e'}")
        done
    fi
    zle _klammer-render 2>/dev/null
    zle -R 2>/dev/null
}

# ----- rendering ------------------------------------------------------------

_klammer_elide() {
    local s=$1
    if (( $#s > 36 )); then
        REPLY="${s[1,18]}…${s[-14,-1]}"
    else
        REPLY=$s
    fi
}

_klammer_clear_display() {
    POSTDISPLAY=""
    region_highlight=("${(@)region_highlight:#*memo=klammer*}")
    _klammer_state=empty
}

_klammer_render_apply() {
    region_highlight=("${(@)region_highlight:#*memo=klammer*}")
    if (( _klammer_suppress )) || [[ $_klammer_state == empty ]]; then
        POSTDISPLAY=""
        return
    fi

    local -i base=$#BUFFER pos=0
    local pd=""
    local -a hl

    case $_klammer_state in
        none)
            pd=" [No match]"
            hl+=("0 ${#pd} ${_klammer_color[nomatch]}")
            ;;
        single)
            local c1; _klammer_elide "$_klammer_cands[1]"; c1=$REPLY
            pd="[${c1}]"
            hl+=("0 1 ${_klammer_color[frame]}")
            hl+=("1 $((1 + $#c1)) ${_klammer_color[${_klammer_srcs[1]:-hist}]},bold")
            hl+=("$((1 + $#c1)) $#pd ${_klammer_color[frame]}")
            ;;
        multi)
            local -i avail=$(( COLUMNS - ( (_klammer_prompt_w + base) % COLUMNS ) - 2 ))
            (( avail < 16 )) && avail=16
            pd="{"
            hl+=("0 1 ${_klammer_color[frame]}")
            local -i i shown=0
            local c
            for (( i = 1; i <= $#_klammer_cands && shown < 5; i++ )); do
                _klammer_elide "$_klammer_cands[i]"; c=$REPLY
                if (( shown > 0 && $#pd + $#c + 9 > avail )); then
                    break
                fi
                if (( shown > 0 )); then
                    hl+=("$#pd $(($#pd + 3)) ${_klammer_color[frame]}")
                    pd+=" | "
                fi
                pos=$#pd
                local spec=${_klammer_color[${_klammer_srcs[i]:-hist}]}
                (( shown == 0 )) && spec+=",bold"
                hl+=("$pos $((pos + $#c)) $spec")
                pd+="$c"
                (( shown++ ))
            done
            local -i overflow=$(( _klammer_total - shown ))
            if (( overflow > 0 )); then
                local tail=" | …+${overflow}"
                hl+=("$#pd $(($#pd + $#tail)) ${_klammer_color[frame]}")
                pd+=$tail
            fi
            hl+=("$#pd $(($#pd + 1)) ${_klammer_color[frame]}")
            pd+="}"
            ;;
    esac

    POSTDISPLAY=$pd
    local h
    for h in "${hl[@]}"; do
        local -a parts=(${(s: :)h})
        region_highlight+=("$((base + parts[1])) $((base + parts[2])) ${parts[3]} memo=klammer")
    done
}
zle -N _klammer-render _klammer_render_apply

# ----- per-keystroke hook ----------------------------------------------------

_klammer_precheck() {
    if [[ $BUFFER == *$'\n'* ]]; then
        _klammer_clear_display
        return
    fi
    local key="$CURSOR:$BUFFER"
    [[ $key == $_klammer_lastkey ]] && return
    _klammer_lastkey=$key
    _klammer_suppress=0
    if (( ! _klammer_inhist )); then
        _klammer_lines=()
        _klammer_lidx=0
    fi
    _klammer_inhist=0
    _klammer_send_query
}
add-zle-hook-widget line-pre-redraw _klammer_precheck

_klammer_line_init() {
    _klammer_lastkey="<reset>"
    _klammer_clear_display
}
add-zle-hook-widget line-init _klammer_line_init

# ----- widgets ----------------------------------------------------------------

_klammer_accept() {
    if (( $#_klammer_cands )) && [[ $_klammer_state == (multi|single) ]]; then
        local cand=$_klammer_cands[1]
        local before=${BUFFER[1,$_klammer_wstart]}
        local after=${BUFFER[$((CURSOR + 1)),-1]}
        BUFFER="${before}${cand}${after}"
        CURSOR=$(( _klammer_wstart + $#cand ))
        if [[ $cand != */ ]] && (( CURSOR == $#BUFFER )); then
            BUFFER+=" "
            (( CURSOR++ ))
        fi
    else
        zle expand-or-complete
    fi
}
zle -N _klammer_accept

_klammer_next() {
    (( $#_klammer_cands > 1 )) || return 0
    _klammer_cands=("${(@)_klammer_cands[2,-1]}" "$_klammer_cands[1]")
    _klammer_srcs=("${(@)_klammer_srcs[2,-1]}" "$_klammer_srcs[1]")
    _klammer_render_apply
}
zle -N _klammer_next

_klammer_prev() {
    (( $#_klammer_cands > 1 )) || return 0
    _klammer_cands=("$_klammer_cands[-1]" "${(@)_klammer_cands[1,-2]}")
    _klammer_srcs=("$_klammer_srcs[-1]" "${(@)_klammer_srcs[1,-2]}")
    _klammer_render_apply
}
zle -N _klammer_prev

_klammer_fetch_lines() {
    _klammer_sync_connect || return 1
    local cwd buf line
    _klammer_escape "$PWD";    cwd=$REPLY
    _klammer_escape "$BUFFER"; buf=$REPLY
    print -nu $_klammer_fd_sync -- "L"$'\t'"1"$'\t'"$cwd"$'\t'"$buf"$'\n' 2>/dev/null || {
        exec {_klammer_fd_sync}>&- 2>/dev/null
        _klammer_fd_sync=""
        return 1
    }
    IFS= read -r -t 1 -u $_klammer_fd_sync line || return 1
    [[ $line == R$'\t'* ]] || return 1
    local -a f
    f=("${(@ps:\t:)line}")
    _klammer_lines=()
    if (( $#f >= 6 )) && [[ -n $f[6] ]]; then
        local p
        for p in "${(@ps:\x1f:)f[6]}"; do
            _klammer_unescape "${p%%$'\x1e'*}"
            _klammer_lines+=("$REPLY")
        done
    fi
    (( $#_klammer_lines ))
}

_klammer_hist_up() {
    if (( ! $#_klammer_lines )); then
        _klammer_fetch_lines || { zle up-line-or-history; return }
        _klammer_origin=$BUFFER
        _klammer_lidx=0
    fi
    (( _klammer_lidx < $#_klammer_lines )) && (( _klammer_lidx++ ))
    _klammer_inhist=1
    BUFFER=$_klammer_lines[_klammer_lidx]
    CURSOR=$#BUFFER
}
zle -N _klammer_hist_up

_klammer_hist_down() {
    if (( _klammer_lidx <= 0 )); then
        zle down-line-or-history
        return
    fi
    (( _klammer_lidx-- ))
    _klammer_inhist=1
    if (( _klammer_lidx == 0 )); then
        BUFFER=$_klammer_origin
    else
        BUFFER=$_klammer_lines[_klammer_lidx]
    fi
    CURSOR=$#BUFFER
}
zle -N _klammer_hist_down

_klammer_dismiss() {
    _klammer_suppress=1
    _klammer_clear_display
}
zle -N _klammer_dismiss

_klammer_accept_line() {
    _klammer_clear_display
    zle .accept-line
}
zle -N _klammer_accept_line

# ----- recording ---------------------------------------------------------------

_klammer_preexec() {
    typeset -g _klammer_t0=$EPOCHREALTIME
    typeset -g _klammer_lastcmd=$1
    typeset -g _klammer_lastpwd=$PWD
}

_klammer_precmd() {
    local -i ex=$?
    [[ -n ${_klammer_lastcmd:-} ]] || return 0
    local -F dur_f=0
    [[ -n ${_klammer_t0:-} ]] && dur_f=$(( (EPOCHREALTIME - _klammer_t0) * 1000 ))
    local -i dur=$dur_f
    if _klammer_sync_connect; then
        local cwd cmd
        _klammer_escape "${_klammer_lastpwd:-$PWD}"; cwd=$REPLY
        _klammer_escape "$_klammer_lastcmd";         cmd=$REPLY
        print -nu $_klammer_fd_sync -- "H"$'\t'"$ex"$'\t'"$dur"$'\t'"$cwd"$'\t'"$cmd"$'\n' 2>/dev/null || {
            exec {_klammer_fd_sync}>&- 2>/dev/null
            _klammer_fd_sync=""
        }
    fi
    _klammer_lastcmd=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _klammer_preexec
add-zsh-hook precmd _klammer_precmd

# ----- key bindings --------------------------------------------------------------

bindkey '^I' _klammer_accept
bindkey '^X' _klammer_next
bindkey '^Z' _klammer_prev
bindkey '^[[A' _klammer_hist_up
bindkey '^[[B' _klammer_hist_down
bindkey '^P'   _klammer_hist_up
bindkey '^N'   _klammer_hist_down
bindkey '^G'   _klammer_dismiss
bindkey '^M'   _klammer_accept_line
bindkey '^J'   _klammer_accept_line

# Prompt width of the input line (last PROMPT line), for width budgeting.
_klammer_prompt_w=${#${(%%)${PROMPT##*$'\n'}}}
(( _klammer_prompt_w >= COLUMNS )) && _klammer_prompt_w=3
