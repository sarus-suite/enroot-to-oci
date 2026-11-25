use super::{CharacterLocale, Pattern, StageError, trim_start};
use crate::HostEnvPolicy;
use std::{
    collections::HashMap,
    env,
    ffi::OsString,
    fs::{File, OpenOptions},
    io::{BufRead, BufReader, Write},
    ops::Range,
    os::unix::ffi::OsStrExt,
    path::Path,
};

pub(super) fn prepare(
    environment_file: &Path,
    mut policy: HostEnvPolicy,
    locale: &CharacterLocale,
    leading_space: &Pattern<'_>,
    changes: &mut Vec<OsString>,
) -> Result<(), StageError> {
    let assignment_name = Pattern::new(locale, c"^[[:alpha:]_][[:alnum:]_]*$")?;
    let trailing_space = Pattern::new(locale, c"[[:space:]]*$")?;
    let diagnostic = |error| StageError::io("Cannot read staged /etc/environment", error);
    let file = File::open(environment_file).map_err(diagnostic)?;
    let mut assignments = Assignments::default();

    for (index, line) in BufReader::new(file).split(b'\n').enumerate() {
        let line_number = index + 1;
        let line = line.map_err(diagnostic)?;
        let line = trim_start(&line, leading_space)?;
        if is_ignored_line(line) {
            continue;
        }
        let raw_assignment = split_assignment(line, &assignment_name)?;
        if raw_assignment.is_some_and(|(name, _)| name.starts_with(b"ENROOT_")) {
            continue;
        }

        // A reference in an otherwise malformed value cannot make its key valid.
        // A reference before the first equals sign can produce a name or assignment.
        let reference_input = if raw_assignment.is_some() {
            line
        } else {
            line.split(|&byte| byte == b'=').next().unwrap_or_default()
        };
        let expanded;
        let line = if host_references(reference_input).next().is_some() {
            if matches!(policy, HostEnvPolicy::Prompt) {
                policy = choose_policy(line_number)?;
            }
            if matches!(policy, HostEnvPolicy::Skip) {
                if let Some((name, _)) = raw_assignment {
                    assignments.clear(name);
                }
                continue;
            }
            expanded = expand(line);
            trim_start(&expanded, leading_space)?
        } else {
            line
        };
        if is_ignored_line(line) {
            continue;
        }

        let Some((name, value)) = split_assignment(line, &assignment_name)? else {
            eprintln!(
                "WARNING: /etc/environment:{line_number}: ignoring malformed environment assignment"
            );
            continue;
        };
        if name.starts_with(b"ENROOT_") {
            continue;
        }

        let value = unquote(value, &trailing_space)?;
        if value.iter().any(|byte| matches!(byte, b'\n' | b'\r')) {
            let name = String::from_utf8_lossy(name);
            return Err(StageError::validation(format!(
                "/etc/environment:{line_number}: {name} contains a newline/CR unsupported by podman import --change ENV"
            )));
        }
        assignments.set(name, value, line_number);
    }

    for change in assignments.into_changes() {
        changes.push(change?);
    }
    Ok(())
}

type Assignment<'line> = (&'line [u8], &'line [u8]);

fn split_assignment<'line>(
    line: &'line [u8],
    assignment_name: &Pattern<'_>,
) -> Result<Option<Assignment<'line>>, StageError> {
    let Some(equals) = line.iter().position(|&byte| byte == b'=') else {
        return Ok(None);
    };
    let name = &line[..equals];
    Ok(assignment_name
        .find(name)?
        .map(|_| (name, &line[equals + 1..])))
}

fn is_ignored_line(line: &[u8]) -> bool {
    line.is_empty() || line.starts_with(b"#")
}

fn unquote<'value>(
    value: &'value [u8],
    trailing_space: &Pattern<'_>,
) -> Result<&'value [u8], StageError> {
    if matches!(value.first(), Some(b'\'' | b'"')) {
        let end = trailing_space
            .find(value)?
            .map_or(value.len(), |range| range.start);
        if end >= 2 && matches!(value[end - 1], b'\'' | b'"') {
            return Ok(&value[1..end - 1]);
        }
    }
    Ok(value)
}

