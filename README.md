# Enroot to OCI

`enroot-to-oci` converts an Enroot SquashFS image into an OCI image in the
Sarus filesystem-based content-addressable store (CAS). It uses a temporary
image in local Podman storage and prints the committed CAS tag and root
digest. The stored image can be exported to a local Podman tag for execution.

## Build and configure

Build the Rust executable with `cargo build --locked`. At runtime it needs
`unsquashfs`, GNU tar, and local rootless Podman and Skopeo. Skopeo must
support `--dest-shared-blob-dir` for publication and
`--src-shared-blob-dir` and `--preserve-digests` for export. Podman and
Skopeo must use the same containers-storage configuration, user, and
namespace. The runner needs working user namespaces and subordinate UID
and GID mappings.

The converter loads Sarus configuration through XDG. For example,
in case a Sarus configuration is not already provided at the system or user
level, put the following settings in `~/.config/sarus-suite/sarus-suite.conf`
when using the default user configuration directory.

```toml
hpc_image_store = "/scratch/me/images"
podman_path = "/usr/bin/podman"
skopeo_path = "/usr/bin/skopeo"
```

Prepare the immediate parent of the CAS directory and make its path durable
before conversion. The user must be able to create entries and open and sync
the parent directory. The store library initializes a missing CAS directory.
Use a path without a colon so Skopeo can address the OCI layout.
[Sarus store administration](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/hpc-image-store/docs/administration.md)

## Convert an image

```text
enroot-to-oci [--store PATH] [--skip-dynamic-env | --resolve-host-env] [--allow-unrecognized-rc] [--] IMAGE.sqsh IMAGE_REF
```

Provide a destination image reference with an explicit tag. A digest-only
destination is a usage error. For a reference with a digest suffix, the import
into the CAS uses the tag and warns that it ignored the supplied digest.
An existing CAS tag causes the conversion to fail and retains its original
image.

The `--store` option overrides the CAS directory from configuration files.
Options can appear anywhere before `--`. Use `--` to pass an image path
that starts with a hyphen. `--help` and `-h` exit with status 0. Invalid
usage exits with status 2.

Successful conversion prints `Published <local_ref> <stored_root>` to
stdout. A cleanup failure after commit also prints a warning to stderr.
Conversion failures exit nonzero. If both tar and Podman import fail,
the converter returns Podman’s status.
[Sarus store commands](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/hpc-image-store/docs/user-guide.md)

## Conversion behavior

- The converter extracts to a private directory, validates the configuration
  paths, and leaves the source SquashFS intact. It rejects symlinks at
  `/etc`, `/etc/rc`, `/etc/environment`, and `/etc/fstab`. It streams the
  prepared filesystem as one GNU tar layer with numeric owners, ACLs, and
  extended attributes. Filesystem metadata depends on what unprivileged
  extraction and rootless storage can preserve.
- If the image contains a regular `/etc/rc`, the OCI entrypoint is set to run
  it with executable Bash from the image, preferring `/bin/bash` and falling
  back to `/usr/bin/bash`. Conversion fails if neither is available.
  The script retains its startup logic, default command, argument forwarding,
  and `rc.local` handling. Without `/etc/rc`, the entrypoint is `/bin/sh`.
- Workdir is derived from `/etc/rc` contents. The converter moves the
  Enroot generated working directory into image metadata when it finds exactly
  one consecutive pair of commands like these:

  ```sh
  mkdir -p "/app space" 2> /dev/null
  cd "/app space" && unset OLDPWD || exit 1
  ```

  The `mkdir` form allows whitespace variation. The `cd` line must match
  the generated form exactly, with the same quoted absolute UTF-8 path.
  Paths containing a backslash, dollar sign, backtick, or NUL are ineligible.
  Moving the directory into image metadata allows `podman run -w` to
  override it. When the pair is missing or ambiguous, `--allow-unrecognized-rc`
  keeps the script intact and warns it may override `-w`.
