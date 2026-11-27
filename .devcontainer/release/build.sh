#!/bin/sh
set -eu
export LC_ALL=C

architecture=${1:-$(uname -m)}
case "$architecture" in
    x86_64)
        elf_machine='Advanced Micro Devices X86-64'
        interpreter=/lib64/ld-linux-x86-64.so.2
        ;;
    aarch64)
        elf_machine='AArch64'
        interpreter=/lib/ld-linux-aarch64.so.1
        ;;
    *)
        printf 'Unsupported Linux architecture: %s\n' "$architecture" >&2
        exit 1
        ;;
esac

target="$architecture-unknown-linux-gnu"
cargo build --locked --release --bin enroot-to-oci --target "$target" --target-dir target

binary="target/$target/release/enroot-to-oci"
elf_header=$(readelf -hW "$binary")
program_headers=$(readelf -lW "$binary")
dynamic_section=$(readelf -dW "$binary")
version_info=$(readelf -VW "$binary")

if ! printf '%s\n' "$elf_header" | grep -Eq "Machine:[[:space:]]+$elf_machine\$"; then
    printf 'Expected an ELF executable for %s: %s\n' "$elf_machine" "$binary" >&2
    exit 1
fi
actual_interpreter=$(printf '%s\n' "$program_headers" |
    sed -n 's/.*Requesting program interpreter: \(.*\)]$/\1/p')
if [ "$actual_interpreter" != "$interpreter" ]; then
    printf 'Expected glibc interpreter %s: %s\n' "$interpreter" "$binary" >&2
    exit 1
fi

needed_libraries=$(printf '%s\n' "$dynamic_section" |
    sed -n 's/.*(NEEDED).*Shared library: \[\([^]]*\)\]$/\1/p')
if ! printf '%s\n' "$needed_libraries" | grep -Fxq libc.so.6; then
    printf 'Expected a shared dependency on libc.so.6: %s\n' "$binary" >&2
    exit 1
fi
unexpected_libraries=$(printf '%s\n' "$needed_libraries" | awk -v loader="${interpreter##*/}" '
    NF && $0 != "libc.so.6" && $0 != "libm.so.6" && $0 != "libgcc_s.so.1" && $0 != loader
')
if [ -n "$unexpected_libraries" ]; then
    printf 'Unexpected shared dependencies in %s:\n%s\n' "$binary" "$unexpected_libraries" >&2
    exit 1
fi

glibc_baseline=2.36
required_glibc_versions=$(printf '%s\n' "$version_info" | awk '
    $2 == "Name:" && $3 ~ /^GLIBC_[0-9]/ && $5 != "WEAK" {
        sub(/^GLIBC_/, "", $3)
        print $3
    }
')
highest_version=$(printf '%s\n' "$glibc_baseline" "$required_glibc_versions" | sort -V | tail -n 1)
if [ "$highest_version" != "$glibc_baseline" ]; then
    printf 'Executable requires glibc %s, above the Debian 12 baseline %s: %s\n' \
        "$highest_version" "$glibc_baseline" "$binary" >&2
    exit 1
fi
"$binary" --help > /dev/null

mkdir -p target/release-artifacts
cp "$binary" "target/release-artifacts/enroot-to-oci-linux-$architecture"
