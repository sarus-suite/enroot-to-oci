TERMINAL_PROMPT='Expand host-dependent assignments? [y/N] '

run_with_terminal() {
    local reply=$1 log=$2
    shift 2
    local response command input tty_stdout tty_stderr tty_fd session deadline session_status=0
    case "$reply" in
        enter) response=$'\n' ;;
        eof) response=$'\x04' ;;
        no) response=$'n\n' ;;
        yes) response=$'y\n' ;;
        uppercase_yes) response=$'Y\n' ;;
        repeated_yes) response=$'yy\n' ;;
        *) printf 'Unknown terminal reply: %s\n' "$reply" >&2; return 2 ;;
    esac

    input="$log.input"
    tty_stdout="$log.stdout"
    tty_stderr="$log.stderr"
    mkfifo "$input" || return
    exec {tty_fd}<>"$input" || return

    # script gives the child a controlling terminal. The converter itself
    # reads /dev/tty, so its ordinary streams can still be captured separately.
    printf -v command ' %q' "$@"
    printf -v command 'exec%s </dev/null >%q 2>%q' "$command" "$tty_stdout" "$tty_stderr"
    : > "$log"
    SHELL=/bin/bash timeout --kill-after=5 20 script -q -e -f -E never -c "$command" /dev/null \
        < "$input" > "$log" &
    session=$!
    deadline=$((SECONDS + 20))
    until grep -Fq -- "$TERMINAL_PROMPT" "$log"; do
        if ! kill -0 "$session" 2>/dev/null || ((SECONDS >= deadline)); then
            break
        fi
        sleep 0.05
    done
    if grep -Fq -- "$TERMINAL_PROMPT" "$log"; then
        printf '%s' "$response" >&"$tty_fd"
    else
        printf 'Converter did not prompt on the controlling terminal\n' >&2
        session_status=1
    fi
    wait "$session" || session_status=$?
    exec {tty_fd}>&-

    if [[ -f $tty_stdout ]]; then cat "$tty_stdout"; fi
    if [[ -f $tty_stderr ]]; then cat "$tty_stderr" >&2; fi
    return "$session_status"
}

assert_single_prompt() {
    [ "$(grep -Fo -- "$TERMINAL_PROMPT" "$terminal_log" | wc -l)" -eq 1 ]
    [ "$(grep -Fo -- 'Enroot host expansion can embed credentials' "$terminal_log" | wc -l)" -eq 1 ]
}
