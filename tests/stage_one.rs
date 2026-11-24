use enroot_to_oci::load_transfer_settings;
use hpc_image_store::{ImageSelector, ImportOptions, ImportReport, Store, TransferContext};
use std::{
    env,
    error::Error,
    ffi::OsString,
    fs::{self, File},
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Command, Output},
};

type TestResult<T = ()> = Result<T, Box<dyn Error>>;

fn write_sarus_config(xdg: &Path, contents: &str) -> TestResult {
    let config_dir = xdg.join("sarus-suite");
    fs::create_dir_all(&config_dir)?;
    fs::write(config_dir.join("stage-one.conf"), contents)?;
    Ok(())
}

fn converter(xdg: &Path, args: &[&str]) -> TestResult<Output> {
    Ok(Command::new(env!("CARGO_BIN_EXE_enroot-to-oci"))
        .env("XDG_CONFIG_HOME", xdg)
        .env("XDG_CONFIG_DIRS", xdg)
        .args(args)
        .output()?)
}

#[test]
fn help_and_usage_errors_precede_configuration() -> TestResult {
    let xdg = tempfile::tempdir()?;
    write_sarus_config(xdg.path(), "invalid = [")?;
    let help_cases: &[&[&str]] = &[
        &["--help"],
        &["-h"],
        &["source.sqsh", "example:tag", "--help"],
    ];
    for args in help_cases {
        let output = converter(xdg.path(), args)?;
        let stdout = std::str::from_utf8(&output.stdout)?;
        assert_eq!(output.status.code(), Some(0), "{args:?}: {output:?}");
        assert!(output.stderr.is_empty(), "{args:?}: {output:?}");
        assert!(
            stdout.contains("Usage: enroot-to-oci"),
            "{args:?}: {stdout}"
        );
        assert!(stdout.contains("--resolve-host-env"), "{args:?}: {stdout}");
        assert!(
            stdout.contains("--store PATH or --store=PATH"),
            "{args:?}: {stdout}"
        );
    }

    let invalid_cases: &[(&[&str], &str)] = &[
        (&[], "<IMAGE.sqsh>"),
        (&["source.sqsh"], "<IMAGE_TAG>"),
        (&["source.sqsh", "example:tag", "extra"], "extra"),
        (&["--unknown", "source.sqsh", "example:tag"], "--unknown"),
        (&["--store"], "--store"),
        (&["--store", "--", "source.sqsh", "example:tag"], "--store"),
        (&["--store", "", "source.sqsh", "example:tag"], "--store"),
        (&["--store=", "source.sqsh", "example:tag"], "--store"),
        (
            &[
                "--store=one",
                "--store",
                "two",
                "source.sqsh",
                "example:tag",
            ],
            "--store",
        ),
        (
            &[
                "--store",
                "one",
                "--store",
                "two",
                "source.sqsh",
                "example:tag",
            ],
            "--store",
        ),
        (
            &[
                "--skip-dynamic-env",
                "--resolve-host-env",
                "source.sqsh",
                "example:tag",
            ],
            "--resolve-host-env",
        ),
        (&["source.sqsh", "example"], "<IMAGE_TAG>"),
        (&["source.sqsh", "invalid tag"], "<IMAGE_TAG>"),
    ];
    for (args, expected_diagnostic) in invalid_cases {
        let output = converter(xdg.path(), args)?;
        let stderr = std::str::from_utf8(&output.stderr)?;
        assert_eq!(output.status.code(), Some(2), "{args:?}: {stderr}");
        assert!(output.stdout.is_empty(), "{args:?}");
        assert!(stderr.starts_with("error:"), "{args:?}: {stderr}");
        assert!(stderr.contains(expected_diagnostic), "{args:?}: {stderr}");
    }
    Ok(())
}

#[test]
fn accepts_end_of_options_and_digest_qualified_destination() -> TestResult {
    let xdg = tempfile::tempdir()?;
    write_sarus_config(xdg.path(), "# Test with a command-line store override.\n")?;
    let store = xdg.path().join("store with spaces");
    let destination = format!("example:tag@sha256:{}", "a".repeat(64));
    for (image, policy) in [
        ("-source.sqsh", "--skip-dynamic-env"),
        ("-", "--resolve-host-env"),
        ("--store=literal", "--skip-dynamic-env"),
    ] {
        let output = converter(
            xdg.path(),
            &[
                "--store",
                store.to_str().unwrap(),
                "--allow-unrecognized-rc",
                "--allow-unrecognized-rc",
                policy,
                policy,
                "--",
                image,
                &destination,
            ],
        )?;
        let stderr = std::str::from_utf8(&output.stderr)?;
        assert_eq!(output.status.code(), Some(1), "{stderr}");
        assert!(
            stderr.contains(&format!(
                "SquashFS conversion is pending: {image} to {destination}"
            )),
            "{stderr}"
        );
    }
    assert!(!store.exists());
    Ok(())
}

