setup_file() {
    bats_require_minimum_version 1.11.0
    local tool rootless
    for tool in bash ldd jq mksquashfs unsquashfs tar script setsid timeout sync podman skopeo; do
        command -v "$tool" >/dev/null || { echo "Missing required test tool: $tool" >&2; return 1; }
    done
    unset CONTAINER_HOST CONTAINER_CONNECTION
    export PODMAN_BIN SKOPEO_BIN
    PODMAN_BIN=$(command -v podman)
    SKOPEO_BIN=$(command -v skopeo)
    rootless=$(timeout 20 "$PODMAN_BIN" info --format '{{.Host.Security.Rootless}}')
    if [[ $(id -u) == 0 || $rootless != true ]]; then
        echo "CAS round-trip tests require an unprivileged user with local rootless Podman" >&2
        return 1
    fi
}

setup() {
    export LC_ALL=C.UTF-8
    unset BASH_ENV ENV CDPATH ENROOT_TEST_MISSING ENROOT_TEST_INVALID_IMPORT
    repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    find_converter "$repo"
    round_trip="${ENROOT_CAS_ROUND_TRIP:-$repo/target/debug/examples/cas-round-trip}"
    [[ -f $round_trip && -x $round_trip ]] || {
        printf 'CAS round-trip helper must be an executable file (%s)\n' "$round_trip" >&2
        echo "Build it with cargo build --locked --example cas-round-trip or set ENROOT_CAS_ROUND_TRIP to its executable" >&2
        return 1
    }
    local id="${BATS_RUN_TMPDIR##*/}-$BATS_SUITE_TEST_NUMBER"
    container="enroot-test-${id,,}"
    cas_tag="localhost/$container:converted"
    restored_tag="localhost/$container:restored"
    probe_tag="localhost/$container:probe"
    source_tree="$BATS_TEST_TMPDIR/root"
    sqsh="$BATS_TEST_TMPDIR/fixture image.sqsh"
    terminal_log="$BATS_TEST_TMPDIR/terminal"
    store="$BATS_TEST_TMPDIR/cas"
    assert_podman_absent container "$container"
    assert_podman_absent image "$restored_tag"
    assert_podman_absent image "$probe_tag"
    fixtures_ready=1
    prepare_converter_config
}

teardown() {
    if [[ ${fixtures_ready:-} == 1 ]]; then
        local cleanup_status=0
        local -a images=("$restored_tag" "$probe_tag")
        if [[ -s $BATS_TEST_TMPDIR/staging-tag ]]; then
            images+=("$(cat "$BATS_TEST_TMPDIR/staging-tag")")
        fi
        timeout 20 "$PODMAN_BIN" rm --ignore --force "$container" >/dev/null || cleanup_status=$?
        timeout 20 "$PODMAN_BIN" image rm --ignore --no-prune -- "${images[@]}" >/dev/null || cleanup_status=$?
        return "$cleanup_status"
    fi
}

load converter-executable

prepare_converter_config() {
    local config="$BATS_TEST_TMPDIR/config"
    mkdir -p "$config/sarus-suite"
    # Persist the directories leading to the CAS parent before import initializes the store.
    sync -- "${BATS_RUN_TMPDIR%/*}" "$BATS_RUN_TMPDIR" "${BATS_TEST_TMPDIR%/*}" "$BATS_TEST_TMPDIR"
    cat > "$config/sarus-suite/test.conf" <<'CONFIG'
hpc_image_store = '${BATS_TEST_TMPDIR}/cas'
podman_path = '${BATS_TEST_TMPDIR}/configured-podman'
skopeo_path = '${BATS_TEST_TMPDIR}/configured-skopeo'
CONFIG
    cat > "$BATS_TEST_TMPDIR/configured-podman" <<'SHIM'
#!/usr/bin/env bash
if [[ -v ENROOT_TEST_CALLER_XDG_CONFIG_HOME ]]; then
    export XDG_CONFIG_HOME="$ENROOT_TEST_CALLER_XDG_CONFIG_HOME"
else
    unset XDG_CONFIG_HOME
fi
if [[ -v ENROOT_TEST_CALLER_XDG_CONFIG_DIRS ]]; then
    export XDG_CONFIG_DIRS="$ENROOT_TEST_CALLER_XDG_CONFIG_DIRS"
else
    unset XDG_CONFIG_DIRS
fi
if [[ ${0##*/} == configured-skopeo ]]; then
    exec "$SKOPEO_BIN" "$@"
fi
if [[ $1 != import ]]; then
    exec "$PODMAN_BIN" "$@"
fi
printf '%s\n' "${@: -1}" > "$BATS_TEST_TMPDIR/staging-tag"
if [[ ${ENROOT_TEST_INVALID_IMPORT:-} == 1 ]]; then
    cat >/dev/null || exit
    "$PODMAN_BIN" "$@" <<< 'invalid archive'
else
    "$PODMAN_BIN" "$@"
fi
status=$?
printf '%s\n' "$status" > "$BATS_TEST_TMPDIR/import-status"
exit "$status"
SHIM
    chmod +x "$BATS_TEST_TMPDIR/configured-podman"
    ln -s configured-podman "$BATS_TEST_TMPDIR/configured-skopeo"

    local -a unset_backups=() backups=()
    local name backup
    for name in XDG_CONFIG_HOME XDG_CONFIG_DIRS; do
        backup="ENROOT_TEST_CALLER_$name"
        if [[ -v $name ]]; then
            backups+=("$backup=${!name}")
        else
            unset_backups+=(-u "$backup")
        fi
    done
    converter=(env "${unset_backups[@]}" "${backups[@]}"
        XDG_CONFIG_HOME="$config" XDG_CONFIG_DIRS="$config" "${converter[@]}")
}

assert_podman_absent() {
    local status=0
    timeout 20 "$PODMAN_BIN" "$1" exists -- "$2" || status=$?
    if [[ $status != 1 ]]; then
        printf 'Expected Podman %s %s to be absent (exists status %s)\n' "$1" "$2" "$status" >&2
        return 1
    fi
}

assert_unpublished() {
    [[ -z $output && ! -e $store ]] && assert_podman_absent image "$restored_tag"
}

restore_image() {
    local staging_tag
    staging_tag=$(cat "$BATS_TEST_TMPDIR/staging-tag") || return
    assert_podman_absent image "$staging_tag" || return
    timeout --kill-after=5 45 "$round_trip" --podman "$PODMAN_BIN" --skopeo "$SKOPEO_BIN" \
        "$store" "$cas_tag" "$output" "$restored_tag"
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
    timeout --kill-after=5 45 setsid --wait "${converter[@]}" "$@" "$sqsh" "$cas_tag" </dev/null
}

convert_with_terminal() {
    run_with_terminal "$1" "$terminal_log" "${converter[@]}" "$sqsh" "$cas_tag"
}

container_run() {
    timeout --kill-after=5 30 "$PODMAN_BIN" run --pull=never --network=none --rm --name "$container" "$@"
}

inspect_config() {
    local inspect
    inspect=$(timeout 20 "$PODMAN_BIN" image inspect "$restored_tag") && jq -e '.[0].Config' <<< "$inspect"
}

assert_env() {
    local config
    config=$(inspect_config) || return
    # Test keys are prefixed to isolate them from any defaults Podman adds.
    jq -e --args '
        [.Env[]? | select(startswith("T_") or startswith("ENROOT_"))] | sort == ($ARGS.positional | sort)
    ' "$@" <<< "$config"
}

assert_no_import() {
    [[ ! -e $BATS_TEST_TMPDIR/staging-tag ]] && assert_unpublished
}