- Environment variables are derived from assignments in`/etc/environment`.
  The converter skips blank lines, full-line comments, and `ENROOT_*`
  keys. It warns about malformed assignments and applies the last
  assignment for a key. It strips one outer quote pair and preserves
  unquoted trailing whitespace, inline hashes, literal dollar signs,
  backslashes, and embedded equals signs. Use `--skip-dynamic-env` to
  omit assignments containing `${NAME}` host references and clear earlier
  values for the same key. Use `--resolve-host-env` to expand those
  references once from the environment of the converter, using an empty string
  for unset names. Without an explicit policy, the
  converter asks once on the controlling terminal and defaults to omission.
  Unattended conversions that encounter these assignments require a policy.
  Pay attention that expansions from host variables can embed credentials in
  the stored image.
- A nonempty value on the first `# enroot-provenance: ` marker in
  `/etc/rc` supplies `org.opencontainers.image.source`.
- The converter warns about dynamic Enroot `/etc/fstab` entries.
  Replicate those mounts at runtime through an EDF.

## Testing and verification

Use the devcontainer as `vscode` or an equivalent unprivileged Linux
runner. In addition to the runtime tools, the tests use Bats 1.11 or
later, `jq`, `mksquashfs`, GNU coreutils, and `script` and `setsid` from
util-linux. The optional metadata cases use the ACL and attr tools.
Use an executable `TMPDIR` without a colon for the Bats fixtures and
their tool shims. Check local Podman and Skopeo with `bash .devcontainer/check.sh`.
The tests use the runner’s local containers-storage context and allocate
their own image names, containers, and CAS directories.

```sh
cargo build --locked --bin enroot-to-oci --example cas-round-trip
cargo test --locked
bats --print-output-on-failure tests/conversion-process.bats
ENROOT_CONVERTER="$PWD/target/debug/enroot-to-oci" bats --print-output-on-failure \
  --show-output-of-passing-tests tests/enroot-to-oci.bats tests/filesystem-fidelity.bats
```

For a custom Cargo target directory, point the real-image suites to the
converter and the CAS round-trip helper built there.

```sh
target_dir="$PWD/target/custom build"
cargo build --locked --target-dir "$target_dir" --bin enroot-to-oci --example cas-round-trip
ENROOT_CONVERTER="$target_dir/debug/enroot-to-oci" \
  ENROOT_CAS_ROUND_TRIP="$target_dir/debug/examples/cas-round-trip" \
  bats --print-output-on-failure tests/enroot-to-oci.bats tests/filesystem-fidelity.bats
```

The runtime and fidelity suites verify the CAS reference and reported root
digest, run the store’s structural check, and export to a fresh local Podman
tag. They inspect, run, and mount the restored image. Container runs use
local fixtures with pulls and networking disabled. Filesystem comparisons
start below the mount root and use an independent unprivileged extraction
to account for rootless ownership differences. Optional metadata cases
can skip when the fixture filesystem, extraction, or the independent
Podman storage probe lacks support.

### MVP verification record

The 0.1.0 release candidate based on `542ab78` was verified on 2026-11-26
as `vscode` (UID/GID 1000) on Debian 13 x86-64, with rootless Podman 5.4.2
using isolated overlay storage, Skopeo 1.18.0, Bats 1.11.1, and
squashfs-tools 4.6.1.

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Cargo unit and integration tests | 9 | 0 | 0 |
| Conversion process | 23 | 0 | 0 |
| Real-image conversion and runtime | 19 | 0 | 0 |
| Restored filesystem fidelity | 2 | 0 | 2 |

The binary user xattr survived the round trip. The numeric ACL case skipped
because SquashFS extraction did not retain the fixture ACL. The character
device case skipped because the unprivileged runner could not create the
fixture node. The restored image showed `1000:1000` for files encoded as
`0:0` and `1234:2345` in SquashFS, matching the independent unprivileged
extraction.
