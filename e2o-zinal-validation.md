# Enroot-to-oci Zinal CPU validation report

This report documents validation of the `enroot-to-oci` converter tool on the Zinal TDS cluster. The following tool builds were used:
- enroot-to-oci: https://github.com/sarus-suite/enroot-to-oci/commit/fadcb7851c5c156fd8b5ac4dbd3688af54c9c1de
- sarusctl: https://github.com/sarus-suite/cluster-tooling/commit/b411f0f69d5cea1824121d3a86cca68a21d2bbd0
- parallax: https://github.com/sarus-suite/parallax/commit/a7805d7018ad927600fa2290eaafe97df14d6b70
- Skybox: https://github.com/sarus-suite/sarus-suite/commit/00c37011b2336d4459d75614fd02d2e5204bf10d
- Podman 5.8.11

The tests used OSU-MB images from the Sarus Suite containerfiles-ci repo, in Enroot Squashfs form as used for CE ReFrame tests. 

## Current assessment

The Zinal runs verified conversion, publication, export, and CPU container execution for real Enroot images. Two-node MPICH execution over Slingshot passed on `nid001318` and `nid001319` on 2026-11-27. The completed failure and recovery tests revealed no converter defect requiring a code change within the tested scope.

| Status | Finding |
| --- | --- |
| **Passed** | Ubuntu 24.04 and Fedora published to the Sarus content-addressable store (CAS), exported at their reported digests, and matched native Enroot for OS identity, selected environment values, argument forwarding, and exit status. Sampled filesystem metadata matched independent unprivileged extraction. The sampled OCI owners carried the converter account’s numeric UID and GID, consistent with the documented rootless behavior. Job 830 verified these results. |
| **Passed** | An existing tag retained its digest. Truncated input and a missing CAS parent failed without publishing. The checks found no extraction or Podman staging residue. Creating the missing parent allowed the same destination to publish and export. Job 831 verified these results. |
| **Observed** | The mixed builds produced two Parallax entries for one converted Ubuntu image. Custom `sarusctl` used a tag-based entry and Skybox used a digest-based entry. Each reused its own entry on the second launch. Convergence with matching builds remains unverified. |
| **Passed** | The operator’s manual two-node runs of `osu_bw` and `osu_alltoall` on the converted Open MPI OMB image `7.5.2-ompi5.0.11-ofi2.6.0` achieved the expected Slingshot performance. Job 831 independently verified the image’s default working directory on `nid001308`. |
| **Observed** | The inspected CPU images had no active Enroot mounts or `${NAME}` host substitutions, so those behaviors have fixture coverage for this assessment. [Runtime fixtures](tests/enroot-to-oci.bats) |

The early one-node attempts exposed validation harness issues with the local `unsquashfs -version` exit status, namespace-relative ownership, and the changing age field in the CAS listing. The results above use the corrected checks and the recovery run in job 831.

## Two-node follow-up

The operator reported a successful two-node OSU point-to-point bandwidth run on `nid001318` and `nid001319`. The follow-up jobs used that pair explicitly. Job 833 found the custom Parallax executable and user override on each node. The system executable was also present on both. Skybox completed the default and override probes on each node, reporting `/usr/local/libexec/osu-micro-benchmarks/mpi` and `/tmp`, respectively. The launch logs did not identify which Parallax executable Skybox invoked.

The MPICH OMB image `7.5.2-mpich5.0.1-ofi2.6.0` converted in 12.91 seconds and passed the CAS check. Sampling recorded a 2.36 GiB extraction peak, 0.79 GiB in Podman storage at peak, and approximately 284 MiB of additional CAS usage. The native image rejected PMIx during `MPI_Init`. PMI-2 worked, and job 835 used it for both Enroot and Skybox with one rank per node. All four steps exited 0 and reported `libfabric provider: cxi - cxi`. Job 834 also produced valid native bandwidth output. Its harness stopped early because its output check required leading whitespace in the measurement rows.

| Test at 1 MiB | Native Enroot | Converted Skybox |
| --- | ---: | ---: |
| `osu_bw` bandwidth | 23,221.19 MB/s | 23,285.30 MB/s |
| `osu_alltoall` average latency | 86.28 µs | 82.81 µs |

The table shows one paired run in steps `835.0` through `835.3`, in Enroot bandwidth, Enroot all-to-all, Skybox bandwidth, and Skybox all-to-all order.

## Misuse and recovery tests

Job 837 ran on `nid001318` against a disposable CAS. It followed job 836, which passed the same-tag race and stopped when the harness expected different wording for the untagged-reference diagnostic. Job 837 checked the actual diagnostic.

| Status | Case | Result |
| --- | --- | --- |
| **Passed** | Same-tag race | Ubuntu won and exported as the committed image. Fedora returned a reference conflict. The harness found no staging residue after both conversions. |
| **Passed** | Bad paths and references | A missing source, directory source, untagged destination, and digest-only destination produced actionable errors. Both valid unusual filenames published. |
| **Passed** | Digest suffix | The converter warned that it ignored the supplied digest. The committed digest matched the publication line and exported. |
| **Passed** | Unattended environment and startup | With no terminal, the converter requested an explicit environment policy. Skip and resolve produced the expected OCI metadata. The unrecognized startup script was rejected by default, and the override preserved it and emitted warnings. The runtime read the marker through the explicit EDF mount. |
| **Observed** | Interrupt during extraction | SIGTERM arrived after the extractor had written the tree and before it returned control to the converter. The destination was absent and there was no Podman staging tag. Retry published and exported, but the original extracted tree remained in node-local staging. |
| **Initial setup failure** | Interrupt during publication | The harness’s temporary XDG configuration changed the Podman storage context. Podman reported a database path mismatch before publication. Job 838 corrected the harness. |
| **Initial setup failure** | Staging exhaustion | The compute node denied the first size-limited tmpfs mount attempt. Job 838 mounted the tmpfs in a private namespace with the invoking user mapped to namespace root. |

