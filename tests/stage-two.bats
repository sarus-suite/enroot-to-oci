#!/usr/bin/env bats

load mock-helpers

setup_file() {
    bats_require_minimum_version 1.11.0
    [[ -n ${ENROOT_CONVERTER:-} ]] || skip 'set ENROOT_CONVERTER to the stage-two-driver example'
}

install_tar_stub() {
    export REAL_TAR TAR_PID="$BATS_TEST_TMPDIR/tar.pid"
    REAL_TAR=$(command -v tar)
    cat > "$BATS_TEST_TMPDIR/bin/tar" <<'SH'
#!/usr/bin/env bash
if [[ $1 != --format=posix ]]; then
    exec "$REAL_TAR" "$@"
fi
printf '%s\n' "$$" > "$TAR_PID"
if [[ ${MOCK_TAR_BLOCK:-0} == 1 ]]; then
    exec sleep 60
fi
if [[ ${MOCK_TAR_SIGNAL:-0} == 1 ]]; then
    kill -TERM "$$"
fi
"$REAL_TAR" "$@" || exit $?
exit "${MOCK_TAR_STATUS:-0}"
SH
    chmod +x "$BATS_TEST_TMPDIR/bin/tar"
}

assert_tar_reaped() {
    local pid
    pid=$(cat "$TAR_PID") || return
    ! kill -0 "$pid" 2>/dev/null
}

