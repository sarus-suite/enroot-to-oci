mod support;

use hpc_image_store::{ImageSelector, Store, StoreConfig};
use std::{
    collections::HashSet,
    env,
    fs::{self, File},
    path::{Path, PathBuf},
    process::{Command, Output},
};
use support::{
    TestResult, XDG_CONFIG_VARIABLES, executable_fixture_dir, run, set_fixture_xdg,
    write_executable, write_sarus_config, write_tool_wrapper,
};

fn prepare_config(directory: &Path) -> TestResult {
    fs::create_dir(directory.join("staging"))?;
    write_sarus_config(
        &directory.join("config"),
        "hpc_image_store = '${ENROOT_TEST_DIRECTORY}/store'\n\
         podman_path = '${ENROOT_TEST_TOOLS}/configured-podman'\n\
         skopeo_path = '${ENROOT_TEST_TOOLS}/configured-skopeo'\n",
    )
}

fn converter(directory: &Path, tools: &Path, destination: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_enroot-to-oci"));
    set_fixture_xdg(
        &mut command,
        &directory.join("config"),
        XDG_CONFIG_VARIABLES.map(|(name, _)| env::var_os(name)),
    );
    command
        .env("ENROOT_TEST_DIRECTORY", directory)
        .env("ENROOT_TEST_TOOLS", tools)
        .env("TMPDIR", directory.join("staging"))
        .env_remove("ENROOT_TEST_FAIL_REMOVE")
        .env_remove("ENROOT_TEST_FAIL_COPY")
        .arg("--skip-dynamic-env")
        .arg(directory.join("fixture image.sqsh"))
        .arg(destination);
    command
}

#[test]
fn rejects_digest_only_destination_before_staging() -> TestResult {
    let temporary = tempfile::tempdir()?;
    let directory = std::path::absolute(temporary.path())?;
    let tools = executable_fixture_dir()?;
    prepare_config(&directory)?;
    File::create(directory.join("fixture image.sqsh"))?;
    for tool in ["unsquashfs", "configured-podman", "configured-skopeo"] {
        write_executable(
            &tools.path().join(tool),
            "#!/bin/sh\nprintf '%s\\n' \"$0\" >> \"$ENROOT_TEST_DIRECTORY/tool-log\"\nexit 42\n",
        )?;
    }

    let destination = format!("localhost/test@sha256:{}", "a".repeat(64));
    let output = converter(&directory, tools.path(), &destination)
        .env("PATH", tools.path())
        .output()?;
    let stderr = assert_failed(&output, 2, "requires an explicit tag")?;
    assert!(stderr.starts_with("error:"), "{stderr}");
    assert!(stderr.contains(&destination), "{stderr}");
    assert!(!directory.join("tool-log").exists());
    assert!(!directory.join("store").exists());
    assert!(fs::read_dir(directory.join("staging"))?.next().is_none());
    Ok(())
}

#[test]
fn staging_failure_cleans_up_without_publishing() -> TestResult {
    let temporary = tempfile::tempdir()?;
    let directory = std::path::absolute(temporary.path())?;
    let tools = executable_fixture_dir()?;
    prepare_config(&directory)?;
    File::create(directory.join("fixture image.sqsh"))?;
    write_executable(
        &tools.path().join("unsquashfs"),
        "#!/bin/sh\n[ \"$2\" = -dest ] && mkdir \"$3\"\n",
    )?;
    write_executable(
        &tools.path().join("tar"),
        "#!/bin/sh\nprintf 'streamed bytes'\nexit 37\n",
    )?;
    write_executable(
        &tools.path().join("configured-podman"),
        r#"#!/bin/sh
set -eu
state="$ENROOT_TEST_DIRECTORY/staged"
case "$1 $2" in
    'image exists')
        [ "$3" = -- ] && [ -f "$state" ] && [ "$4" = "$(cat "$state")" ]
        ;;
    'import --change')
        cat >/dev/null
        for tag do :; done
        printf '%s\n' "$tag" > "$state"
        ;;
    'image rm')
        [ "$3 $4 $5" = '--ignore --no-prune --' ]
        [ "$6" = "$(cat "$state")" ]
        printf '%s\n' "$6" > "$ENROOT_TEST_DIRECTORY/removal"
        if [ "${ENROOT_TEST_FAIL_REMOVE:-0}" = 1 ]; then
            echo 'forced Podman cleanup failure' >&2
            exit 42
        fi
        rm "$state"
        ;;
    *) exit 125 ;;
