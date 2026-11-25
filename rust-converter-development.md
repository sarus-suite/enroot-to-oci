# Rust converter development roadmap

A CSCS Container Engine user should be able to convert an existing Enroot SquashFS image under their ordinary account, retrieve it by name from the Sarus OCI filesystem-based content-addressable store (CAS), and run it with Podman. The converter reports the committed CAS reference and its stored root digest. A Podman image serves as temporary input to the CAS transfer.

The [Bats suites](tests/) exercise the conversion behavior specified below. Deployment context is available in the [Container Engine documentation](https://docs.cscs.ch/software/container-engine/) and the [Sarus Suite project](https://github.com/sarus-suite).

## 1. Establish the CLI and exercise the store library (implemented)

```text
enroot-to-oci [--store PATH] [--skip-dynamic-env | --resolve-host-env] [--allow-unrecognized-rc] [--] IMAGE.sqsh IMAGE_TAG
```

- [x] Use Clap's derived parser for options, the `--` separator, the two required operands, help, and usage errors.
  Accept options anywhere before `--`, including `--store PATH` and `--store=PATH`.
  Allow one `--store` option and treat repeated boolean flags as a single occurrence.
  Use the store library's `ImageSelector` to parse `IMAGE_TAG` as the requested CAS destination.
  Clap prints `-h` and `--help` to stdout with status 0 and reports invalid usage, including conflicting environment flags, to stderr with status 2.
  Return errors for configuration and conversion failures.
  [hpc-image-store CLI](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/hpc-image-store/src/main.rs), [sarusctl CLI](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/sarusctl/src/main.rs)
- [x] Pin the cluster-tooling Cargo dependencies to the inspected `oci-cas` revision `49c6f24716e08bc16b5e31cf8779cb957afc411d` and commit the converter's Cargo.lock. [Upstream source](https://github.com/sarus-suite/cluster-tooling/tree/49c6f24716e08bc16b5e31cf8779cb957afc411d)
- [x] Load Sarus configuration through `raster::load_config_xdg(raster::config::VarExpand::Must, &None)`. Select `Config::hpc_image_store` unless the caller supplies `--store PATH`. Use the configured Podman path for staging, cleanup, and transfer, and the configured Skopeo path for transfer. [Raster configuration](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/raster/src/config.rs)
- [x] **Acceptance:** Build with the lockfile. From a local rootless Podman store, import a small fixture through the Rust library and resolve it in a temporary user-owned CAS. Repeat with an isolated Sarus configuration and a distinct override path, verifying which store received each reference. Record the prepared-parent and user-namespace requirements in the runner setup. Check that the devcontainer provides Skopeo with the transfer capabilities required by upstream. [Transfer requirements](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/hpc-image-store/docs/user-guide.md)

### Stage 1 runner setup

The Rust binary validates arguments and loads Sarus configuration. Use
`enroot-to-oci.sh` for SquashFS conversion during this stage.

Run the smoke test as an ordinary user with rootless Podman and Skopeo.
In the devcontainer, run as `vscode`. Podman and Skopeo must inherit the same
local containers-storage configuration and user namespace. The runner needs
working user namespaces and subordinate UID/GID mappings. The devcontainer
startup check verifies Skopeo's shared-blob and digest-preservation flags.

```sh
cargo build --locked
cargo test --locked
cargo test --locked --test stage_one rootless_store_smoke -- --ignored --nocapture
```

If the tools require an existing rootless user namespace, run the smoke test
with `podman unshare` before the last Cargo command.

Use a prepared, writable temporary location for the smoke test. It creates
and syncs a private immediate parent for both CAS roots under `TMPDIR` (or
the system temporary directory). The parent and the directory entries needed
to reach it must be durable. For a missing CAS root, its immediate parent must
allow the user to create entries and open and sync the directory. The store
library initializes the CAS root. Use paths without a colon for Skopeo's OCI
transport. [Preparing a store](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/hpc-image-store/docs/administration.md)

On 2026-11-24, the locked build and four CLI tests passed. The smoke test
passed as `vscode` with rootless Podman 5.4.2 using overlay storage and
Skopeo 1.18.0. Each destination resolved to the digest reported by the store
library and was absent from the other CAS. The devcontainer startup check
passed with those tools.

## 2. Port extraction, metadata recovery, and Podman staging (implemented)

Recognize the following consecutive lines in a regular `/etc/rc`. Allow whitespace variation in the generated `mkdir` form. Match the `cd` line exactly, with the same quoted absolute path. Exclude paths containing a backslash, dollar sign, or backtick. Read the first `# enroot-provenance: ` marker and set `org.opencontainers.image.source` if its value is nonempty. [Enroot startup generator](https://github.com/NVIDIA/enroot/blob/main/src/docker.sh), [image format](https://github.com/NVIDIA/enroot/blob/main/doc/image-format.md)

```sh
mkdir -p "/app space" 2> /dev/null
cd "/app space" && unset OLDPWD || exit 1
```

Read `/etc/environment` line by line. Trim leading whitespace, skip blanks and full-line comments, and accept names matching `[[:alpha:]_][[:alnum:]_]*` immediately followed by `=`. Filter `ENROOT_*` names. Strip one outer quote pair when the first byte and last non-whitespace byte are quotes, even of different styles. Keep unquoted trailing whitespace, backslashes, inline hashes, literal `$NAME`, and embedded equals signs. Pass each retained assignment as one `--change` argument value of the form `ENV NAME="VALUE"`. [Enroot environment formatting](https://github.com/NVIDIA/enroot/blob/main/src/common.sh), [environment loading](https://github.com/NVIDIA/enroot/blob/main/bin/common.h)

Recognize only `${NAME}` with an ASCII shell identifier for host substitution. Resolve from the inherited environment in one pass before validating the resulting assignment. Both explicit policies bypass the prompt. Otherwise warn once on the controlling terminal that expansion can embed credentials, then ask `Expand host-dependent assignments? [y/N] `. Only a single `y` or `Y` selects expansion. Enter, EOF, and other replies select omission. Without a controlling terminal, diagnose the two policy flags. Use exit status 1 for conversion validation errors.

| Work item | Acceptance evidence |
| --- | --- |
| Extract with unsquashfs into a private temporary directory. Validate the staged paths before reading or editing configuration. | A corrupt input or a symlink at /etc, /etc/rc, /etc/environment, or /etc/fstab fails before import. The input image checksum survives conversion. |
| Recover WorkingDir from exactly one recognized generated command pair. Validate that the path is valid UTF-8 and contains no NUL before removing those lines from the staged /etc/rc. Preserve trailing whitespace through Podman import and retain startup, default command, argument forwarding, and rc.local handling. | Check the stored and runtime directory for a path with a trailing space and verify a runtime workdir override. With zero or multiple pairs, reject by default. The explicit rc override preserves the script byte for byte and warns. |
| Select /bin/bash for rc if it resolves to a regular file with execute bits in the image. Otherwise try /usr/bin/bash. Preserve the empty image Cmd. | Cover the /usr/bin/bash-only layout, a non-executable /bin/bash, and the absence of executable Bash. Verify the /bin/sh fallback when rc is absent. |
| Parse Enroot assignments and one-pass host substitutions as data. Preserve quoting rules, literal characters, and last-assignment-wins behavior. Filter reserved names and warn on malformed assignments. Reject invalid UTF-8 in assignments retained for image metadata. | Cover dynamic names, skipped assignments clearing earlier values, later static assignments restoring them, unset host values, and rejection of CR/LF and invalid UTF-8. Test explicit policies, a single controlling-terminal prompt with default omission, and unattended failure before import. |
| Recover the source label from the first provenance marker and warn about active fstab mounts. Stream one flattened GNU tar layer with POSIX format, numeric ownership, ACLs, and xattrs. | Inspect metadata and capture import arguments individually. Verify the staged script, filesystem contents, and mount warning. |

- [x] Implement the streaming pipeline with `std::process::Command`, using individual arguments for each import change. Connect tar stdout to Podman stdin, reap both children, and propagate the rightmost failing status. Cover tar and Podman failures, including failure to start the consumer. The pinned Podman driver provides `rmi` for cleanup and lacks a streaming image-import method. [Podman driver API](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/podman-driver/src/lib.rs)
- [x] **Acceptance:** Run the eight Bash mock cases as a reference and reuse their captured-argument, staged-script, terminal, and status assertions at the Rust staging boundary. Select the Rust test driver with `ENROOT_CONVERTER`. The test driver exercises Podman staging, and stage three connects it to mandatory CAS publication in the production CLI. [Mock suite](tests/converter-mocks.bats), [terminal helper](tests/terminal.bash)

### Stage 2 runner setup

Run the mock suites on Linux with Bats 1.11 or later, GNU tar, and
`script` and `setsid` from util-linux. For the real-image suites, use
rootless Podman and the fixture tools in the devcontainer. The test driver
takes a test-owned local stage tag, which the real-image suite removes.

```sh
cargo build --locked --example stage-two-driver
bats --print-output-on-failure tests/converter-mocks.bats
export ENROOT_CONVERTER="$PWD/target/debug/examples/stage-two-driver"
bats --print-output-on-failure tests/converter-mocks.bats tests/stage-two.bats
bats --print-output-on-failure \
  tests/enroot-to-oci.bats tests/stage-two-rootless.bats tests/filesystem-fidelity.bats
```

On 2026-11-25, 21 real-image cases passed as `vscode` with Podman 5.4.2
using an isolated rootless overlay store. The ACL case skipped because the
fixture ACL was unavailable after extraction. The device-node case skipped
because the runner could not create the fixture device.

## 3. Publish the staged image to the CAS

- [ ] Stage under a unique converter-owned Podman tag for each invocation. Once both pipeline children succeed, construct separate source and destination selectors and call `Store::import(&source, Some(&destination), &context, &ImportOptions::default())` on the configured store. Staging and transfer must share a local containers-storage configuration, user, and namespace.
- [ ] Use the hpc-image-store Cargo library directly. Podman and Skopeo are runtime dependencies of the library's transfer implementation. Leave CAS initialization, locking, publication, and recovery to the library and retain its default collision policy. Read the committed identity from `ImportReport.local_ref` and `ImportReport.stored_root`. [Store library guide](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/hpc-image-store/docs/library-guide.md)
- [ ] Release the extracted tree and remove the owned staging tag on success and handled failure. Preserve the primary error if cleanup also fails. If cleanup fails after the CAS commit, report the committed reference, digest, and any surviving staging tag.
- [ ] **Acceptance:** Force CAS import to fail after successful staging and verify a failing exit, absence of a completion message, and staging cleanup. Exercise a destination conflict and verify the prior CAS digest survives. Seed an unrelated Podman tag, including one with the requested destination name, and verify cleanup preserves it.

## 4. Release against a rootless CAS round trip

- [ ] Extend the real-image Bats helpers to use an isolated CAS for each Rust test. After conversion, resolve the requested reference, compare its digest with the reported digest, and check the image for structural errors. Use a test helper calling `Store::export` to restore the CAS image to a fresh Podman tag. Direct the existing inspect, run, and mount assertions at that restored tag. [Conversion suite](tests/enroot-to-oci.bats), [test helpers](tests/helpers.bash)
- [ ] Run the adapted suites with the Rust binary selected through the existing test interface. Verify startup, argument forwarding, runtime environment and workdir overrides, exact environment metadata, and label recovery. Preserve offline runtime checks using local fixtures, disabled pulls, and disabled networking.

```sh
ENROOT_CONVERTER="$PWD/target/debug/enroot-to-oci" bats --print-output-on-failure \
  tests/enroot-to-oci.bats tests/filesystem-fidelity.bats
```

- [ ] Check file contents, modes, symlink targets, hardlink relationships, FIFOs, and numeric ownership below the restored mount root. Record ownership from an independent unprivileged extraction before entering Podman's user namespace. Apply the existing rootless ownership comparison and report differences from the IDs encoded in SquashFS. Exercise binary user xattrs, numeric ACLs, and device nodes where fixture creation, extraction, and storage support them. Record each capability skip with its reason. [Filesystem suite](tests/filesystem-fidelity.bats), [comparison helper](tests/filesystem-compare.bash)
- [ ] **Release criterion:** Record a successful end-to-end run as an unprivileged user with rootless Podman, including CAS publication, export, runtime checks, fidelity checks, and failure cases. Rootful execution and privileged fixture creation are outside the release criteria. Record pass, failure, and skip counts for the release candidate.