assert_change() {
    local -a args
    local i
    mapfile -d '' -t args < "$CAPTURE.args"
    for ((i=1; i<${#args[@]}-2; i+=2)); do
        [ "${args[i]}" = --change ] || return 1
        if [ "${args[i+1]}" = "$1" ]; then
            return 0
        fi
    done
    return 1
}

@test "staging returns tar status when Podman succeeds and reaps tar" {
    install_tar_stub
    export MOCK_TAR_STATUS=37
    run --separate-stderr convert
    [ "$status" -eq 37 ]
    [[ $stderr == *'tar failed'* ]]
    assert_import
    assert_tar_reaped
}

@test "staging returns the rightmost failure when tar and Podman both fail" {
    install_tar_stub
    export MOCK_TAR_STATUS=37 MOCK_IMPORT_STATUS=42
    run --separate-stderr convert
    [ "$status" -eq 42 ]
    [[ $stderr == *'Podman import failed'* ]]
    assert_import
    assert_tar_reaped
}

@test "staging maps a tar signal to a process exit status" {
    install_tar_stub
    export MOCK_TAR_SIGNAL=1
    run --separate-stderr convert
    [ "$status" -eq 143 ]
    assert_tar_reaped
}

@test "staging exits promptly if configured Podman cannot start" {
    install_tar_stub
    export MOCK_TAR_BLOCK=1
    mv "$configured_podman" "$configured_podman.disabled"
    run --separate-stderr convert
    [ "$status" -eq 1 ]
    [[ $stderr == *'Cannot start Podman import'* ]]
    assert_no_import
    # The driver may kill tar before the shim writes its PID.
    if [[ -s $TAR_PID ]]; then
        assert_tar_reaped
    fi
}

@test "staging removes only the workdir pair and warns about active mounts" {
    printf 'first byte preserved\nlast line has no newline' > "$BATS_TEST_TMPDIR/expected-rc"
    {
        printf 'first byte preserved\nmkdir\t-p  "/app space" \t2>\t/dev/null\n'
        printf 'cd "/app space" && unset OLDPWD || exit 1\nlast line has no newline'
    } > "$FIXTURE/etc/rc"
    cp "$FIXTURE/etc/rc" "$BATS_TEST_TMPDIR/original-rc"
    printf '  # ignore\n\n  /host/source /destination none bind 0 0\n' > "$FIXTURE/etc/fstab"
    printf 'image checksum fixture\n' > "$sqsh"
    printf '\0binary payload\n' > "$FIXTURE/payload"
    local checksum
    checksum=$(sha256sum "$sqsh")

    run --separate-stderr convert
    [ "$status" -eq 0 ]
    [[ $stderr == *'/etc/fstab has Enroot-specific mounts'* ]]
    assert_import
    sha256sum --check <<< "$checksum"
    tar -xOf "$CAPTURE.tar" ./payload | cmp "$FIXTURE/payload" -
}

@test "staging uses only the first provenance marker" {
    sed -i '1s/^# enroot-provenance: .*/# enroot-provenance: /' "$FIXTURE/etc/rc"
    printf '# enroot-provenance: later\n' >> "$FIXTURE/etc/rc"
    cp "$FIXTURE/etc/rc" "$BATS_TEST_TMPDIR/original-rc"
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    ! grep -aq 'LABEL org.opencontainers.image.source=' "$CAPTURE.args"

    sed -i '1s/$/docker:\/\/first/' "$FIXTURE/etc/rc"
    cp "$FIXTURE/etc/rc" "$BATS_TEST_TMPDIR/original-rc"
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    assert_change 'LABEL org.opencontainers.image.source=docker://first'
}

@test "staging rejects unrecognized working directories unless explicitly allowed" {
    local path
    for path in 'relative' '/app$HOME' '/app\space' '/app`space'; do
        printf 'mkdir -p "%s" 2> /dev/null\ncd "%s" && unset OLDPWD || exit 1' "$path" "$path" > "$FIXTURE/etc/rc"
        cp "$FIXTURE/etc/rc" "$BATS_TEST_TMPDIR/original-rc"
        run --separate-stderr convert
        [ "$status" -eq 1 ]
        [[ $stderr == *'--allow-unrecognized-rc'* ]]
        assert_no_import
    done

    printf 'mkdir -p "/app space" 2> /dev/null\ncd "/app space"  && unset OLDPWD || exit 1' > "$FIXTURE/etc/rc"
    cp "$FIXTURE/etc/rc" "$BATS_TEST_TMPDIR/original-rc"
    run --separate-stderr convert --allow-unrecognized-rc
    [ "$status" -eq 0 ]
    [[ $stderr == *'may override'* ]]
    ! grep -aq 'WORKDIR ' "$CAPTURE.args"
    tar -xOf "$CAPTURE.tar" ./etc/rc | cmp "$FIXTURE/etc/rc" -
}

@test "staging preserves nonregular optional configuration entries" {
    unlink "$FIXTURE/etc/environment"
    mkfifo "$FIXTURE/etc/environment"
    mkdir "$FIXTURE/etc/fstab"
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    [[ $stderr != *'Enroot-specific mounts'* ]]
    assert_import
    tar -tvf "$CAPTURE.tar" ./etc/environment ./etc/fstab > "$BATS_TEST_TMPDIR/listing"
    grep -Eq '^p.* ./etc/environment$' "$BATS_TEST_TMPDIR/listing"
    grep -Eq '^d.* ./etc/fstab/$' "$BATS_TEST_TMPDIR/listing"
}

@test "staging preserves read-only paths and removes the extracted tree" {
    chmod 0444 "$FIXTURE/etc/rc"
    mkdir "$FIXTURE/read-only"
    touch "$FIXTURE/read-only/file"
    chmod 0555 "$FIXTURE/read-only"
    run --separate-stderr convert
    chmod 0755 "$FIXTURE/read-only"
    [ "$status" -eq 0 ]
    assert_import
    tar -tvf "$CAPTURE.tar" ./etc/rc ./read-only > "$BATS_TEST_TMPDIR/listing"
    grep -Eq '^-r--r--r--.* ./etc/rc$' "$BATS_TEST_TMPDIR/listing"
    grep -Eq '^dr-xr-xr-x.* ./read-only/$' "$BATS_TEST_TMPDIR/listing"
}

@test "staging applies the caller locale to names and expands each reference once" {
    export SOME_HOST='${LATER}' LATER=expanded
    cat > "$FIXTURE/etc/environment" <<'ENV'
ÉTÉ=kept
A=${SOME_HOST}
B=${ÉTÉ}
C=literal$LATER
ENV
    run --separate-stderr convert --resolve-host-env
    [ "$status" -eq 0 ]
    assert_import 'ÉTÉ=kept' 'A=${LATER}' 'B=${ÉTÉ}' 'C=literal$LATER'

    export LC_ALL=C
    run --separate-stderr convert --resolve-host-env
    [ "$status" -eq 0 ]
    [[ $stderr == *'ignoring malformed environment assignment'* ]]
    assert_import 'A=${LATER}' 'B=${ÉTÉ}' 'C=literal$LATER'
}

@test "staging rejects retained environment values with invalid UTF-8" {
    printf '# comment\nRAW=\377\n' > "$FIXTURE/etc/environment"
    run --separate-stderr convert
    [ "$status" -eq 1 ]
    [[ $stderr == *'/etc/environment:2:'*'not valid UTF-8'* ]]
    assert_no_import

    export SOME_HOST=$'sensitive-\377'
    printf 'RAW=${SOME_HOST}\n' > "$FIXTURE/etc/environment"
    run --separate-stderr convert --resolve-host-env
    [ "$status" -eq 1 ]
    [[ $stderr == *'/etc/environment:1:'*'not valid UTF-8'* && $stderr != *'sensitive-'* ]]
    assert_no_import
}

@test "staging ignores invalid UTF-8 in overwritten or skipped values" {
    printf 'RAW=\377\nRAW=雪\nOMITTED=\377\nOMITTED=${SOME_HOST}\n' > "$FIXTURE/etc/environment"
    export SOME_HOST=$'\377'
    run --separate-stderr convert --skip-dynamic-env
    [ "$status" -eq 0 ]
    assert_import 'RAW=雪'
}

@test "staging protects trailing workdir whitespace in the Podman argument" {
    local workdir
    for workdir in '/workdir ' $'/workdir\t' $'/workdir\u00a0'; do
        printf 'mkdir -p "%s" 2> /dev/null\ncd "%s" && unset OLDPWD || exit 1\n' "$workdir" "$workdir" > "$FIXTURE/etc/rc"
        cp "$FIXTURE/etc/rc" "$BATS_TEST_TMPDIR/original-rc"
        run --separate-stderr convert
        [ "$status" -eq 0 ]
        assert_change "WORKDIR $workdir/."
    done
}

@test "staging rejects a workdir that cannot be represented before import" {
    printf 'mkdir -p "/workdir\377" 2> /dev/null\ncd "/workdir\377" && unset OLDPWD || exit 1\n' > "$FIXTURE/etc/rc"
    cp "$FIXTURE/etc/rc" "$BATS_TEST_TMPDIR/original-rc"
    run --separate-stderr convert --allow-unrecognized-rc
    [ "$status" -eq 1 ]
    [[ $stderr == *'Working directory in /etc/rc is not valid UTF-8'* ]]
    assert_no_import
}

@test "staging accepts only a single y or Y from the controlling terminal" {
    export SOME_HOST=host
    printf '%s\n' 'A=${SOME_HOST}' > "$FIXTURE/etc/environment"
    run --separate-stderr run_with_terminal uppercase_yes "$terminal_log" "${converter[@]}" "$sqsh" "$tag"
    [ "$status" -eq 0 ]
    assert_single_prompt
    assert_import 'A=host'

    terminal_log="$BATS_TEST_TMPDIR/repeated-yes"
    CAPTURE="$BATS_TEST_TMPDIR/repeated-yes-import"
    run --separate-stderr run_with_terminal repeated_yes "$terminal_log" "${converter[@]}" "$sqsh" "$tag"
    [ "$status" -eq 0 ]
    assert_single_prompt
    assert_import
}

@test "staging resolves absolute Bash symlinks inside the image" {
    mkdir -p "$FIXTURE/usr"
    mv "$FIXTURE/bin" "$FIXTURE/usr/bin"
    ln -s /usr/bin "$FIXTURE/bin"
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    assert_import

    unlink "$FIXTURE/usr/bin/bash"
    CAPTURE="$BATS_TEST_TMPDIR/without-bash"
    run --separate-stderr convert
    [ "$status" -eq 1 ]
    [[ $stderr == *'Bash is not present'* ]]
    assert_no_import
}

@test "staging falls back to /usr/bin/bash when /bin/bash requires a directory" {
    mkdir -p "$FIXTURE/usr/bin"
    mv "$FIXTURE/bin/bash" "$FIXTURE/usr/bin/bash"
    chmod +x "$FIXTURE/usr/bin/bash"
    ln -s ../usr/bin/bash/. "$FIXTURE/bin/bash"

    run --separate-stderr convert
    [ "$status" -eq 0 ]
    assert_change 'ENTRYPOINT ["/usr/bin/bash","/etc/rc"]'
}

@test "staging requires execute bits on the resolved Bash file" {
    mkdir -p "$FIXTURE/usr/bin"
    cp "$FIXTURE/bin/bash" "$FIXTURE/usr/bin/bash"
    chmod 0644 "$FIXTURE/bin/bash"
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    assert_change 'ENTRYPOINT ["/usr/bin/bash","/etc/rc"]'

    mv "$FIXTURE/bin/bash" "$FIXTURE/bin/bash-no-execute"
    ln -s bash-no-execute "$FIXTURE/bin/bash"
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    assert_change 'ENTRYPOINT ["/usr/bin/bash","/etc/rc"]'

    chmod 0644 "$FIXTURE/usr/bin/bash"
    CAPTURE="$BATS_TEST_TMPDIR/no-executable-bash"
    run --separate-stderr convert
    [ "$status" -eq 1 ]
    [[ $stderr == *'executable regular file'* ]]
    assert_no_import
}
