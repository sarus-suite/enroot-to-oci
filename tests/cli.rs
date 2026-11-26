mod support;

use std::{
    ffi::OsString,
    path::Path,
    process::{Command, Output},
};
use support::{
    TestResult, XDG_CONFIG_VARIABLES, executable_fixture_dir, run, set_fixture_xdg,
    write_executable, write_sarus_config, write_tool_wrapper,
};

fn converter(xdg: &Path, args: &[&str]) -> TestResult<Output> {
    Ok(Command::new(env!("CARGO_BIN_EXE_enroot-to-oci"))
        .current_dir(xdg)
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
        assert!(stdout.contains("--store"), "{args:?}: {stdout}");
    }

    let digest_only = format!("example@sha256:{}", "a".repeat(64));
    let invalid_cases: &[(&[&str], &str)] = &[
        (&[], "<IMAGE.sqsh>"),
        (&["source.sqsh"], "<IMAGE_REF>"),
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
        (&["source.sqsh", "example"], "<IMAGE_REF>"),
        (&["source.sqsh", "invalid tag"], "<IMAGE_REF>"),
        (&["source.sqsh", &digest_only], "requires an explicit tag"),
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
            stderr.contains(&format!("Cannot resolve {image}:")),
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
            stderr.contains("Cannot resolve source.sqsh:"),
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

#[test]
fn tool_wrappers_restore_caller_xdg() -> TestResult {
    let temporary = executable_fixture_dir()?;
    let directory = temporary.path();
    let fixture_xdg = Path::new("/fixture config");
    let storage_conf = "/runner storage/storage.conf";
    let stub = r#"#!/bin/sh
printf '%s\0' "${XDG_CONFIG_HOME+x}" "${XDG_CONFIG_HOME-}" \
    "${XDG_CONFIG_DIRS+x}" "${XDG_CONFIG_DIRS-}" \
    "${ENROOT_TO_OCI_TEST_CALLER_XDG_CONFIG_HOME+x}" "${ENROOT_TO_OCI_TEST_CALLER_XDG_CONFIG_DIRS+x}" \
    "$CONTAINERS_STORAGE_CONF" "$@"
"#;

    for tool in ["podman", "skopeo"] {
        write_executable(&directory.join(tool), stub)?;
        let wrapper = directory.join(format!("configured-{tool}"));
        write_tool_wrapper(&wrapper, &format!("exec {tool} \"$@\"\n"))?;

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
