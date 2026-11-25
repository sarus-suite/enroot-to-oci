mod environment;

use super::{
    StageError, StageOptions,
    posix::{CharacterLocale, Pattern},
};
use std::{
    collections::VecDeque,
    ffi::{OsStr, OsString},
    fs::{self, File, Metadata},
    io::{self, BufRead, BufReader},
    ops::Range,
    os::unix::{
        ffi::{OsStrExt, OsStringExt},
        fs::PermissionsExt,
    },
    path::{Path, PathBuf},
};

struct ConfigFiles {
    rc: Option<PathBuf>,
    environment: Option<PathBuf>,
    fstab: Option<PathBuf>,
}

impl ConfigFiles {
    fn inspect(rootfs: &Path) -> Result<Self, StageError> {
        if !path_metadata(rootfs)?.is_some_and(|metadata| metadata.is_dir()) {
            return Err(StageError::validation(
                "Extracted rootfs is not a directory",
            ));
        }
        let etc = rootfs.join("etc");
        if checked_metadata(&etc, "/etc")?
            .filter(Metadata::is_dir)
            .is_none()
        {
            return Ok(Self {
                rc: None,
                environment: None,
                fstab: None,
            });
        }

        let rc = etc.join("rc");
        let environment = etc.join("environment");
        let fstab = etc.join("fstab");
        let rc_metadata = checked_metadata(&rc, "/etc/rc")?;
        let environment_metadata = checked_metadata(&environment, "/etc/environment")?;
        let fstab_metadata = checked_metadata(&fstab, "/etc/fstab")?;
        if rc_metadata
            .as_ref()
            .is_some_and(|metadata| !metadata.is_file())
        {
            return Err(StageError::validation(
                "Unsupported rootfs: /etc/rc is not a regular file",
            ));
        }
        Ok(Self {
            rc: rc_metadata.map(|_| rc),
            environment: environment_metadata
                .filter(Metadata::is_file)
                .map(|_| environment),
            fstab: fstab_metadata.filter(Metadata::is_file).map(|_| fstab),
        })
    }
}

fn path_metadata(path: &Path) -> Result<Option<Metadata>, StageError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(StageError::io(
            format_args!("Cannot inspect {}", path.display()),
            error,
        )),
    }
}

fn checked_metadata(path: &Path, image_path: &str) -> Result<Option<Metadata>, StageError> {
    let metadata = path_metadata(path)?;
    if metadata
        .as_ref()
        .is_some_and(|metadata| metadata.is_symlink())
    {
        return Err(StageError::validation(format!(
            "Unsupported rootfs: {image_path} is a symlink"
        )));
    }
    Ok(metadata)
}