#[test]
fn accepts_both_store_spellings_around_operands() -> TestResult {
    let xdg = tempfile::tempdir()?;
    write_sarus_config(xdg.path(), "# Leave hpc_image_store unset.\n")?;
    let store = xdg.path().join("store with spaces");
    let path = store.to_str().unwrap();
    let joined_option = format!("--store={path}");
    let cases: &[&[&str]] = &[
        &["--store", path, "source.sqsh", "example:tag"],
        &[&joined_option, "source.sqsh", "example:tag"],
        &["source.sqsh", &joined_option, "example:tag"],
        &["source.sqsh", "example:tag", "--store", path],
        &[&joined_option, "source.sqsh", "--", "example:tag"],
    ];
    for args in cases {
        let output = converter(xdg.path(), args)?;
        let stderr = std::str::from_utf8(&output.stderr)?;
        assert_eq!(output.status.code(), Some(1), "{args:?}: {stderr}");
        assert!(
            stderr.contains("SquashFS conversion is pending: source.sqsh to example:tag"),
            "{args:?}: {stderr}"
        );
    }
    assert!(!store.exists());
    Ok(())
}

#[test]
fn store_override_still_requires_sarus_configuration() -> TestResult {
    let xdg = tempfile::tempdir()?;
    write_sarus_config(xdg.path(), "invalid = [")?;
    let output = converter(
        xdg.path(),
        &[
            "--store",
            "override",
            "--resolve-host-env",
            "source.sqsh",
            "example:tag",
        ],
    )?;
    let stderr = std::str::from_utf8(&output.stderr)?;
    assert_eq!(output.status.code(), Some(1), "{stderr}");
    assert!(
        stderr.contains("Cannot load Sarus configuration"),
        "{stderr}"
    );
    Ok(())
}

#[test]
fn missing_configured_store_has_an_actionable_error() -> TestResult {
    let xdg = tempfile::tempdir()?;
    write_sarus_config(xdg.path(), "# Leave hpc_image_store unset.\n")?;
    let output = converter(xdg.path(), &["source.sqsh", "example:tag"])?;
    let stderr = std::str::from_utf8(&output.stderr)?;
    assert_eq!(output.status.code(), Some(1), "{stderr}");
    assert!(
        stderr.contains("Set hpc_image_store in the Sarus configuration or supply --store PATH")
    );
    Ok(())
}

const SMOKE_ROOT: &str = "ENROOT_TO_OCI_SMOKE_ROOT";
const SMOKE_TOOLS_DIR: &str = "ENROOT_TO_OCI_SMOKE_TOOLS_DIR";
const XDG_CONFIG_VARIABLES: [(&str, &str); 2] = [
    (
        "XDG_CONFIG_HOME",
        "ENROOT_TO_OCI_SMOKE_CALLER_XDG_CONFIG_HOME",
    ),
    (
        "XDG_CONFIG_DIRS",
        "ENROOT_TO_OCI_SMOKE_CALLER_XDG_CONFIG_DIRS",
    ),
];

fn set_fixture_xdg(
    command: &mut Command,
    fixture_xdg: &Path,
    caller_values: [Option<OsString>; 2],
) {
    for ((name, backup), value) in XDG_CONFIG_VARIABLES.into_iter().zip(caller_values) {
        command.env(name, fixture_xdg);
        match value {
            Some(value) => command.env(backup, value),
            None => command.env_remove(backup),
        };
    }
}

