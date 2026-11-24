# Rust converter development roadmap

A CSCS Container Engine user should be able to convert an existing Enroot SquashFS image under their ordinary account, retrieve it by name from the Sarus OCI filesystem-based content-addressable store (CAS), and run it with Podman. The converter reports the committed CAS reference and its stored root digest. A Podman image serves as temporary input to the CAS transfer.

The [Bats suites](tests/) exercise the conversion behavior specified below. Deployment context is available in the [Container Engine documentation](https://docs.cscs.ch/software/container-engine/) and the [Sarus Suite project](https://github.com/sarus-suite).

## 1. Establish the CLI and exercise the store library

```text
enroot-to-oci [--store PATH] [--skip-dynamic-env | --resolve-host-env] [--allow-unrecognized-rc] [--] IMAGE.sqsh IMAGE_TAG
```

- [ ] Keep flags before the positional arguments and honor the end-of-options marker. Preserve exit status 2 for help, invalid arguments, and conflicting environment flags. Interpret the positional tag as the requested CAS destination.
- [ ] Pin the cluster-tooling Cargo dependencies to the inspected `oci-cas` revision `49c6f24716e08bc16b5e31cf8779cb957afc411d` and commit the converter's Cargo.lock. [Upstream source](https://github.com/sarus-suite/cluster-tooling/tree/49c6f24716e08bc16b5e31cf8779cb957afc411d)
- [ ] Load Sarus configuration through `raster::load_config_xdg(raster::config::VarExpand::Must, &None)`. Select `Config::hpc_image_store` unless the caller supplies `--store PATH`. Use the configured Podman path for staging, cleanup, and transfer, and the configured Skopeo path for transfer. [Raster configuration](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/raster/src/config.rs)
- [ ] **Acceptance:** Build with the lockfile. From a local rootless Podman store, import a small fixture through the Rust library and resolve it in a temporary user-owned CAS. Repeat with an isolated Sarus configuration and a distinct override path, verifying which store received each reference. Record the prepared-parent and user-namespace requirements in the runner setup. Check that the devcontainer provides Skopeo with the transfer capabilities required by upstream. [Transfer requirements](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/hpc-image-store/docs/user-guide.md)

## 2. Port extraction, metadata recovery, and Podman staging

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
| Recover WorkingDir from exactly one recognized generated command pair and remove those two lines from the staged /etc/rc. Preserve its startup, default command, argument forwarding, and rc.local handling. | The image honors its recovered directory and a runtime workdir override. With zero or multiple pairs, reject by default. The explicit rc override preserves the script byte for byte and warns. |
| Select /bin/bash for rc when available, or /usr/bin/bash when that is the image's only Bash. Preserve the empty image Cmd. | Add a fixture for the /usr/bin/bash-only layout. Reject an rc without Bash and use the documented /bin/sh fallback when rc is absent. |
| Parse Enroot assignments and one-pass host substitutions as data. Preserve quoting rules, literal characters, and last-assignment-wins behavior. Filter reserved names and warn on malformed assignments. | Cover dynamic names, skipped assignments clearing earlier values, later static assignments restoring them, unset host values, and CR/LF rejection. Test explicit policies, a single controlling-terminal prompt with default omission, and unattended failure before import. |
| Recover the source label from the first provenance marker and warn about active fstab mounts. Stream one flattened GNU tar layer with POSIX format, numeric ownership, ACLs, and xattrs. | Inspect metadata and capture import arguments individually. Verify the staged script, filesystem contents, and mount warning. |

- [ ] Implement the streaming pipeline with `std::process::Command`, using individual arguments for each import change. Connect tar stdout to Podman stdin, reap both children, and propagate the rightmost failing status. Cover tar and Podman failures, including failure to start the consumer. The pinned Podman driver provides `rmi` for cleanup and lacks a streaming image-import method. [Podman driver API](https://github.com/sarus-suite/cluster-tooling/blob/49c6f24716e08bc16b5e31cf8779cb957afc411d/crates/podman-driver/src/lib.rs)
- [ ] **Acceptance:** Run the eight Bash mock cases as a reference and reuse their captured-argument, staged-script, terminal, and status assertions at the Rust staging boundary. The mock suite hard-codes Bash and its Podman stub produces no real image. Exercise this boundary in tests while keeping publication mandatory in the production CLI. [Mock suite](tests/converter-mocks.bats), [terminal helper](tests/terminal.bash)

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