esac
"#,
    )?;
    write_executable(
        &tools.path().join("configured-skopeo"),
        "#!/bin/sh\ntouch \"$ENROOT_TEST_DIRECTORY/skopeo-called\"\nexit 1\n",
    )?;
    let path = env::join_paths(
        [tools.path().to_path_buf()]
            .into_iter()
            .chain(env::split_paths(&env::var_os("PATH").unwrap_or_default())),
    )?;
    for fail_removal in ["0", "1"] {
        let output = converter(&directory, tools.path(), "localhost/test:destination")
            .env("PATH", &path)
            .env("ENROOT_TEST_FAIL_REMOVE", fail_removal)
            .output()?;
        let stderr = assert_failed(&output, 37, "tar failed")?;
        let tag = fs::read_to_string(directory.join("removal"))?;
        assert!(tag.starts_with("localhost/enroot-to-oci-stage:"));
        if fail_removal == "1" {
            assert_eq!(fs::read_to_string(directory.join("staged"))?, tag);
            assert!(stderr.contains("forced Podman cleanup failure"), "{stderr}");
            assert!(
                stderr.contains(&format!("{} remains", tag.trim())),
                "{stderr}"
            );
        } else {
            assert!(!directory.join("staged").exists());
            assert!(
                !stderr.contains("Cannot remove Podman staging tag"),
                "{stderr}"
            );
        }
        assert!(!directory.join("skopeo-called").exists());
        assert!(!directory.join("store").exists());
        assert!(fs::read_dir(directory.join("staging"))?.next().is_none());
    }
    Ok(())
}

#[test]
#[ignore = "requires local rootless Podman and Skopeo and squashfs-tools"]
fn rootless_publication() -> TestResult {
    let rootless =
        run(Command::new("podman").args(["info", "--format", "{{.Host.Security.Rootless}}"]))?;
    assert_eq!(
        rootless.trim(),
        "true",
        "This test requires rootless Podman"
    );

    let temporary = tempfile::Builder::new()
        .prefix("enroot-publication-")
        .tempdir()?;
    let tools = executable_fixture_dir()?;
    let directory = std::path::absolute(temporary.path())?;
    prepare_config(&directory)?;
    // Persist the CAS parent's directory entry before import initializes the store.
    File::open(directory.parent().unwrap())?.sync_all()?;
    File::open(&directory)?.sync_all()?;
    let store = Store::new(StoreConfig::new(directory.join("store"))?);
    let rootfs = directory.join("rootfs");
    fs::create_dir(&rootfs)?;
    fs::write(rootfs.join("fixture.txt"), "Stage 3 publication fixture\n")?;
    run(Command::new("mksquashfs")
        .arg(&rootfs)
        .arg(directory.join("fixture image.sqsh"))
        .args(["-noappend", "-processors", "1", "-no-progress"]))?;
    fs::write(rootfs.join("fixture.txt"), "Unrelated Podman image\n")?;
    let archive = directory.join("seed.tar");
    run(Command::new("tar")
        .arg("-C")
        .arg(&rootfs)
        .arg("-cf")
        .arg(&archive)
        .arg("."))?;

    let prefix = format!(
        "localhost/enroot-to-oci-stage-three:{}",
        directory.file_name().unwrap().to_str().unwrap()
    );
    let destination = format!("{prefix}-published");
    let unrelated = format!("{prefix}-unrelated");
    assert!(!image_exists(&destination)?);
    assert!(!image_exists(&unrelated)?);
    let fixtures = PodmanFixtures {
        seeded_tags: [&destination, &unrelated],
        staging_log: directory.join("staging-tags"),
    };
    run(Command::new("podman")
        .arg("import")
        .arg(&archive)
        .arg(&destination))?;
    run(Command::new("podman").args(["tag", &destination, &unrelated]))?;
    let destination_id = image_id(&destination)?;
    let unrelated_id = image_id(&unrelated)?;

    write_tool_wrapper(
        &tools.path().join("configured-podman"),
        r#"set -eu
if [ "$1" = import ]; then
    for tag do :; done
    printf '%s\n' "$tag" >> "$ENROOT_TEST_DIRECTORY/staging-tags"
elif [ "$1 $2" = 'image rm' ] && [ "${ENROOT_TEST_FAIL_REMOVE:-0}" = 1 ]; then
    echo 'forced Podman cleanup failure' >&2
    exit 42
fi
exec podman "$@"
"#,
    )?;
    write_tool_wrapper(
        &tools.path().join("configured-skopeo"),
        r#"set -eu
if [ "$1" = copy ] && [ "$2" != --help ] && [ "${ENROOT_TEST_FAIL_COPY:-0}" = 1 ]; then
    tag=$(tail -n 1 "$ENROOT_TEST_DIRECTORY/staging-tags")
    podman image exists -- "$tag"
    echo 'forced Skopeo copy failure after staging' >&2
    exit 42
fi
exec skopeo "$@"
"#,
    )?;

    let output = converter(&directory, tools.path(), &destination).output()?;
    let original = assert_published(&store, &destination, &output)?;
    let stderr = std::str::from_utf8(&output.stderr)?;
    assert!(!stderr.contains("Ignored destination digest"), "{stderr}");
    assert!(!image_exists(&fixtures.latest_staging_tag()?)?);

    let failed_destination = format!("{prefix}-copy-failure");
    let output = converter(&directory, tools.path(), &failed_destination)
        .env("ENROOT_TEST_FAIL_COPY", "1")
        .output()?;
    assert_failed(&output, 1, "forced Skopeo copy failure after staging")?;
    assert!(!image_exists(&fixtures.latest_staging_tag()?)?);
    assert_eq!(
        store.resolve(&ImageSelector::new(failed_destination)?)?,
        None
    );

    let output = converter(&directory, tools.path(), &destination).output()?;
    assert_failed(
        &output,
        1,
        &format!("reference already exists: {destination}"),
    )?;
    assert!(!image_exists(&fixtures.latest_staging_tag()?)?);
    assert_eq!(
        store.resolve(&ImageSelector::new(&destination)?)?,
        Some(original)
    );

    let committed_destination = format!("{prefix}-cleanup-failure");
    let requested_digest = format!("sha256:{}", "a".repeat(64));
    let requested = format!("{committed_destination}@{requested_digest}");
    let output = converter(&directory, tools.path(), &requested)
        .env("ENROOT_TEST_FAIL_REMOVE", "1")
        .output()?;
    let resolved = assert_published(&store, &committed_destination, &output)?;
    assert_ne!(
        ImageSelector::new(resolved)?.digest().unwrap().as_str(),
        requested_digest.as_str()
    );
    let surviving_tag = fixtures.latest_staging_tag()?;
    let stderr = std::str::from_utf8(&output.stderr)?;
    assert!(
        stderr.contains(&format!(
            "WARNING: Ignored destination digest {requested_digest} for {committed_destination}"
        )),
        "{stderr}"
    );
    assert!(stderr.contains("forced Podman cleanup failure"), "{stderr}");
    assert!(
        stderr.contains(&format!("{surviving_tag} remains")),
        "{stderr}"
    );
    assert!(image_exists(&surviving_tag)?);

    let log = fs::read_to_string(&fixtures.staging_log)?;
    assert_eq!(log.lines().count(), 4);
    assert_eq!(log.lines().collect::<HashSet<_>>().len(), 4);
    assert_eq!(image_id(&destination)?, destination_id);
    assert_eq!(image_id(&unrelated)?, unrelated_id);
    assert!(fs::read_dir(directory.join("staging"))?.next().is_none());
    run(Command::new("podman").args(["image", "rm", "--no-prune", "--", &surviving_tag]))?;
    Ok(())
}

