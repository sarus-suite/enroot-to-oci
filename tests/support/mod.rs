use std::{
    env, error::Error, ffi::OsString, fs, os::unix::fs::PermissionsExt, path::Path,
    process::Command,
};

pub type TestResult<T = ()> = Result<T, Box<dyn Error>>;

pub const XDG_CONFIG_VARIABLES: [(&str, &str); 2] = [
    (
        "XDG_CONFIG_HOME",
        "ENROOT_TO_OCI_SMOKE_CALLER_XDG_CONFIG_HOME",
    ),
    (
        "XDG_CONFIG_DIRS",
        "ENROOT_TO_OCI_SMOKE_CALLER_XDG_CONFIG_DIRS",
    ),
];

pub fn set_fixture_xdg(
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

pub fn write_sarus_config(xdg: &Path, contents: &str) -> TestResult {
    let config_dir = xdg.join("sarus-suite");
    fs::create_dir_all(&config_dir)?;
    fs::write(config_dir.join("test.conf"), contents)?;
    Ok(())
}

pub fn write_executable(path: &Path, script: &str) -> TestResult {
    fs::write(path, script)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub fn executable_fixture_dir() -> TestResult<tempfile::TempDir> {
    // The test binary's directory supports execution even if TMPDIR is mounted noexec.
    let binary = env::current_exe()?;
    let directory = binary
        .parent()
        .ok_or_else(|| format!("Test binary {} has no parent directory", binary.display()))?;
    Ok(tempfile::tempdir_in(directory)?)
}

pub fn write_tool_wrapper(path: &Path, body: &str) -> TestResult {
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
    script.push_str(body);
    write_executable(path, &script)
}

pub fn run(command: &mut Command) -> TestResult<String> {
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
