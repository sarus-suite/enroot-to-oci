#!/usr/bin/env bash
set -euo pipefail

if [[ $1 == --owners ]]; then
    exec find -P "$2" -mindepth 1 -printf '%P\0%U:%G\0'
fi

source_tree=$1
owners_file=$2
expected_rc=$3
restored_tree=$4
paths=${owners_file%/*}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

list_paths() {
    find -P "$1" -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z
}

list_paths "$source_tree" > "$paths/source-paths"
list_paths "$restored_tree" > "$paths/restored-paths"
cmp "$paths/source-paths" "$paths/restored-paths" || fail 'Image paths differ from fixture paths'

declare -A extracted_owners=() source_inodes=() image_inodes=() ownership_losses=()
while IFS= read -r -d '' relative && IFS= read -r -d '' owner; do
    extracted_owners[$relative]=$owner
done < "$owners_file"

while IFS= read -r -d '' relative; do
    before=$source_tree/$relative
    after=$restored_tree/$relative
    before_metadata=$(stat -c '%f %d:%i' -- "$before")
    after_metadata=$(stat -c '%f %d:%i %u:%g' -- "$after")
    read -r before_mode before_inode <<< "$before_metadata"
    read -r after_mode after_inode after_owner <<< "$after_metadata"
    [[ $before_mode == "$after_mode" ]] || fail "$relative: expected mode $before_mode, got $after_mode (hex)"

    expected_owner=0:0
    if [[ $relative == payload/owned ]]; then expected_owner=1234:2345; fi
    if [[ $after_owner != "$expected_owner" ]]; then
        baseline=${extracted_owners[$relative]-unavailable}
        [[ $after_owner == "$baseline" ]] ||
            fail "$relative: expected $expected_owner, got $after_owner (unprivileged extraction: $baseline)"
        ownership_losses["$expected_owner, restored $after_owner"]=1
    fi

    if [[ -L $before ]]; then
        IFS= read -r -d '' before_target < <(readlink -z -- "$before")
        IFS= read -r -d '' after_target < <(readlink -z -- "$after")
        [[ $before_target == "$after_target" ]] || fail "$relative: symlink target differs"
    elif [[ -f $before ]]; then
        if [[ $relative == etc/rc ]]; then before=$expected_rc; fi
        cmp "$before" "$after" || fail "$relative: contents differ"
        source_inodes[$before_inode]=${source_inodes[$before_inode]-$relative}
        image_inodes[$after_inode]=${image_inodes[$after_inode]-$relative}
        [[ ${source_inodes[$before_inode]} == "${image_inodes[$after_inode]}" ]] ||
            fail "$relative: hardlink relationship differs"
    fi
done < "$paths/source-paths"

if ((${#ownership_losses[@]})); then
    printf 'Rootless extraction ownership: SquashFS %s\n' "${!ownership_losses[@]}" | LC_ALL=C sort
fi
