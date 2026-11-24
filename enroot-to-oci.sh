#!/usr/bin/env bash
# Convert an Enroot SquashFS image into a Podman image.
# Requires: bash, squashfs-tools (unsquashfs), GNU tar, podman.
set -Eeuo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: enroot-to-oci.sh [--skip-dynamic-env | --resolve-host-env] [--allow-unrecognized-rc] IMAGE.sqsh IMAGE_TAG
Example: enroot-to-oci.sh image.sqsh localhost/image:latest

--skip-dynamic-env   Omit assignments using Enroot host substitutions (${NAME}).
                     Clear any earlier value for that key. A later static
                     assignment can restore it. Pass needed values with `podman run -e`.
--resolve-host-env    Expand ${NAME} using the converter's environment (unset
                     variables become empty), freezing values into the image.
                     May embed credentials in image metadata. Without either
                     flag, a terminal prompt defaults to omission. Unattended
                     conversion of host-dependent assignments requires a flag.
--allow-unrecognized-rc
                     Keep custom /etc/rc scripts unchanged if the generated Enroot
                     working-directory block cannot be recognized. WARNING: in
                     that case podman -w may still be overridden by /etc/rc.
USAGE
    exit 2
}

skip_dynamic_env=0
resolve_host_env=0
allow_unrecognized_rc=0
while (($#)); do
    case "$1" in
        --skip-dynamic-env) skip_dynamic_env=1; shift ;;
        --resolve-host-env) resolve_host_env=1; shift ;;
        --allow-unrecognized-rc) allow_unrecognized_rc=1; shift ;;
        --help|-h) usage ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done
