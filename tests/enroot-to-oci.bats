#!/usr/bin/env bats

load helpers
load terminal

@test "preserves exact environment values in the real image" {
    make_rootfs
    cat > "$source_tree/etc/environment" <<'ENV'
  # ignored
T_SPACES=two words
T_EQUALS=a=b=c
T_QUOTES='say "hello"'
T_BACKSLASH=one\two\\three
T_DOLLAR=literal$ENROOT_TEST_HOST
T_EMPTY=
T_UNICODE=crème 雪
T_DUPLICATE=old
T_DUPLICATE=new
ENROOT_RESERVED=discard
bad-name=discard
ENV
    printf '%s\n' 'T_TRAILING=trailing spaces   ' >> "$source_tree/etc/environment"
    pack_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 0 ]
    restore_image
    [[ $stderr == *'ignoring malformed environment assignment'* ]]
    assert_env 'T_SPACES=two words' 'T_TRAILING=trailing spaces   ' 'T_EQUALS=a=b=c' \
        'T_QUOTES=say "hello"' 'T_BACKSLASH=one\two\\three' 'T_DOLLAR=literal$ENROOT_TEST_HOST' \
        'T_EMPTY=' 'T_UNICODE=crème 雪' 'T_DUPLICATE=new'
}

make_dynamic_rootfs() {
    make_rootfs
    cat > "$source_tree/etc/environment" <<'ENV'
T_OMIT=stale
T_OMIT=${ENROOT_TEST_HOST}
T_MISSING=${ENROOT_TEST_MISSING}
T_RESTORED=before
T_RESTORED=${ENROOT_TEST_HOST}
T_RESTORED=after
ENV
    export ENROOT_TEST_HOST='synthetic value'
    pack_rootfs
}

@test "skips host assignments and accepts runtime env and overrides" {
    make_dynamic_rootfs
    run --separate-stderr --keep-empty-lines convert --skip-dynamic-env
    [ "$status" -eq 0 ]
    restore_image
    [[ $stderr != *'Enroot host expansion can embed credentials'* ]]
    assert_env 'T_RESTORED=after'

    run container_run --env 'T_OMIT=runtime value' --env 'T_RESTORED=override' \
        --entrypoint /bin/bash "$restored_tag" -c 'printf "<%s>\n" "$T_OMIT" "$T_RESTORED"'
    [ "$status" -eq 0 ]
    [ "$output" = $'<runtime value>\n<override>' ]
}

@test "resolves known host env and expands unset variables to empty" {
    make_dynamic_rootfs
    run --separate-stderr --keep-empty-lines convert --resolve-host-env
    [ "$status" -eq 0 ]
    restore_image
    [[ $stderr != *'Enroot host expansion can embed credentials'* ]]
    assert_env 'T_OMIT=synthetic value' 'T_MISSING=' 'T_RESTORED=after'
}

@test "rejects unattended host substitution before import" {
    make_dynamic_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 1 ]
    [[ $stderr == *'--skip-dynamic-env'* && $stderr == *'--resolve-host-env'* ]]
    assert_no_import
}

@test "rejects conflicting environment flags before import" {
    make_dynamic_rootfs
    run --separate-stderr --keep-empty-lines convert --skip-dynamic-env --resolve-host-env
    [ "$status" -eq 2 ]
    [[ $stderr == *'--skip-dynamic-env'* && $stderr == *'--resolve-host-env'* ]]
    assert_no_import
}

@test "interactive Enter selects omission" {
    make_dynamic_rootfs
    run --separate-stderr --keep-empty-lines convert_with_terminal enter
    [ "$status" -eq 0 ]
    restore_image
    assert_single_prompt
    assert_env 'T_RESTORED=after'
}

@test "interactive EOF selects omission" {
    make_dynamic_rootfs
    run --separate-stderr --keep-empty-lines convert_with_terminal eof
    [ "$status" -eq 0 ]
    restore_image
    assert_single_prompt
    assert_env 'T_RESTORED=after'
}

@test "interactive yes resolves host env" {
    make_dynamic_rootfs
    run --separate-stderr --keep-empty-lines convert_with_terminal yes
    [ "$status" -eq 0 ]
    restore_image
    assert_single_prompt
    assert_env 'T_OMIT=synthetic value' 'T_MISSING=' 'T_RESTORED=after'
}

@test "preserves startup, default command, argument forwarding and workdir override" {
    make_rootfs
    pack_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 0 ]
    restore_image
    local config
    config=$(inspect_config)
    jq -e '
        .Entrypoint == ["/bin/bash", "/etc/rc"] and
        .WorkingDir == "/app space" and
        ((.Cmd // []) | length == 0) and
        .Labels["org.opencontainers.image.source"] == "docker://example/image:tag"
    ' <<< "$config"

    run container_run "$restored_tag"
    [ "$status" -eq 0 ]
    [ "$output" = $'cwd=</app space>\nrc.local=<sourced>\narg=<default command>' ]

    run container_run -w /override "$restored_tag" 'two words' 'literal$arg' ''
    [ "$status" -eq 0 ]
    [ "$output" = $'cwd=</override>\nrc.local=<sourced>\narg=<two words>\narg=<literal$arg>\narg=<>' ]
}

@test "uses a runnable shell entrypoint without /etc/rc" {
    make_rootfs
    rm "$source_tree/etc/rc"
    pack_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 0 ]
    restore_image
    [[ $stderr == *'no /etc/rc'* ]]
    jq -e '.Entrypoint == ["/bin/sh"]' <<< "$(inspect_config)"

    run container_run -w /override "$restored_tag" -c 'printf "<%s>\n" "$PWD" "$1"' sh 'two words'
    [ "$status" -eq 0 ]
    [ "$output" = $'</override>\n<two words>' ]
}

