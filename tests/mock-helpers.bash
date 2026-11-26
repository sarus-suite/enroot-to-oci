load terminal
load converter-executable

setup_file() {
    bats_require_minimum_version 1.11.0
}

setup() {
    export LC_ALL=C.UTF-8
    unset BASH_ENV ENV CDPATH MISSING MOCK_IMPORT_STATUS SOME_HOST DYNAMIC_KEY name IGNORED
    unset MOCK_TAR_STATUS MOCK_TAR_BLOCK MOCK_TAR_SIGNAL MOCK_PODMAN_DISAPPEARS LATER
    find_converter "$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    sqsh="$BATS_TEST_TMPDIR/fixture image.sqsh"
    tag=localhost/example:tag
    terminal_log="$BATS_TEST_TMPDIR/terminal"
    export FIXTURE="$BATS_TEST_TMPDIR/fixture" CAPTURE="$BATS_TEST_TMPDIR/import"
    export TMPDIR="$BATS_TEST_TMPDIR/staging"
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FIXTURE"/{bin,etc} "$bin" "$TMPDIR"
    touch "$FIXTURE/bin/bash" "$FIXTURE/etc/environment" "$sqsh"
    chmod 0755 "$FIXTURE/bin/bash"
    cat > "$BATS_TEST_TMPDIR/expected-rc" <<'RC'
# enroot-provenance: docker://example/name:tag

if [ -s /etc/rc.local ]; then
    . /etc/rc.local
fi
exec /bin/sh "$@"
RC
    sed '1a\
mkdir -p "/app space" 2> /dev/null\
cd "/app space" \&\& unset OLDPWD || exit 1
' "$BATS_TEST_TMPDIR/expected-rc" > "$FIXTURE/etc/rc"
    cp "$FIXTURE/etc/rc" "$BATS_TEST_TMPDIR/original-rc"
    cat > "$bin/unsquashfs" <<'SH'
#!/usr/bin/env bash
while (($#)); do
    if [[ $1 == -dest ]]; then
        cp -a -- "$FIXTURE" "$2"
        exit $?
    fi
    shift
done
exit 2
SH
    configured_podman="$BATS_TEST_TMPDIR/configured podman"
    cat > "$configured_podman" <<'SH'
#!/usr/bin/env bash
set -e
state="$BATS_TEST_TMPDIR/podman-tag"
case "$1 $2" in
    'image exists')
        [[ $3 == -- ]] || exit 98
        if [[ ${MOCK_PODMAN_DISAPPEARS:-} == 1 ]]; then
            mv -- "$0" "$0.disabled"
            exit 1
        fi
        [[ -f $state && $4 == "$(cat "$state")" ]]
        ;;
    'import --change')
        printf '%s\0' "$@" > "$CAPTURE.args"
        cat > "$CAPTURE.tar"
        if [[ ${MOCK_IMPORT_STATUS:-0} == 0 ]]; then
            printf '%s\n' "${@: -1}" > "$state"
        fi
        exit "${MOCK_IMPORT_STATUS:-0}"
        ;;
    'image rm')
        [[ $3 == --ignore && $4 == --no-prune && $5 == -- ]] || exit 98
        if [[ -e $state ]]; then
            [[ $6 == "$(cat "$state")" ]] || exit 98
            unlink "$state"
        fi
        ;;
    *)
        exit 98
        ;;
esac
SH
    cat > "$BATS_TEST_TMPDIR/configured skopeo" <<'SH'
#!/usr/bin/env bash
[[ $1 == copy && $2 == --help && -s $BATS_TEST_TMPDIR/podman-tag ]] || exit 98
echo 'stopping publication after capturing Podman import' >&2
exit 97
SH
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_CONFIG_DIRS="$BATS_TEST_TMPDIR/config"
    mkdir -p "$XDG_CONFIG_HOME/sarus-suite"
    cat > "$XDG_CONFIG_HOME/sarus-suite/test.conf" <<'CONFIG'
hpc_image_store = '${BATS_TEST_TMPDIR}/cas'
podman_path = '${BATS_TEST_TMPDIR}/configured podman'
skopeo_path = '${BATS_TEST_TMPDIR}/configured skopeo'
CONFIG
    printf '#!/bin/sh\nexit 98\n' > "$bin/podman"
    sync -- "${BATS_RUN_TMPDIR%/*}" "$BATS_RUN_TMPDIR" "${BATS_TEST_TMPDIR%/*}" "$BATS_TEST_TMPDIR"
    chmod +x "$bin"/{unsquashfs,podman} "$configured_podman" "$BATS_TEST_TMPDIR/configured skopeo"
    export PATH="$bin:$PATH"
}

teardown() {
    cmp "$BATS_TEST_TMPDIR/original-rc" "$FIXTURE/etc/rc"
    [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
    [ ! -e "$BATS_TEST_TMPDIR/podman-tag" ]
}

convert() {
    timeout --kill-after=5 10 setsid --wait "${converter[@]}" "$@" "$sqsh" "$tag" </dev/null
}

assert_import() {
    local -a args env_changes=()
    local i change assignment key value workdir= entrypoint=
    mapfile -d '' -t args < "$CAPTURE.args"
    [ "${args[0]}" = import ]
    [ "${args[-2]}" = - ]
    [[ ${args[-1]} =~ ^localhost/enroot-to-oci-stage:[[:xdigit:]]{32}$ ]]
    for ((i=1; i<${#args[@]}-2; i+=2)); do
        [ "${args[i]}" = --change ] || return 1
        change=${args[i+1]}
        case "$change" in
            'WORKDIR /app space') workdir=present ;;
            'ENTRYPOINT ["/bin/bash","/etc/rc"]') entrypoint=present ;;
            'ENV '*)
                assignment=${change#ENV }
                key=${assignment%%=*}
                value=${assignment#*=}
                [[ $value == \"*\" ]] || return 1
                env_changes+=("$key=${value:1:${#value}-2}")
                ;;
        esac
    done
    [ "$workdir" = present ] && [ "$entrypoint" = present ] || return 1
    tar -xOf "$CAPTURE.tar" ./etc/rc > "$BATS_TEST_TMPDIR/staged-rc" || return
    cmp "$BATS_TEST_TMPDIR/expected-rc" "$BATS_TEST_TMPDIR/staged-rc" || return
    cmp <(printf '%s\0' "${env_changes[@]}" | sort -z) <(printf '%s\0' "$@" | sort -z)
}

assert_quiet_host_policy() {
    [[ $stderr != *'Enroot host expansion'* && $stderr != *'omitted host-dependent'* ]]
}

assert_no_import() {
    [ ! -e "$CAPTURE.args" ] && [ ! -e "$CAPTURE.tar" ] && [ -z "$output" ]
}

assert_publication_stopped() {
    [ "$status" -eq 1 ] &&
        [[ $stderr == *'stopping publication after capturing Podman import'* ]] &&
        [ -z "$output" ] &&
        [ ! -e "$BATS_TEST_TMPDIR/podman-tag" ]
}
