load terminal

setup_file() {
    bats_require_minimum_version 1.11.0
}

setup() {
    export LC_ALL=C.UTF-8
    unset BASH_ENV ENV CDPATH MISSING MOCK_IMPORT_STATUS SOME_HOST DYNAMIC_KEY name IGNORED
    unset MOCK_TAR_STATUS MOCK_TAR_BLOCK MOCK_TAR_SIGNAL LATER
    converter=(bash "$BATS_TEST_DIRNAME/../enroot-to-oci.sh")
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
    cat > "$bin/podman" <<'SH'
#!/usr/bin/env bash
set -e
printf '%s\0' "$@" > "$CAPTURE.args"
cat > "$CAPTURE.tar"
exit "${MOCK_IMPORT_STATUS:-0}"
SH
    chmod +x "$bin"/{unsquashfs,podman}
    if [[ -n ${ENROOT_CONVERTER:-} ]]; then
        local executable
        executable=$(command -v -- "$ENROOT_CONVERTER") && [[ -x $executable ]] || {
            echo "ENROOT_CONVERTER must name an executable: $ENROOT_CONVERTER" >&2
            return 1
        }
        export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_CONFIG_DIRS="$BATS_TEST_TMPDIR/config"
        configured_podman="$BATS_TEST_TMPDIR/configured podman"
        mkdir -p "$XDG_CONFIG_HOME/sarus-suite"
        printf "podman_path = '%s'\n" "$configured_podman" > "$XDG_CONFIG_HOME/sarus-suite/stage-two.conf"
        mv "$bin/podman" "$configured_podman"
        printf '#!/bin/sh\nexit 98\n' > "$bin/podman"
        chmod +x "$bin/podman"
        converter=("$executable" --store "$BATS_TEST_TMPDIR/unused-store")
    fi
    export PATH="$bin:$PATH"
}

teardown() {
    cmp "$BATS_TEST_TMPDIR/original-rc" "$FIXTURE/etc/rc"
    [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
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
    [ "${args[-1]}" = "$tag" ]
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
    [ ! -e "$CAPTURE.args" ] && [ ! -e "$CAPTURE.tar" ]
}