@test "rejects ambiguous workdirs by default and preserves /etc/rc with the override" {
    make_rootfs
    cat >> "$source_tree/etc/rc" <<'RC'
mkdir -p "/override" 2> /dev/null
cd "/override" && unset OLDPWD || exit 1
RC
    pack_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 1 ]
    [[ $stderr == *'--allow-unrecognized-rc'* ]]
    assert_no_import

    run --separate-stderr --keep-empty-lines convert --allow-unrecognized-rc
    [ "$status" -eq 0 ]
    restore_image
    [[ $stderr == *'may override'* ]]
    jq -e '.Entrypoint == ["/bin/bash", "/etc/rc"]' <<< "$(inspect_config)"

    # Read through EOF with Bash to preserve trailing newlines in the script.
    container_run --entrypoint /bin/bash "$restored_tag" -c '
        if IFS= read -r -d "" script < /etc/rc; then exit 1; fi
        printf "%s" "$script"
    ' > "$BATS_TEST_TMPDIR/restored-rc"
    cmp "$source_tree/etc/rc" "$BATS_TEST_TMPDIR/restored-rc"
}

@test "rejects symlinks at /etc and each inspected configuration path before import" {
    local path name
    for path in etc etc/rc etc/environment etc/fstab; do
        name=${path##*/}
        source_tree="$BATS_TEST_TMPDIR/root-$name"
        sqsh="$BATS_TEST_TMPDIR/$name.sqsh"
        make_rootfs
        touch "$source_tree/etc/environment" "$source_tree/etc/fstab"
        mv "$source_tree/$path" "$source_tree/$path.real"
        ln -s "$name.real" "$source_tree/$path"
        pack_rootfs

        run --separate-stderr --keep-empty-lines convert --allow-unrecognized-rc
        [ "$status" -eq 1 ]
        [[ $stderr == *"/$path is a symlink"* ]]
        assert_no_import
    done
}

@test "rejects /etc/rc without Bash before import" {
    make_rootfs
    rm "$source_tree/bin/bash"
    pack_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 1 ]
    [[ $stderr == *'Bash is not present'* ]]
    assert_no_import
}

@test "rejects line breaks introduced by host expansion before import" {
    make_dynamic_rootfs
    local value
    for value in $'first\nsecond' $'first\rsecond'; do
        export ENROOT_TEST_HOST="$value"
        run --separate-stderr --keep-empty-lines convert --resolve-host-env
        [ "$status" -eq 1 ]
        [[ $stderr == *'T_OMIT contains a newline/CR'* ]]
        assert_no_import
    done
}

@test "rejects a corrupt SquashFS before import" {
    printf 'invalid SquashFS\n' > "$sqsh"
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -ne 0 ]
    [ -n "$stderr" ]
    assert_no_import
}

@test "warns about active /etc/fstab mounts while converting" {
    make_rootfs
    printf '# Fixture mount\n  /host/source /container/destination none bind 0 0\n' > "$source_tree/etc/fstab"
    pack_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 0 ]
    restore_image
    [[ $stderr == *'/etc/fstab has Enroot-specific mounts'* ]]
    inspect_config >/dev/null
}

@test "propagates the real Podman import failure" {
    make_rootfs
    pack_rootfs
    export ENROOT_TEST_INVALID_IMPORT=1
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -ne 0 ]
    [ "$status" -eq "$(cat "$BATS_TEST_TMPDIR/import-status")" ]
    [[ $stderr == *'Podman import failed'* ]]
    assert_unpublished
    assert_podman_absent image "$(cat "$BATS_TEST_TMPDIR/staging-tag")"
}

@test "runs the restored image with Bash only at /usr/bin/bash" {
    make_rootfs
    mkdir -p "$source_tree/usr/bin"
    mv "$source_tree/bin/bash" "$source_tree/usr/bin/bash"
    sed -i 's@/bin/bash@/usr/bin/bash@g' "$source_tree/etc/rc"
    pack_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 0 ]
    restore_image
    jq -e '.Entrypoint == ["/usr/bin/bash", "/etc/rc"] and ((.Cmd // []) | length == 0)' <<< "$(inspect_config)"

    run container_run -w /override "$restored_tag" 'two words'
    [ "$status" -eq 0 ]
    [ "$output" = $'cwd=</override>\nrc.local=<sourced>\narg=<two words>' ]
}

@test "preserves trailing whitespace in the stored and runtime working directory" {
    make_rootfs
    local workdir='/workdir '
    mkdir "$source_tree/workdir" "$source_tree$workdir"
    sed -i "s@/app space@$workdir@g" "$source_tree/etc/rc"
    pack_rootfs
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 0 ]
    restore_image
    jq -e --arg expected "$workdir" '.WorkingDir == $expected' <<< "$(inspect_config)"

    run container_run "$restored_tag"
    [ "$status" -eq 0 ]
    [ "$output" = $'cwd=</workdir >\nrc.local=<sourced>\narg=<default command>' ]

    run container_run -w /override "$restored_tag"
    [ "$status" -eq 0 ]
    [ "$output" = $'cwd=</override>\nrc.local=<sourced>\narg=<default command>' ]
}