pub(super) fn prepare(rootfs: &Path, options: StageOptions) -> Result<Vec<OsString>, StageError> {
    let files = ConfigFiles::inspect(rootfs)?;
    let locale = CharacterLocale::activate()?;
    let leading_space = Pattern::new(&locale, c"^[[:space:]]*")?;
    let mut changes = Vec::new();

    if let Some(rc) = files.rc {
        prepare_rc(
            rootfs,
            &rc,
            options.allow_unrecognized_rc,
            &locale,
            &mut changes,
        )?;
    } else {
        eprintln!("WARNING: no /etc/rc; using /bin/sh as a fallback entrypoint");
        changes.push(r#"ENTRYPOINT ["/bin/sh"]"#.into());
    }
    if let Some(environment_file) = files.environment {
        environment::prepare(
            &environment_file,
            options.host_env,
            &locale,
            &leading_space,
            &mut changes,
        )?;
    }
    if let Some(fstab) = files.fstab {
        warn_about_mounts(&fstab, &leading_space)?;
    }
    if changes.iter().any(|change| change.as_bytes().contains(&0)) {
        return Err(StageError::validation(
            "Image metadata contains a NUL byte unsupported by Podman import",
        ));
    }
    Ok(changes)
}

fn prepare_rc(
    rootfs: &Path,
    rc: &Path,
    allow_unrecognized_rc: bool,
    locale: &CharacterLocale,
    changes: &mut Vec<OsString>,
) -> Result<(), StageError> {
    let entrypoint = if image_has_executable(rootfs, Path::new("/bin/bash"))? {
        r#"ENTRYPOINT ["/bin/bash","/etc/rc"]"#
    } else if image_has_executable(rootfs, Path::new("/usr/bin/bash"))? {
        r#"ENTRYPOINT ["/usr/bin/bash","/etc/rc"]"#
    } else {
        return Err(StageError::validation(
            "Enroot /etc/rc exists but Bash is not present as an executable regular file in the rootfs",
        ));
    };

    let script =
        fs::read(rc).map_err(|error| StageError::io("Cannot read staged /etc/rc", error))?;
    let mkdir_prefix = Pattern::new(locale, c"^mkdir[[:space:]]+-p[[:space:]]+\"")?;
    let mkdir_suffix = Pattern::new(locale, c"^[[:space:]]+2>[[:space:]]*/dev/null$")?;
    if let Some(RecoveredWorkdir { path, pair }) =
        recover_workdir(&script, &mkdir_prefix, &mkdir_suffix)?
    {
        let change = workdir_change(path)?;
        let mut edited = Vec::with_capacity(script.len() - pair.len());
        edited.extend_from_slice(&script[..pair.start]);
        edited.extend_from_slice(&script[pair.end..]);
        edit_rc(rc, &edited)
            .map_err(|error| StageError::io("Cannot edit staged /etc/rc", error))?;
        changes.push(change);
    } else if allow_unrecognized_rc {
        eprintln!(
            "WARNING: cannot recover a unique Enroot-generated WORKDIR; preserving /etc/rc unchanged"
        );
        eprintln!("WARNING: /etc/rc may override podman run -w if it changes directory");
    } else {
        return Err(StageError::validation(
            "Cannot safely recover WORKDIR from /etc/rc. Use --allow-unrecognized-rc to keep it unchanged.",
        ));
    }

    changes.push(entrypoint.into());
    if let Some(source) = script
        .split(|&byte| byte == b'\n')
        .find_map(|line| line.strip_prefix(b"# enroot-provenance: "))
        .filter(|source| !source.is_empty())
    {
        changes.push(change_with_value(
            b"LABEL org.opencontainers.image.source=",
            source,
        ));
    }
    Ok(())
}

fn change_with_value(prefix: &[u8], value: &[u8]) -> OsString {
    OsString::from_vec([prefix, value].concat())
}

fn workdir_change(path: &[u8]) -> Result<OsString, StageError> {
    let path = std::str::from_utf8(path)
        .map_err(|_| StageError::validation("Working directory in /etc/rc is not valid UTF-8"))?;
    if path.contains('\0') {
        return Err(StageError::validation(
            "Working directory in /etc/rc contains a NUL byte",
        ));
    }
    let mut change = format!("WORKDIR {path}");
    // Podman trims the operand before cleaning the path, which removes this suffix.
    if path.ends_with(char::is_whitespace) {
        change.push_str("/.");
    }
    Ok(change.into())
}

fn edit_rc(rc: &Path, contents: &[u8]) -> io::Result<()> {
    let result = fs::write(rc, contents);
    if !matches!(&result, Err(error) if error.kind() == io::ErrorKind::PermissionDenied) {
        return result;
    }
    let permissions = fs::metadata(rc)?.permissions();
    if permissions.mode() & 0o200 != 0 {
        return result;
    }
    fs::set_permissions(rc, fs::Permissions::from_mode(permissions.mode() | 0o200))?;
    let write_result = fs::write(rc, contents);
    let restore_result = fs::set_permissions(rc, permissions);
    write_result.and(restore_result)
}

struct RecoveredWorkdir<'script> {
    path: &'script [u8],
    pair: Range<usize>,
}

fn recover_workdir<'script>(
    script: &'script [u8],
    mkdir_prefix: &Pattern<'_>,
    mkdir_suffix: &Pattern<'_>,
) -> Result<Option<RecoveredWorkdir<'script>>, StageError> {
    let mut lines = script.split_inclusive(|&byte| byte == b'\n').peekable();
    let mut offset = 0;
    let mut workdir = None;
    while let Some(line) = lines.next() {
        let start = offset;
        offset += line.len();
        let Some(cd_line) = lines.peek() else { break };
        let line = line.strip_suffix(b"\n").unwrap_or(line);
        let Some(prefix) = mkdir_prefix.find(line)? else {
            continue;
        };
        // Keep path bytes out of the locale-sensitive regex so invalid UTF-8
        // can be recognized as a generated pair and reported explicitly.
        let operand = &line[prefix.end..];
        let Some(closing_quote) = operand.iter().position(|&byte| byte == b'"') else {
            continue;
        };
        let path = &operand[..closing_quote];
        let suffix = &operand[closing_quote + 1..];
        if mkdir_suffix.find(suffix)?.is_none() {
            continue;
        }
        if !path.starts_with(b"/")
            || path
                .iter()
                .any(|byte| matches!(byte, b'\\' | b'$' | b'\x60'))
        {
            continue;
        }

        let cd_command = [b"cd \"".as_slice(), path, b"\" && unset OLDPWD || exit 1"].concat();
        if cd_line.strip_suffix(b"\n").unwrap_or(cd_line) != cd_command {
            continue;
        }
        if workdir.is_some() {
            return Ok(None);
        }
        offset += cd_line.len();
        lines.next();
        workdir = Some(RecoveredWorkdir {
            path,
            pair: start..offset,
        });
    }
    Ok(workdir)
}

