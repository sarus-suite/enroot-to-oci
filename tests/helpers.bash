setup_file() {
    bats_require_minimum_version 1.11.0
    local tool
    for tool in bash ldd jq mksquashfs unsquashfs tar script setsid timeout podman; do
        command -v "$tool" >/dev/null || { echo "Missing required test tool: $tool" >&2; return 1; }
    done
    unset CONTAINER_HOST CONTAINER_CONNECTION
    export PODMAN_BIN PODMAN_ROOTLESS
    PODMAN_BIN=$(command -v podman)
    PODMAN_ROOTLESS=$(timeout 20 "$PODMAN_BIN" info --format '{{.Host.Security.Rootless}}')
    [[ "$PODMAN_ROOTLESS" == true || "$PODMAN_ROOTLESS" == false ]]
}

setup() {
    export LC_ALL=C.UTF-8
    unset BASH_ENV ENV CDPATH ENROOT_TEST_MISSING
    repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    converter=(bash "$repo/enroot-to-oci.sh")
    if [[ -n ${ENROOT_CONVERTER:-} ]]; then
        local executable
        executable=$(command -v -- "$ENROOT_CONVERTER") &&
            [[ -f "$executable" && -x "$executable" ]] || {
                echo "ENROOT_CONVERTER must name an executable: $ENROOT_CONVERTER" >&2
                return 1
            }
        converter=("$executable")
    fi
    local id="${BATS_RUN_TMPDIR##*/}-$BATS_SUITE_TEST_NUMBER"
    container="enroot-test-${id,,}"
    tag="localhost/$container:converted"
    probe_tag="localhost/$container:probe"
    source_tree="$BATS_TEST_TMPDIR/root"
    sqsh="$BATS_TEST_TMPDIR/fixture image.sqsh"
    terminal_log="$BATS_TEST_TMPDIR/terminal"
}

teardown() {
    if [[ -n ${container:-} ]]; then
        local cleanup_status=0
        timeout 20 "$PODMAN_BIN" rm --ignore --force "$container" >/dev/null || cleanup_status=$?
        timeout 20 "$PODMAN_BIN" image rm --ignore "$tag" "$probe_tag" >/dev/null
        return "$cleanup_status"
    fi
}

make_rootfs() {
    local libraries library
    mkdir -p "$source_tree"/{bin,etc,'app space',override}
    cp -L /bin/bash "$source_tree/bin/bash"
    ln -s bash "$source_tree/bin/sh"

    libraries=$(ldd /bin/bash)
    if [[ $libraries == *'not found'* ]]; then
        echo "$libraries" >&2
        return 1
    fi
    while IFS= read -r library; do
        cp -L --parents "$library" "$source_tree"
    done < <(awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// { print $1 }' <<< "$libraries")

    cat > "$source_tree/etc/rc" <<'RC'
# enroot-provenance: docker://example/image:tag

mkdir -p "/app space" 2> /dev/null
cd "/app space" && unset OLDPWD || exit 1

if [ -s /etc/rc.local ]; then
    . /etc/rc.local
fi

if [ "$#" -gt 0 ]; then
    exec /bin/bash /startup "$@"
else
    exec /bin/bash /startup 'default command'
fi
RC
    cat > "$source_tree/etc/rc.local" <<'RC_LOCAL'
export ENROOT_TEST_RC_LOCAL=sourced
RC_LOCAL
    cat > "$source_tree/startup" <<'STARTUP'
printf 'cwd=<%s>\nrc.local=<%s>\n' "$PWD" "$ENROOT_TEST_RC_LOCAL"
printf 'arg=<%s>\n' "$@"
STARTUP
}

pack_rootfs() {
    mksquashfs "$source_tree" "$sqsh" -noappend -all-root -processors 1 -quiet -no-progress "$@"
}

convert() {
    timeout --kill-after=5 45 setsid --wait "${converter[@]}" "$@" "$sqsh" "$tag" </dev/null
}

convert_with_terminal() {
    run_with_terminal "$1" "$terminal_log" "${converter[@]}" "$sqsh" "$tag"
}

container_run() {
    timeout --kill-after=5 30 "$PODMAN_BIN" run --pull=never --network=none --rm --name "$container" "$@"
}

inspect_config() {
    local inspect
    inspect=$(timeout 20 "$PODMAN_BIN" image inspect "$tag") && jq -e '.[0].Config' <<< "$inspect"
}

assert_env() {
    local config
    config=$(inspect_config) || return
    # Test keys are prefixed to isolate them from any defaults Podman adds.
    jq -e --args '
        [.Env[]? | select(startswith("T_") or startswith("ENROOT_"))] | sort == ($ARGS.positional | sort)
    ' "$@" <<< "$config"
}

# Negative tests use a pass-through wrapper around the real engine to observe
# whether import was called and which exit status it returned.
trace_import() {
    mkdir "$BATS_TEST_TMPDIR/trace-bin"
    export IMPORT_TRACE="$BATS_TEST_TMPDIR/import-status"
    cat > "$BATS_TEST_TMPDIR/trace-bin/podman" <<'SHIM'
#!/usr/bin/env bash
if [[ $1 != import ]]; then
    exec "$PODMAN_BIN" "$@"
fi
"$PODMAN_BIN" "$@"
status=$?
printf '%s\n' "$status" >> "$IMPORT_TRACE"
exit "$status"
SHIM
    chmod +x "$BATS_TEST_TMPDIR/trace-bin/podman"
    export PATH="$BATS_TEST_TMPDIR/trace-bin:$PATH"
}