### Final failure and recovery checks

Job 838 ran on `nid001318` and used disposable CAS directories. For hard external interruptions, the acceptance criteria were an intact store and a successful ordinary retry. Temporary residue is an accepted operational finding.

| Status | Case | Result |
| --- | --- | --- |
| **Passed** | Concurrent first use | Ubuntu and Fedora conversions started against the same previously absent CAS with distinct tags. Each tag retained its own digest and exported the correct distribution. The staging inventory returned to its baseline. |
| **Passed** | Unwritable CAS parent | Publication returned `Permission denied` and left no committed reference or staging residue after normal exit. Restoring write permission allowed the same tag to publish and export. |
| **Passed** | Interrupted publication | Both tool wrappers preserved the original XDG environment. The real Skopeo copy finished and the harness sent SIGTERM before returning control to the publisher. The new tag was absent, the seed image kept its digest and exported, and ordinary retry published and exported the new image. A temporary CAS operation directory and a Podman staging tag remained at the interruption point. The harness removed the test-owned Podman tag after verifying the retry. |
| **Passed** | Staging exhaustion | A 1 MiB tmpfs in the private namespace produced a real `ENOSPC` during extraction. The converter exited 1 and published no reference. The same tag published and exported with ordinary staging. |
| **Passed** | Additional image compatibility | openSUSE Leap and Ubuntu 26.04 both exported at the reported CAS digests. Their restored Podman probes matched native Enroot for OS identity, argument forwarding, and exit status. Source checksums matched before and after the run. |

Two empty core-named files appeared during the native Enroot steps, after conversion and export had finished. The steps returned the probe’s intended exit status of 37. The files contain no evidence identifying the process that produced them.

### Reusable test procedures

This section contains a reference for rerunning the misuse and recovery tests in the previous subsections. Every case has already been exercised in the reported jobs 837 and 838. The results appear in the tables above. 

Use a disposable CAS, private staging, unique test-owned tags, and an ordinary user account. Keep source images read-only. Use small local images or harmless fixtures and bound the runtime of each case. Prioritize duplicate submissions, interruption, and constrained storage because they exercise the real publication and cleanup paths. The [CLI tests](tests/cli.rs) and [process fixtures](tests/conversion-process.bats) already cover many argument and metadata cases.

| Priority | User behavior | Procedure and expected result |
| --- | --- | --- |
| P1 | Copies the wrong path or reference | Try a missing source, a source directory, a destination without a tag, and a digest-only destination. Require actionable diagnostics, a nonzero exit, and no publication. Require exit 2 for invalid CLI usage. Then convert valid paths containing spaces and a relative filename beginning with a hyphen passed after `--`. |
| P1 | Supplies a digest as an expected checksum | Convert to an unused explicit tag with a syntactically valid digest suffix that differs from the result. Require a warning that the supplied digest was ignored. Verify that the tag resolves to the digest printed in `Published` and export that digest. |
| P1 | Starts the same conversion twice | Start two conversions of different small images to one fresh tag inside a single one-node job. Require exactly one success and one reference conflict. The winning digest must resolve and export, and the exported image must contain the winner’s identifying file. Inspect each run’s extraction directory and the Podman staging tags after both processes exit. |
| P1 | Stops a conversion and immediately retries | Use a bounded harness to interrupt one run during extraction and another during publication after observing the relevant phase. Check the resulting destination before retrying. If the ref is absent, retry should publish and export. If commit completed, the existing ref must export and the retry must preserve it. Record residual files, tags, or processes and whether an operator must remove them before retrying. |
| P1 | Runs out of staging space | Set `TMPDIR` to a private size-limited filesystem with less free space than the small fixture needs to extract. Keep the CAS and Podman stores outside that limit. Require a diagnostic, nonzero exit, and no partial publication. Retry the same destination with sufficient staging space and verify export. |
| P2 | Runs unattended with a host-dependent environment | Use a fixture with an assignment containing a `${NAME}` reference and set the referenced variable to a harmless unique marker. With no controlling terminal, require the default invocation to fail with guidance. With `--skip-dynamic-env`, require the assignment and expanded marker to be absent from OCI environment metadata. With `--resolve-host-env`, require the marker in the expected OCI environment value. |
| P2 | Expects Enroot mounts and a custom startup script to carry over | Use a harmless fixture with an active `/etc/fstab` entry and an unrecognized workdir script. Verify default rejection and the workdir warning with `--allow-unrecognized-rc`. In the allowed case, verify the mount warning, confirm the script is retained, and supply the fixture mount explicitly through an EDF. Read a test marker through that mount. |

For each case, record the command, exit status, diagnostics, source checksum, CAS reference and digest, export result where applicable, and staging residue. Capture the Slurm job and step IDs for compute-node runs. Preserve test-owned evidence for unexpected results. If a significant design gap appears, stop the affected work and record the reproducer, impact, and decision needed before resuming.
