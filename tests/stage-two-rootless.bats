#!/usr/bin/env bats

load helpers

@test "stages and runs an image with Bash only at /usr/bin/bash" {
    [[ -n ${ENROOT_CONVERTER:-} ]] || skip 'set ENROOT_CONVERTER to the stage-two-driver example'
    make_rootfs
    mkdir -p "$source_tree/usr/bin"
    mv "$source_tree/bin/bash" "$source_tree/usr/bin/bash"
    sed -i 's@/bin/bash@/usr/bin/bash@g' "$source_tree/etc/rc"
    pack_rootfs
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    jq -e '.Entrypoint == ["/usr/bin/bash", "/etc/rc"] and ((.Cmd // []) | length == 0)' <<< "$(inspect_config)"

    run container_run -w /override "$tag" 'two words'
    [ "$status" -eq 0 ]
    [ "$output" = $'cwd=</override>\nrc.local=<sourced>\narg=<two words>' ]
}

@test "preserves trailing whitespace in the stored and runtime working directory" {
    [[ -n ${ENROOT_CONVERTER:-} ]] || skip 'set ENROOT_CONVERTER to the stage-two-driver example'
    make_rootfs
    local workdir='/workdir '
    mkdir "$source_tree/workdir" "$source_tree$workdir"
    sed -i "s@/app space@$workdir@g" "$source_tree/etc/rc"
    pack_rootfs
    run --separate-stderr convert
    [ "$status" -eq 0 ]
    jq -e --arg expected "$workdir" '.WorkingDir == $expected' <<< "$(inspect_config)"

    run container_run "$tag"
    [ "$status" -eq 0 ]
    [ "$output" = $'cwd=</workdir >\nrc.local=<sourced>\narg=<default command>' ]

    run container_run -w /override "$tag"
    [ "$status" -eq 0 ]
    [ "$output" = $'cwd=</override>\nrc.local=<sourced>\narg=<default command>' ]
}