// Resolve the candidates with the same root for absolute and relative image symlinks.
fn image_has_executable(rootfs: &Path, path: &Path) -> Result<bool, StageError> {
    let mut directory = rootfs.to_path_buf();
    let mut remaining: VecDeque<OsString> = path.iter().map(OsStr::to_os_string).collect();
    let mut symlinks = 0;
    while let Some(component) = remaining.pop_front() {
        if component == "/" {
            directory = rootfs.to_path_buf();
            continue;
        }
        if component == ".." {
            if directory != rootfs {
                directory.pop();
            }
            continue;
        }

        let entry = directory.join(component);
        let Some(metadata) = path_metadata(&entry)? else {
            return Ok(false);
        };
        if metadata.is_symlink() {
            symlinks += 1;
            if symlinks > 40 {
                return Ok(false);
            }
            let target = fs::read_link(&entry).map_err(|error| {
                StageError::io(
                    format_args!("Cannot read image symlink {}", entry.display()),
                    error,
                )
            })?;
            let target_bytes = target.as_os_str().as_bytes();
            // Path::iter drops trailing separators and dots, but both require a directory.
            if target_bytes.ends_with(b"/") || target_bytes.ends_with(b"/.") {
                remaining.push_front(".".into());
            }
            for component in target.iter().rev() {
                remaining.push_front(component.to_os_string());
            }
        } else if remaining.is_empty() {
            return Ok(metadata.is_file() && metadata.permissions().mode() & 0o111 != 0);
        } else if metadata.is_dir() {
            directory = entry;
        } else {
            return Ok(false);
        }
    }
    Ok(false)
}

fn warn_about_mounts(fstab: &Path, leading_space: &Pattern<'_>) -> Result<(), StageError> {
    let diagnostic = |error| StageError::io("Cannot read staged /etc/fstab", error);
    let file = File::open(fstab).map_err(diagnostic)?;
    for line in BufReader::new(file).split(b'\n') {
        let line = line.map_err(diagnostic)?;
        let entry = trim_start(&line, leading_space)?;
        if !entry.is_empty() && !entry.starts_with(b"#") {
            eprintln!(
                "WARNING: /etc/fstab has Enroot-specific mounts. Configure them at container runtime."
            );
            break;
        }
    }
    Ok(())
}

fn trim_start<'line>(
    line: &'line [u8],
    leading_space: &Pattern<'_>,
) -> Result<&'line [u8], StageError> {
    let start = leading_space.find(line)?.map_or(0, |range| range.end);
    Ok(&line[start..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unrepresentable_workdir_leaves_staged_rc_intact() {
        let staged = tempfile::tempdir().unwrap();
        let rootfs = staged.path();
        fs::create_dir(rootfs.join("bin")).unwrap();
        let bash = rootfs.join("bin/bash");
        fs::write(&bash, b"").unwrap();
        fs::set_permissions(&bash, fs::Permissions::from_mode(0o755)).unwrap();

        let rc = rootfs.join("rc");
        let locale = CharacterLocale::activate().unwrap();
        for (byte, diagnostic) in [(0xff, "not valid UTF-8"), (0, "contains a NUL byte")] {
            let path = [b"/workdir".as_slice(), &[byte]].concat();
            let script = [
                b"mkdir -p \"".as_slice(),
                &path,
                b"\" 2> /dev/null\ncd \"",
                &path,
                b"\" && unset OLDPWD || exit 1\n",
            ]
            .concat();
            fs::write(&rc, &script).unwrap();

            let mut changes = Vec::new();
            let error = prepare_rc(rootfs, &rc, true, &locale, &mut changes).unwrap_err();
            assert_eq!(error.exit_code(), 1);
            assert!(error.to_string().contains(diagnostic), "{error}");
            assert!(changes.is_empty());
            assert_eq!(fs::read(&rc).unwrap(), script);
        }
    }
}