fn choose_policy(line_number: usize) -> Result<HostEnvPolicy, StageError> {
    let mut terminal = OpenOptions::new().read(true).write(true).open("/dev/tty").map_err(|error| {
        StageError::validation(format!(
            "/etc/environment:{line_number}: Host substitution requires --skip-dynamic-env or --resolve-host-env without a controlling terminal ({error})"
        ))
    })?;
    terminal
        .write_all(
            concat!(
                "WARNING: Enroot host expansion can embed credentials in image metadata.\n",
                "Provide --skip-dynamic-env or --resolve-host-env to skip this prompt.\n",
                "Expand host-dependent assignments? [y/N] ",
            )
            .as_bytes(),
        )
        .and_then(|_| terminal.flush())
        .map_err(|error| StageError::io("Cannot write host expansion prompt", error))?;
    let mut reply = Vec::new();
    BufReader::new(terminal)
        .read_until(b'\n', &mut reply)
        .map_err(|error| StageError::io("Cannot read host expansion reply", error))?;
    Ok(match reply.as_slice() {
        b"y\n" | b"Y\n" => HostEnvPolicy::Resolve,
        _ => HostEnvPolicy::Skip,
    })
}

fn host_references(line: &[u8]) -> impl Iterator<Item = (Range<usize>, &str)> {
    line.windows(2)
        .enumerate()
        .filter(|(_, pair)| *pair == b"${")
        .filter_map(|(start, _)| {
            let name_start = start + 2;
            let remainder = &line[name_start..];
            let first = *remainder.first()?;
            if !(first.is_ascii_alphabetic() || first == b'_') {
                return None;
            }
            let length = remainder
                .iter()
                .take_while(|&&byte| byte.is_ascii_alphanumeric() || byte == b'_')
                .count();
            if remainder.get(length) != Some(&b'}') {
                return None;
            }
            let name = std::str::from_utf8(&remainder[..length]).expect("host reference is ASCII");
            Some((start..name_start + length + 1, name))
        })
}

fn expand(line: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(line.len());
    let mut copied = 0;
    for (reference, name) in host_references(line) {
        result.extend_from_slice(&line[copied..reference.start]);
        if let Some(value) = env::var_os(name) {
            result.extend_from_slice(value.as_bytes());
        }
        copied = reference.end;
    }
    result.extend_from_slice(&line[copied..]);
    result
}

#[derive(Default)]
struct Assignments {
    positions: HashMap<Vec<u8>, usize>,
    ordered: Vec<(Vec<u8>, Option<AssignmentValue>)>,
}

struct AssignmentValue {
    bytes: Vec<u8>,
    line_number: usize,
}

impl Assignments {
    fn set(&mut self, name: &[u8], value: &[u8], line_number: usize) {
        let position = *self.positions.entry(name.to_vec()).or_insert_with(|| {
            let position = self.ordered.len();
            self.ordered.push((name.to_vec(), None));
            position
        });
        self.ordered[position].1 = Some(AssignmentValue {
            bytes: value.to_vec(),
            line_number,
        });
    }

    fn clear(&mut self, name: &[u8]) {
        if let Some(&position) = self.positions.get(name) {
            self.ordered[position].1 = None;
        }
    }

    fn into_changes(self) -> impl Iterator<Item = Result<OsString, StageError>> {
        self.ordered.into_iter().filter_map(|(name, value)| {
            let value = value?;
            Some(environment_change(&name, &value))
        })
    }
}

fn environment_change(name: &[u8], value: &AssignmentValue) -> Result<OsString, StageError> {
    let invalid = |_| {
        StageError::validation(format!(
            "/etc/environment:{}: environment assignment is not valid UTF-8",
            value.line_number,
        ))
    };
    let name = std::str::from_utf8(name).map_err(invalid)?;
    let value = std::str::from_utf8(&value.bytes).map_err(invalid)?;
    Ok(format!("ENV {name}=\"{value}\"").into())
}