(($# == 2)) || usage
if ((skip_dynamic_env && resolve_host_env)); then
    echo '--skip-dynamic-env and --resolve-host-env are mutually exclusive' >&2
    exit 2
fi
sqsh=$(realpath -- "$1")
tag=$2
[[ -f $sqsh ]] || { echo "Not a file: $sqsh" >&2; exit 1; }
for cmd in unsquashfs tar podman mktemp; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
rootfs=$tmp/rootfs

printf 'Extracting %s ...\n' "$sqsh" >&2
unsquashfs -no-progress -dest "$rootfs" "$sqsh" >&2

# The converter reads and edits files under rootfs/etc. Do not follow
# user-supplied symlinks outside the extraction tree during that operation.
if [[ -L $rootfs/etc ]]; then
    echo 'Unsupported rootfs: /etc is a symlink' >&2; exit 1
fi
for config_file in rc environment fstab; do
    if [[ -L $rootfs/etc/$config_file ]]; then
        echo "Unsupported rootfs: /etc/$config_file is a symlink" >&2; exit 1
    fi
done

changes=()

# The Enroot Docker importer renders OCI WorkingDir into these two consecutive
# commands in /etc/rc (src/docker.sh, docker::configure):
#     mkdir -p "/original/workdir" 2> /dev/null
#     cd "/original/workdir" && unset OLDPWD || exit 1
# Let Podman manage the process cwd instead: set image Config.WorkingDir and
# remove ONLY this recognized Enroot-generated pair from the copied /etc/rc.
# Otherwise the rc script would override `podman run --workdir ...`.
extract_workdir_from_rc() {
    local rc=$1 i path found=0
    local -a lines=() edited=()
    mapfile -t lines < "$rc"
    for ((i=0; i<${#lines[@]}; ++i)); do
        if [[ ${lines[i]} =~ ^mkdir[[:space:]]+-p[[:space:]]+\"([^\"]*)\"[[:space:]]+2\>[[:space:]]*/dev/null$ ]]; then
            path=${BASH_REMATCH[1]}
            # Do not interpret shell syntax encoded in the imported workdir.
            # Workdirs containing shell expansions/escapes need a manual review.
            if [[ $path == /* && $path != *'\'* && $path != *'$'* && $path != *'`'* ]] &&
                ((i + 1 < ${#lines[@]})) &&
                [[ ${lines[i+1]} == "cd \"$path\" && unset OLDPWD || exit 1" ]]; then
                ((found+=1))
                workdir=$path
                ((i+=1))    # drop both lines
                continue
            fi
        fi
        edited+=("${lines[i]}")
    done
    if ((found == 1)); then
        # Overwrite the extracted copy only, leaving the source SquashFS intact.
        printf '%s\n' "${edited[@]}" > "$rc"
        return 0
    fi
    return 1
}

if [[ -e $rootfs/etc/rc ]]; then
    [[ -d $rootfs/etc && ! -L $rootfs/etc && -f $rootfs/etc/rc && ! -L $rootfs/etc/rc ]] || {
        echo 'Unsafe or unsupported /etc/rc (symlink or nonregular file)' >&2; exit 1;
    }
    [[ -f $rootfs/bin/bash || -f $rootfs/usr/bin/bash ]] || {
        echo 'Enroot /etc/rc exists but Bash is not present in the rootfs' >&2; exit 1;
    }
    workdir=/
    if extract_workdir_from_rc "$rootfs/etc/rc"; then
        printf 'Recovered OCI WORKDIR: %s (removed Enroot generated cd from staged /etc/rc)\n' "$workdir" >&2
        changes+=(--change "WORKDIR $workdir")
    elif ((allow_unrecognized_rc)); then
        echo 'WARNING: no recognizable Enroot-generated WORKDIR; preserving /etc/rc unchanged.' >&2
        echo 'WARNING: /etc/rc may override `podman run -w` if it changes directory.' >&2
    else
        echo 'Cannot safely recover WORKDIR from /etc/rc; refusing to produce an image with misleading -w behavior.' >&2
        echo 'Use --allow-unrecognized-rc to keep it unchanged, or manually adapt the startup script.' >&2
        exit 1
    fi
    # Keep the original Enroot script logic for rc.local, entrypoint and CMD.
    changes+=(--change 'ENTRYPOINT ["/bin/bash","/etc/rc"]')
else
    echo 'WARNING: no /etc/rc; using /bin/sh as a fallback entrypoint' >&2
    changes+=(--change 'ENTRYPOINT ["/bin/sh"]')
fi

# Enroot's environment syntax is defined by src/common.sh (common::envsubst
# then common::envfmt), not by Bash or the generic dotenv syntax:
#   - Substitute ONLY ${NAME} from the host, before formatting.
#   - Remove leading whitespace, ignore blank/comment/malformed lines.
#   - Drop ENROOT_* entries, strip one pair of surrounding single/double
#     quotes (even if quote styles differ), and retain other bytes verbatim.
#   - No shell escaping, interpolation of $NAME, export syntax or inline
#     comment removal. Repeated variables have last-assignment-wins semantics
#     (bin/common.h: load_environment_fd uses setenv(..., 1)).
#
# Read the initial process environment so Bash locals and assignments cannot
# shadow exported values. NUL delimiters preserve newlines for validation.
declare -A host_env=()
load_host_environment() {
    local entry key
    while IFS= read -r -d '' entry; do
        key=${entry%%=*}
        [[ -n $key && $entry == *=* ]] || continue
        host_env[$key]=${entry#*=}
    done < "/proc/$$/environ"
}

choose_host_env_policy() {
    local file=$1 line_no=$2 tty_fd reply
    if ! { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
        printf 'ERROR: %s:%d: Detected environment variable that requires host expansion in Enroot image. Host substitution requires --skip-dynamic-env or --resolve-host-env without a terminal\n' "$file" "$line_no" >&2
        return 1
    fi

    printf 'WARNING: Detected environment variable that requires host expansion in Enroot image. Enroot host expansion can embed credentials in image metadata.\n' >&"$tty_fd"
    printf 'Provide one of --skip-dynamic-env or --resolve-host-env in the command line to skip this prompt.\n' >&"$tty_fd"
    printf 'Expand host-dependent assignments? [y/N] ' >&"$tty_fd"
    if IFS= read -r -u "$tty_fd" reply && [[ $reply == [yY] ]]; then
        resolve_host_env=1
    else
        skip_dynamic_env=1
    fi
    exec {tty_fd}>&-
}

# Expand Enroot's ${NAME} references without eval or shell syntax. This
# intentionally matches Enroot's `awk ENVIRON[var]` behavior: unset => empty;
# the only recognized parameter form is ${[A-Za-z_][A-Za-z0-9_]*}.
subst_enroot_host_vars() {
    local remaining=$1 match prefix var replacement result=
    while [[ $remaining =~ \$\{([a-zA-Z_][a-zA-Z0-9_]*)\} ]]; do
        match=${BASH_REMATCH[0]}
        var=${BASH_REMATCH[1]}
        prefix=${remaining%%"$match"*}
        replacement=${host_env[$var]-}
        result+="$prefix$replacement"
        remaining=${remaining:$(( ${#prefix} + ${#match} ))}
    done
    ENROOT_SUBST_RESULT=$result$remaining
}

declare -A enroot_env=()
declare -a enroot_env_order=()
declare -A enroot_env_seen=()
parse_enroot_environment() {
    local file=$1 line formatted name value tail line_no=0 host_env_loaded=0
    local assignment_pattern='^([[:alpha:]_][[:alnum:]_]*)=(.*)$'
    local reference_pattern='\$\{[a-zA-Z_][a-zA-Z0-9_]*\}'
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_no+=1))
        # Enroot's formatter strips only leading whitespace, not trailing
        # whitespace on unquoted values. Preserve CR and literal backslashes.
        formatted=${line#"${line%%[![:space:]]*}"}
        [[ -z $formatted || $formatted == \#* ]] && continue
        # Enroot drops reserved ENROOT_* variables after substitution. If
        # the name is already known, avoid needless host-data resolution.
        [[ $formatted =~ ^ENROOT_[[:alnum:]_]*= ]] && continue

        # A reference before the first '=' can affect the assignment name.
        if [[ $formatted =~ $reference_pattern ]] &&
           [[ $formatted =~ $assignment_pattern || ${formatted%%=*} =~ $reference_pattern ]]; then
            if ((!skip_dynamic_env && !resolve_host_env)); then
                choose_host_env_policy "$file" "$line_no" || return 1
            fi
            if ((skip_dynamic_env)); then
                if [[ $formatted =~ $assignment_pattern ]]; then
                    name=${BASH_REMATCH[1]}
                    unset 'enroot_env[$name]'
                fi
                continue
            fi
            if ((!host_env_loaded)); then
                load_host_environment
                host_env_loaded=1
            fi
            subst_enroot_host_vars "$formatted"
            formatted=${ENROOT_SUBST_RESULT#"${ENROOT_SUBST_RESULT%%[![:space:]]*}"}
            [[ -z $formatted || $formatted == \#* ]] && continue
        fi

        # Matches common::envfmt: the name must begin at column zero *after*
        # stripping leading spaces, with no spaces before the '=' character.
        if [[ ! $formatted =~ $assignment_pattern ]]; then
            printf 'WARNING: %s:%d: ignoring malformed environment assignment\n' "$file" "$line_no" >&2
            continue
        fi
        name=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        [[ $name == ENROOT_* ]] && continue

        # Enroot's sed envfmt removes an outer quote if the first byte of the
        # value is a quote and its last non-whitespace byte is a quote (single
        # OR double). The two quote characters need not have the same style.
        # Do not unescape backslashes or interpret embedded quotes/comments.
        if [[ $value == \"* || $value == \'* ]]; then
            tail=${value%"${value##*[![:space:]]}"}
            if (( ${#tail} >= 2 )) && [[ $tail == *\" || $tail == *\' ]]; then
                value=${tail:1:${#tail}-2}
            fi
        fi

        # Dockerfile ENV cannot reliably encode line breaks as literal value
        # bytes using --change. An environment file is line-oriented anyway,
        # but a host substitution could inject a newline.
        if [[ $value == *$'\n'* || $value == *$'\r'* ]]; then
            printf 'ERROR: %s:%d: %s contains a newline/CR unsupported by podman import --change ENV\n' "$file" "$line_no" "$name" >&2
            return 1
        fi

        if [[ ! ${enroot_env_seen[$name]+present} ]]; then
            enroot_env_order+=("$name")
            enroot_env_seen[$name]=1
        fi
        enroot_env[$name]=$value
    done < "$file"
}

if [[ -f $rootfs/etc/environment ]]; then
    [[ -f $rootfs/etc/environment && ! -L $rootfs/etc/environment ]] || {
        echo 'Unsafe or unsupported /etc/environment' >&2; exit 1;
    }
    parse_enroot_environment "$rootfs/etc/environment"
    for name in "${enroot_env_order[@]}"; do
        [[ ${enroot_env[$name]+present} ]] || continue
        # Podman strips one pair of outer quotes and copies the contents literally.
        changes+=(--change "ENV $name=\"${enroot_env[$name]}\"")
    done
fi

if [[ -f $rootfs/etc/rc ]]; then
    provenance=$(sed -n 's/^# enroot-provenance: //p' "$rootfs/etc/rc" | head -n 1)
    if [[ -n $provenance && $provenance != *$'\n'* ]]; then
        changes+=(--change "LABEL org.opencontainers.image.source=$provenance")
    fi
fi

if [[ -f $rootfs/etc/fstab ]] && grep -Eq '^[[:space:]]*[^#[:space:]]' "$rootfs/etc/fstab"; then
    echo 'WARNING: /etc/fstab has Enroot-specific mounts; these are NOT translated into Podman mounts.' >&2
fi

printf 'Importing into Podman as %s ...\n' "$tag" >&2
# stdin is a single rootfs tar layer, not an archive of the .sqsh file itself.
# If extraction was performed rootlessly, ownership/xattr fidelity may be reduced.
tar --format=posix --numeric-owner --acls --xattrs -C "$rootfs" -cpf - . \
    | podman import "${changes[@]}" - "$tag"

printf 'Done: %s\n' "$tag" >&2
