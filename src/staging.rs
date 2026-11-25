mod metadata;
mod posix;

use std::{
    error::Error,
    ffi::OsString,
    fmt, fs, io,
    os::unix::{fs::PermissionsExt, process::ExitStatusExt},
    path::Path,
    process::{Child, Command, ExitStatus, Stdio},
};

#[derive(Clone, Copy, Debug, Default)]
pub enum HostEnvPolicy {
    #[default]
    Prompt,
    Skip,
    Resolve,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct StageOptions {
    pub host_env: HostEnvPolicy,
    pub allow_unrecognized_rc: bool,
}

#[derive(Debug)]
pub struct StageError {
    message: String,
    exit_code: u8,
}

impl StageError {
    fn validation(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            exit_code: 1,
        }
    }

    fn io(operation: impl fmt::Display, error: io::Error) -> Self {
        Self::validation(format!("{operation}: {error}"))
    }

    fn subprocess(operation: &str, status: ExitStatus) -> Self {
        let code = status
            .code()
            .or_else(|| status.signal().map(|signal| 128 + signal));
        Self {
            message: format!("{operation} failed with {status}"),
            exit_code: code.and_then(|code| u8::try_from(code).ok()).unwrap_or(1),
        }
    }

    /// The converter's exit status for this staging failure.
    pub fn exit_code(&self) -> u8 {
        self.exit_code
    }
}

impl fmt::Display for StageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for StageError {}

/// Extract an Enroot image and import its root filesystem into local Podman storage.
///
/// The caller supplies and manages an owned staging tag. An import can create the
/// tag before a failure in the pipeline is detected.
pub fn stage_image(
    image: &Path,
    podman_path: &Path,
    staging_tag: &str,
    options: StageOptions,
) -> Result<(), StageError> {
    let source = fs::canonicalize(image).map_err(|error| {
        StageError::io(format_args!("Cannot resolve {}", image.display()), error)
    })?;
    let source_metadata = fs::metadata(&source).map_err(|error| {
        StageError::io(format_args!("Cannot inspect {}", source.display()), error)
    })?;
    if !source_metadata.is_file() {
        return Err(StageError::validation(format!(
            "Not a regular file: {}",
            source.display()
        )));
    }

    let temporary = tempfile::Builder::new()
        .prefix("enroot-to-oci-")
        .tempdir()
        .map_err(|error| StageError::io("Cannot create staging directory", error))?;
    let rootfs = temporary.path().join("rootfs");
    let result = (|| {
        extract(&source, &rootfs)?;
        let changes = metadata::prepare(&rootfs, options)?;
        import(&rootfs, podman_path, staging_tag, &changes)
    })();

    let temporary_path = temporary.path().to_path_buf();
    if let Err(error) = temporary.close().or_else(|error| match error.kind() {
        io::ErrorKind::PermissionDenied => remove_read_only_tree(&temporary_path),
        _ => Err(error),
    }) {
        let cleanup = StageError::io(
            format_args!(
                "Cannot remove staging directory {}",
                temporary_path.display()
            ),
            error,
        );
        if result.is_ok() {
            return Err(cleanup);
        }
        eprintln!("WARNING: {cleanup}");
    }
    result
}

fn remove_read_only_tree(path: &Path) -> io::Result<()> {
    let mut directories = vec![path.to_path_buf()];
    while let Some(directory) = directories.pop() {
        let permissions = fs::symlink_metadata(&directory)?.permissions();
        if permissions.mode() & 0o700 != 0o700 {
            fs::set_permissions(
                &directory,
                fs::Permissions::from_mode(permissions.mode() | 0o700),
            )?;
        }
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                directories.push(entry.path());
            }
        }
    }
    fs::remove_dir_all(path)
}

fn extract(source: &Path, rootfs: &Path) -> Result<(), StageError> {
    let status = Command::new("unsquashfs")
        .args(["-no-progress", "-dest"])
        .arg(rootfs)
        .arg(source)
        .stdin(Stdio::null())
        .stdout(Stdio::from(io::stderr()))
        .status()
        .map_err(|error| StageError::io("Cannot run unsquashfs", error))?;
    if !status.success() {
        return Err(StageError::subprocess("unsquashfs", status));
    }
    Ok(())
}

fn import(
    rootfs: &Path,
    podman_path: &Path,
    staging_tag: &str,
    changes: &[OsString],
) -> Result<(), StageError> {
    let mut producer = Command::new("tar")
        .args([
            "--format=posix",
            "--numeric-owner",
            "--acls",
            "--xattrs",
            "-C",
        ])
        .arg(rootfs)
        .args(["-cpf", "-", "."])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|error| StageError::io("Cannot start tar", error))?;

    let pipe = producer.stdout.take().expect("tar stdout is piped");
    let consumer = {
        let mut command = Command::new(podman_path);
        command.arg("import");
        for change in changes {
            command.arg("--change").arg(change);
        }
        command
            .args(["-", staging_tag])
            .stdin(Stdio::from(pipe))
            .stdout(Stdio::null())
            .spawn()
    };
    let mut consumer = match consumer {
        Ok(child) => child,
        Err(error) => {
            terminate_and_reap(&mut producer);
            return Err(StageError::io(
                format_args!("Cannot start Podman import ({})", podman_path.display()),
                error,
            ));
        }
    };

    let podman_status = wait(&mut consumer, "Podman import");
    let tar_status = wait(&mut producer, "tar");
    let podman_status = podman_status?;
    if !podman_status.success() {
        return Err(StageError::subprocess("Podman import", podman_status));
    }
    let tar_status = tar_status?;
    if !tar_status.success() {
        return Err(StageError::subprocess("tar", tar_status));
    }
    Ok(())
}

fn wait(child: &mut Child, operation: &str) -> Result<ExitStatus, StageError> {
    child.wait().map_err(|error| {
        terminate_and_reap(child);
        StageError::io(format_args!("Cannot wait for {operation}"), error)
    })
}

fn terminate_and_reap(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}