fn write_executable(path: &Path, script: &str) -> TestResult {
    fs::write(path, script)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn executable_fixture_dir() -> TestResult<tempfile::TempDir> {
    // The test binary's directory supports execution even if TMPDIR is mounted noexec.
    let binary = env::current_exe()?;
    let directory = binary
        .parent()
        .ok_or_else(|| format!("Test binary {} has no parent directory", binary.display()))?;
    Ok(tempfile::tempdir_in(directory)?)
}

fn write_tool_wrapper(path: &Path, tool: &str) -> TestResult {
    let mut script = String::from("#!/bin/sh\n");
    for (name, backup) in XDG_CONFIG_VARIABLES {
        script.push_str(&format!(
            r#"if [ "${{{backup}+x}}" = x ]; then
    export {name}="${backup}"
else
    unset {name}
fi
unset {backup}
"#
        ));
    }
    script.push_str(&format!("exec {tool} \"$@\"\n"));
    write_executable(path, &script)
}

#[test]
fn tool_wrappers_restore_caller_xdg() -> TestResult {
    let temporary = executable_fixture_dir()?;
    let directory = temporary.path();
    let fixture_xdg = Path::new("/fixture config");
    let storage_conf = "/runner storage/storage.conf";
    let stub = r#"#!/bin/sh
printf '%s\0' "${XDG_CONFIG_HOME+x}" "${XDG_CONFIG_HOME-}" \
    "${XDG_CONFIG_DIRS+x}" "${XDG_CONFIG_DIRS-}" \
    "${ENROOT_TO_OCI_SMOKE_CALLER_XDG_CONFIG_HOME+x}" "${ENROOT_TO_OCI_SMOKE_CALLER_XDG_CONFIG_DIRS+x}" \
    "$CONTAINERS_STORAGE_CONF" "$@"
"#;

    for tool in ["podman", "skopeo"] {
        write_executable(&directory.join(tool), stub)?;
        let wrapper = directory.join(format!("configured-{tool}"));
        write_tool_wrapper(&wrapper, tool)?;

        for [home, dirs] in [
            [
                Some("/runner config/$HOME"),
                Some("/runner/one:/runner/two"),
            ],
            [Some(""), None],
            [None, Some("")],
        ] {
            let mut child = Command::new("/bin/sh");
            child
                .env("PATH", directory)
                .env("CONTAINERS_STORAGE_CONF", storage_conf)
                .args([
                    "-c",
                    r#"printf '%s\0' "$XDG_CONFIG_HOME" "$XDG_CONFIG_DIRS"; exec "$@""#,
                    "fixture-child",
                ])
                .arg(&wrapper)
                .args(["argument with spaces", "--flag"]);
            for (_, backup) in XDG_CONFIG_VARIABLES {
                child.env(backup, "stale");
            }
            set_fixture_xdg(
                &mut child,
                fixture_xdg,
                [home, dirs].map(|value| value.map(OsString::from)),
            );

            let output = run(&mut child)?;
            let fields: Vec<_> = output.split_terminator('\0').collect();
            assert_eq!(
                fields,
                [
                    "/fixture config",
                    "/fixture config",
                    home.map_or("", |_| "x"),
                    home.unwrap_or_default(),
                    dirs.map_or("", |_| "x"),
                    dirs.unwrap_or_default(),
                    "",
                    "",
                    storage_conf,
                    "argument with spaces",
                    "--flag",
                ],
                "{tool} with caller XDG values {home:?} and {dirs:?}"
            );
        }
    }
    Ok(())
}

#[test]
#[ignore = "requires local rootless Podman and Skopeo"]
fn rootless_store_smoke() -> TestResult {
    if let Some(directory) = env::var_os(SMOKE_ROOT) {
        let tools_dir = env::var_os(SMOKE_TOOLS_DIR)
            .ok_or("Missing tool directory for the smoke test child")?;
        return exercise_store(Path::new(&directory), Path::new(&tools_dir));
    }

    let temporary = tempfile::Builder::new().prefix("enroot-cas-").tempdir()?;
    let tools = executable_fixture_dir()?;
    let directory = std::path::absolute(temporary.path())?;
    let xdg = directory.join("xdg");
    write_sarus_config(
        &xdg,
        "hpc_image_store = '${ENROOT_TO_OCI_SMOKE_ROOT}/configured-store'\n\
         podman_path = '${ENROOT_TO_OCI_SMOKE_TOOLS_DIR}/configured-podman'\n\
         skopeo_path = '${ENROOT_TO_OCI_SMOKE_TOOLS_DIR}/configured-skopeo'\n",
    )?;
    for tool in ["podman", "skopeo"] {
        let configured_tool = tools.path().join(format!("configured-{tool}"));
        write_tool_wrapper(&configured_tool, tool)?;
    }
    // Persist the store parent's directory entry before either import initializes a store.
    File::open(directory.parent().unwrap())?.sync_all()?;
    File::open(&directory)?.sync_all()?;

    // Raster reads the fixture configuration. The wrappers restore the caller's XDG values.
    let mut child = Command::new(env::current_exe()?);
    set_fixture_xdg(
        &mut child,
        &xdg,
        XDG_CONFIG_VARIABLES.map(|(name, _)| env::var_os(name)),
    );
    let report = run(child
        .env(SMOKE_ROOT, &directory)
        .env(SMOKE_TOOLS_DIR, tools.path())
        .args([
            "--ignored",
            "--exact",
            "rootless_store_smoke",
            "--nocapture",
        ]))?;
    print!("{report}");
    temporary.close()?;
    tools.close()?;
    Ok(())
}

fn exercise_store(directory: &Path, tools_dir: &Path) -> TestResult {
    let override_path = directory.join("override-store");
    let (configured, context) = load_transfer_settings(None)?;
    let (overridden, override_context) = load_transfer_settings(Some(&override_path))?;
    assert_eq!(configured.root(), directory.join("configured-store"));
    assert_eq!(overridden.root(), override_path);
    assert_eq!(context.podman, tools_dir.join("configured-podman"));
    assert_eq!(context.skopeo, tools_dir.join("configured-skopeo"));
    assert_eq!(override_context.podman, context.podman);
    assert_eq!(override_context.skopeo, context.skopeo);

    let rootless = run(Command::new(&context.podman).args([
        "info",
        "--format",
        "{{.Host.Security.Rootless}}",
    ]))?;
    assert_eq!(
        rootless.trim(),
        "true",
        "This test requires rootless Podman"
    );

    let rootfs = directory.join("rootfs");
    fs::create_dir(&rootfs)?;
    fs::write(rootfs.join("fixture.txt"), "Stage 1 CAS fixture\n")?;
    let archive = directory.join("fixture.tar");
    run(Command::new("tar")
        .arg("-C")
        .arg(&rootfs)
        .arg("-cf")
        .arg(&archive)
        .arg("."))?;

    let configured = Store::new(configured);
    let overridden = Store::new(overridden);
    let source = ImageSelector::new(format!(
        "localhost/enroot-to-oci-smoke:{}",
        directory.file_name().unwrap().to_str().unwrap()
    ))?;
    let configured_destination = ImageSelector::new("stage-one/fixture:configured")?;
    let override_destination = ImageSelector::new("stage-one/fixture:override")?;
    assert!(
        !fixture_tag_exists(&context, &source)?,
        "Fixture tag already exists: {source}"
    );

    let imports = (|| -> TestResult<_> {
        run(Command::new(&context.podman)
            .arg("import")
            .arg(&archive)
            .arg(source.as_str()))?;
        let options = ImportOptions::default();
        let configured_report =
            configured.import(&source, Some(&configured_destination), &context, &options)?;
        let override_report = overridden.import(
            &source,
            Some(&override_destination),
            &override_context,
            &options,
        )?;
        Ok((configured_report, override_report))
    })();
    let cleanup = remove_fixture_tag(&context, &source);
    if let Err(error) = &cleanup {
        eprintln!("Cannot clean up Podman fixture {source}: {error}");
    }
    let (configured_report, override_report) = imports?;
    cleanup?;

    assert_resolved(&configured, &configured_destination, &configured_report)?;
    assert_resolved(&overridden, &override_destination, &override_report)?;
    assert_eq!(configured.resolve(&override_destination)?, None);
    assert_eq!(overridden.resolve(&configured_destination)?, None);
    Ok(())
}

fn assert_resolved(
    store: &Store,
    destination: &ImageSelector,
    report: &ImportReport,
) -> TestResult {
    assert_eq!(report.local_ref.as_str(), destination.as_str());
    let expected = format!("{}@{}", destination.name(), report.stored_root);
    assert_eq!(
        store.resolve(destination)?.as_deref(),
        Some(expected.as_str())
    );
    println!(
        "{destination} resolved to {expected} in {}",
        store.config().root().display()
    );
    Ok(())
}

fn remove_fixture_tag(context: &TransferContext, source: &ImageSelector) -> TestResult {
    if fixture_tag_exists(context, source)? {
        run(Command::new(&context.podman).args(["image", "rm", "--", source.as_str()]))?;
    }
    Ok(())
}

fn fixture_tag_exists(context: &TransferContext, source: &ImageSelector) -> TestResult<bool> {
    let status = Command::new(&context.podman)
        .args(["image", "exists", source.as_str()])
        .status()?;
    match status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err(format!("Podman image exists {source} failed ({status})").into()),
    }
}

fn run(command: &mut Command) -> TestResult<String> {
    let output = command.output()?;
    if !output.status.success() {
        return Err(format!(
            "{command:?} failed ({})\n{}\n{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
        .into());
    }
    Ok(String::from_utf8(output.stdout)?)
}
