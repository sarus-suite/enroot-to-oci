#!/usr/bin/env bats

load helpers

# Mount and unmount in the same namespace, including on assertion failures.
with_image() {
    local image=$1
    shift
    timeout --kill-after=5 30 "$PODMAN_BIN" unshare bash -c '
        set -eu
        image=$1
        shift
        mountpoint=$("$PODMAN_BIN" image mount "$image")
        cleanup() { "$PODMAN_BIN" image unmount "$image" >/dev/null; }
        trap cleanup EXIT
        "$@" "$mountpoint"
    ' bash "$image" "$@"
}

extract_source() {
    unsquashfs -no-progress -processors 1 -dest "$1" "$sqsh"
}

@test "matches file contents, modes, links and FIFOs and checks numeric ownership" {
    make_rootfs
    mkdir -m 0750 "$source_tree/payload"
    printf '\0binary data\n' > "$source_tree/payload/data"
    printf 'numeric owner probe\n' > "$source_tree/payload/owned"
    chmod 0640 "$source_tree/payload/owned" "$source_tree/payload/data"
    ln "$source_tree/payload/data" "$source_tree/payload/hardlink"
    ln -s data "$source_tree/payload/symlink"
    mkfifo -m 0620 "$source_tree/payload/fifo"
    pack_rootfs -pseudo-override -p '/payload/owned m 0640 1234 2345'
    local extracted="$BATS_TEST_TMPDIR/source"
    extract_source "$extracted"
    local listing checksum owners="$BATS_TEST_TMPDIR/source-owners"
    local expected_rc="$BATS_TEST_TMPDIR/expected-rc"
    listing=$(unsquashfs -lln "$sqsh")
    grep -E ' 0/0 .*squashfs-root/payload/data$' <<< "$listing"
    grep -E ' 1234/2345 .*squashfs-root/payload/owned$' <<< "$listing"
    # Record extraction ownership before entering Podman's user namespace.
    bash "$BATS_TEST_DIRNAME/filesystem-compare.bash" --owners "$extracted" > "$owners"
    local mkdir_line='mkdir -p "/app space" 2> /dev/null'
    local cd_line='cd "/app space" && unset OLDPWD || exit 1'
    [ "$(grep -Fxc -- "$mkdir_line" "$source_tree/etc/rc")" -eq 1 ]
    [ "$(grep -Fxc -- "$cd_line" "$source_tree/etc/rc")" -eq 1 ]
    grep -Fxv -e "$mkdir_line" -e "$cd_line" "$source_tree/etc/rc" > "$expected_rc"

    checksum=$(sha256sum "$sqsh")
    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 0 ]
    restore_image
    sha256sum --check <<< "$checksum"

    run with_image "$restored_tag" bash "$BATS_TEST_DIRNAME/filesystem-compare.bash" \
        "$source_tree" "$owners" "$expected_rc"
    [ "$status" -eq 0 ]
    if [[ -n $output ]]; then
        while IFS= read -r line; do printf '# %s\n' "$line"; done <<< "$output" >&3
    fi
}

read_metadata() {
    local feature=$1 root=$2
    case "$feature" in
        xattr)
            local result
            if result=$(LC_ALL=C getfattr --absolute-names --encoding=hex -n user.enroot_test -- "$root/payload" 2>&1); then
                sed -n 's/^user\.enroot_test=//p' <<< "$result"
            elif [[ $result == *'No such attribute'* || $result == *'Operation not supported'* ]]; then
                return 77
            else
                printf '%s\n' "$result" >&2
                return 1
            fi
            ;;
        acl) getfacl -ncp "$root/payload" ;;
        device)
            [[ -c $root/payload && ! -L $root/payload ]] || return 77
            stat -c '%a %t:%T' "$root/payload"
            ;;
    esac
}

assert_metadata() {
    local feature=$1 expected
    local extracted="$BATS_TEST_TMPDIR/source"
    export -f read_metadata
    pack_rootfs
    run --separate-stderr extract_source "$extracted"
    if [[ $feature == device && $status -ne 0 && $stderr == *payload* &&
        ( $stderr == *'Operation not permitted'* || $stderr == *'Permission denied'* ) ]]; then
        skip "Unprivileged SquashFS extraction cannot create the fixture device node"
    fi
    [ "$status" -eq 0 ]
    expected=$(read_metadata "$feature" "$source_tree")
    run read_metadata "$feature" "$extracted"
    if [[ $status -eq 77 || ( $status -eq 0 && $output != "$expected" ) ]]; then
        skip "$feature is unavailable after extracting the SquashFS fixture on this runner"
    fi
    [ "$status" -eq 0 ]

    # Probe the engine separately with a tar stream made from the fixture.
    # This keeps a storage limitation from masking a converter regression.
    tar --format=posix --numeric-owner --acls --xattrs -C "$source_tree" -cpf "$BATS_TEST_TMPDIR/probe.tar" .
    run timeout 30 "$PODMAN_BIN" import "$BATS_TEST_TMPDIR/probe.tar" "$probe_tag"
    if [[ $feature == device && $status -ne 0 && $output == *payload* &&
        ( $output == *'operation not permitted'* || $output == *'permission denied'* ) ]]; then
        skip "Podman storage cannot create the device node"
    fi
    [ "$status" -eq 0 ]
    run with_image "$probe_tag" bash -c 'read_metadata "$@"' bash "$feature"
    if [[ $status -eq 77 || ( $status -eq 0 && $output != "$expected" ) ]]; then
        skip "$feature is unavailable in this Podman store"
    fi
    [ "$status" -eq 0 ]

    run --separate-stderr --keep-empty-lines convert
    [ "$status" -eq 0 ]
    restore_image
    run with_image "$restored_tag" bash -c 'read_metadata "$@"' bash "$feature"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}

@test "preserves user extended attributes where supported" {
    command -v setfattr >/dev/null && command -v getfattr >/dev/null || skip "Extended attribute tools are unavailable"
    make_rootfs
    touch "$source_tree/payload"
    local value=0x76616c7565006279746573 # value, NUL, bytes
    run env LC_ALL=C setfattr -n user.enroot_test -v "$value" -- "$source_tree/payload"
    if [[ $status -ne 0 && $output == *'Operation not supported'* ]]; then
        skip "Fixture filesystem does not support user xattrs"
    fi
    [ "$status" -eq 0 ]
    [ "$(read_metadata xattr "$source_tree")" = "$value" ]
    assert_metadata xattr
}

@test "preserves a numeric POSIX ACL where supported" {
    command -v setfacl >/dev/null && command -v getfacl >/dev/null || skip "ACL tools are unavailable"
    make_rootfs
    touch "$source_tree/payload"
    run setfacl -m u:1234:r-- "$source_tree/payload"
    if [[ $status -ne 0 && $output == *'Operation not supported'* ]]; then
        skip "Fixture filesystem does not support POSIX ACLs"
    fi
    [ "$status" -eq 0 ]
    assert_metadata acl
}

@test "preserves a character device where supported" {
    make_rootfs
    run mknod -m 0600 "$source_tree/payload" c 1 3
    if [[ $status -ne 0 && ( $output == *'Operation not permitted'* || $output == *'Permission denied'* ) ]]; then
        skip "Converter user cannot create device nodes"
    fi
    [ "$status" -eq 0 ]
    assert_metadata device
}