fn assert_published(store: &Store, destination: &str, output: &Output) -> TestResult<String> {
    assert!(output.status.success(), "{output:?}");
    let selector = ImageSelector::new(destination)?;
    let resolved = store
        .resolve(&selector)?
        .ok_or("published reference is absent")?;
    let digest = ImageSelector::new(&resolved)?.digest().unwrap().to_string();
    assert_eq!(
        std::str::from_utf8(&output.stdout)?,
        format!("Published {destination} {digest}\n")
    );
    Ok(resolved)
}

fn assert_failed<'a>(output: &'a Output, code: i32, diagnostic: &str) -> TestResult<&'a str> {
    let stderr = std::str::from_utf8(&output.stderr)?;
    assert_eq!(output.status.code(), Some(code), "{stderr}");
    assert!(output.stdout.is_empty(), "{output:?}");
    assert!(stderr.contains(diagnostic), "{stderr}");
    assert!(!stderr.contains("Published "), "{stderr}");
    Ok(stderr)
}

fn image_exists(tag: &str) -> TestResult<bool> {
    let status = Command::new("podman")
        .args(["image", "exists", "--", tag])
        .status()?;
    match status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err(format!("Podman could not check {tag} ({status})").into()),
    }
}

fn image_id(tag: &str) -> TestResult<String> {
    run(Command::new("podman").args(["image", "inspect", "--format", "{{.Id}}", "--", tag]))
}

struct PodmanFixtures<'a> {
    seeded_tags: [&'a str; 2],
    staging_log: PathBuf,
}

impl PodmanFixtures<'_> {
    fn latest_staging_tag(&self) -> TestResult<String> {
        fs::read_to_string(&self.staging_log)?
            .lines()
            .last()
            .map(str::to_owned)
            .ok_or_else(|| "no staging tag was recorded".into())
    }
}

impl Drop for PodmanFixtures<'_> {
    fn drop(&mut self) {
        let log = fs::read_to_string(&self.staging_log).unwrap_or_default();
        let tags = log.lines().chain(self.seeded_tags);
        if let Err(error) = run(Command::new("podman")
            .args(["image", "rm", "--ignore", "--no-prune", "--"])
            .args(tags))
        {
            eprintln!("Cannot remove test images: {error}");
        }
    }
}
