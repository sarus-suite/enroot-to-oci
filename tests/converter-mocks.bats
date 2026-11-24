#!/usr/bin/env bats

load terminal

setup_file() {
    bats_require_minimum_version 1.11.0
}

setup() {
    export LC_ALL=C.UTF-8
    unset BASH_ENV ENV CDPATH MISSING MOCK_IMPORT_STATUS SOME_HOST DYNAMIC_KEY name IGNORED
    converter=(bash "$BATS_TEST_DIRNAME/../enroot-to-oci.sh")
    sqsh="$BATS_TEST_TMPDIR/fixture image.sqsh"
    tag=localhost/example:tag
    terminal_log="$BATS_TEST_TMPDIR/terminal"
    export FIXTURE="$BATS_TEST_TMPDIR/fixture" CAPTURE="$BATS_TEST_TMPDIR/import"
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FIXTURE"/{bin,etc} "$bin"
    touch "$FIXTURE/bin/bash" "$FIXTURE/etc/environment" "$sqsh"
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
    export PATH="$bin:$PATH"
}

teardown() {
    cmp "$BATS_TEST_TMPDIR/original-rc" "$FIXTURE/etc/rc"
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

@test "mock import retains literal values and ignores malformed or reserved assignments" {
    cat > "$FIXTURE/etc/environment" <<'ENV'
   # ignore

A=hello world
B='a word'
C="contains # hash and spaces"
D=literal$UNSET
E="escape\slash \"nested\""
ENROOT_TEST=filtered
BAD-NAME=discard
export NOT_VALID=nope
 EQ=1=2
MISMATCH='x"
A=replaced
BAD=""
HAS_EQ=a=b
EMPTY=
UNICODE=crème 雪
BAD-NAME=${IGNORED}
# ${IGNORED}
ENROOT_TEST=${SOME_HOST}
ENV
    printf '%s\n' 'K=ends with spaces   ' "L='quoted trailing space'   " >> "$FIXTURE/etc/environment"
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    assert_quiet_host_policy
    assert_import 'A=replaced' 'B=a word' 'C=contains # hash and spaces' 'D=literal$UNSET' \
        'E=escape\slash \"nested\"' 'EQ=1=2' 'MISMATCH=x' 'BAD=' 'HAS_EQ=a=b' 'EMPTY=' \
        'UNICODE=crème 雪' 'K=ends with spaces   ' 'L=quoted trailing space'
}

@test "mock import omits host-dependent values and allows later static assignments" {
    printf '%s\n' 'A=old' 'A=${SOME_HOST}' 'B=new' 'C=again' 'C=${SOME_HOST}' 'C=last' \
        > "$FIXTURE/etc/environment"
    run --separate-stderr convert --skip-dynamic-env
    [ "$status" -eq 0 ]
    assert_quiet_host_policy
    assert_import 'B=new' 'C=last'
}

@test "mock import expands inherited values and dynamic names" {
    export SOME_HOST=WORLD name=exported DYNAMIC_KEY=' KEY'
    printf '%s\n' 'A=hello_${SOME_HOST}-${MISSING}' 'B="${SOME_HOST}"' 'VALUE=${name}' '${DYNAMIC_KEY}=named' \
        > "$FIXTURE/etc/environment"
    run --separate-stderr convert --resolve-host-env
    [ "$status" -eq 0 ]
    assert_quiet_host_policy
    assert_import 'A=hello_WORLD-' 'B=WORLD' 'VALUE=exported' 'KEY=named'
}

@test "mock import is never reached for unattended host expansion without a policy" {
    printf '%s\n' 'A=${SOME_HOST}' > "$FIXTURE/etc/environment"
    run --separate-stderr convert
    [ "$status" -eq 1 ]
    [[ $stderr == *'--skip-dynamic-env'* && $stderr == *'--resolve-host-env'* ]]
    assert_no_import
}

@test "mock import is never reached when a host value contains a newline" {
    export SOME_HOST=$'FIRST\nSECOND'
    printf '%s\n' 'A=${SOME_HOST}' > "$FIXTURE/etc/environment"
    run --separate-stderr convert --resolve-host-env
    [ "$status" -ne 0 ]
    assert_no_import
}

@test "mock import is never reached for conflicting or removed options" {
    printf '%s\n' 'A=${SOME_HOST}' > "$FIXTURE/etc/environment"
    run --separate-stderr convert --skip-dynamic-env --resolve-host-env
    [ "$status" -eq 2 ]
    assert_no_import
    run --separate-stderr convert --oci-layout unused
    [ "$status" -eq 2 ]
    assert_no_import
}

@test "mock import observes one terminal prompt and honors each reply" {
    export SOME_HOST=host
    printf '%s\n' 'A=old' 'A=${SOME_HOST}' 'B=${MISSING}' 'C=${SOME_HOST}' 'C=last' \
        > "$FIXTURE/etc/environment"
    local reply
    for reply in enter eof no yes; do
        terminal_log="$BATS_TEST_TMPDIR/terminal-$reply"
        CAPTURE="$BATS_TEST_TMPDIR/import-$reply"
        run --separate-stderr run_with_terminal "$reply" "$terminal_log" "${converter[@]}" "$sqsh" "$tag"
        [ "$status" -eq 0 ]
        assert_single_prompt
        if [[ $reply == yes ]]; then
            assert_import 'A=host' 'B=' 'C=last'
        else
            assert_import 'C=last'
        fi
    done
}

@test "mock import failure is propagated without a completion message" {
    export MOCK_IMPORT_STATUS=42
    printf '%s\n' 'A=static' > "$FIXTURE/etc/environment"
    run --separate-stderr convert
    [ "$status" -eq 42 ]
    [[ $stderr != *'Done:'* && $output != *'Done:'* ]]
    assert_import 'A=static'
}
