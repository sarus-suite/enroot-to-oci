use crate::{
    StageError, StageOptions, load_transfer_settings,
    staging::{import_rootfs, with_prepared_rootfs},
};
use hpc_image_store::{ImageSelector, ImportOptions, ImportReport, Store};
use std::{
    error::Error,
    fmt,
    path::Path,
    process::{Command, Output, Stdio},
};

#[derive(Debug)]
pub enum ConversionError {
    Configuration(String),
    Staging(StageError),
    Publication(hpc_image_store::Error),
}

impl ConversionError {
    /// The converter's exit status for this failure.
    pub fn exit_code(&self) -> u8 {
        match self {
            Self::Staging(error) => error.exit_code(),
            Self::Configuration(_) | Self::Publication(_) => 1,
        }
    }
}

impl fmt::Display for ConversionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(message) => formatter.write_str(message),
            Self::Staging(error) => error.fmt(formatter),
            Self::Publication(error) => write!(formatter, "Cannot publish to the CAS: {error}"),
        }
    }
}

impl Error for ConversionError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Configuration(_) => None,
            Self::Staging(error) => Some(error),
            Self::Publication(error) => Some(error),
        }
    }
}

/// Convert an Enroot image and publish it to the configured Sarus store.
///
/// `destination` must have an explicit tag. The CLI enforces this when parsing `IMAGE_TAG`.
///
/// A failure to remove the Podman staging tag is reported on stderr. After a
/// successful publication, the committed image is still returned to the caller.
pub fn convert_image(
    image: &Path,
    destination: &ImageSelector,
    store_override: Option<&Path>,
    options: StageOptions,
) -> Result<ImportReport, ConversionError> {
    let (config, context) =
        load_transfer_settings(store_override).map_err(ConversionError::Configuration)?;
    let mut staging_tag = None;
    let result = (|| {
        // Extract the Enroot image and import its root filesystem into local Podman storage.
        with_prepared_rootfs(image, options, |rootfs, changes| {
            let tag = staging_tag.insert(allocate_staging_tag(&context.podman, destination)?);
            import_rootfs(rootfs, &context.podman, tag, changes)
        })
        .map_err(ConversionError::Staging)?;

        let tag = staging_tag.as_deref().expect("staging assigned a tag");
        let source = ImageSelector::new(tag).map_err(ConversionError::Publication)?;

        // Import the image from Podman into the OCI CAS
        Store::new(config)
            .import(
                &source,
                Some(destination),
                &context,
                &ImportOptions::default(),
            )
            .map_err(ConversionError::Publication)
    })();

    if let Some(tag) = staging_tag {
        remove_staging_tag(&context.podman, &tag);
    }
    result
}

fn allocate_staging_tag(podman: &Path, destination: &ImageSelector) -> Result<String, StageError> {
    loop {
        let mut random_bytes = [0; 16];
        getrandom::fill(&mut random_bytes).map_err(|error| {
            StageError::validation(format!("Cannot generate a Podman staging tag: {error}"))
        })?;
        let suffix = format!("{:032x}", u128::from_be_bytes(random_bytes));
        if destination.tag() == Some(suffix.as_str()) {
            continue;
        }
        let tag = format!("localhost/enroot-to-oci-stage:{suffix}");
        if !staging_tag_exists(podman, &tag)? {
            return Ok(tag);
        }
    }
}

fn staging_tag_exists(podman: &Path, tag: &str) -> Result<bool, StageError> {
    let operation = format!("Cannot check Podman staging tag {tag}");
    let output = Command::new(podman)
        .args(["image", "exists", "--", tag])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| StageError::io(&operation, error))?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err(StageError::validation(podman_failure(&operation, &output))),
    }
}

fn remove_staging_tag(podman: &Path, tag: &str) {
    let operation = format!("Cannot remove Podman staging tag {tag}");
    let error = match Command::new(podman)
        .args(["image", "rm", "--ignore", "--no-prune", "--", tag])
        .stdin(Stdio::null())
        .output()
    {
        Ok(output) if output.status.success() => return,
        Ok(output) => podman_failure(&operation, &output),
        Err(error) => format!("{operation}: {error}"),
    };
    eprintln!("WARNING: {error}");
    match staging_tag_exists(podman, tag) {
        Ok(true) => eprintln!("WARNING: Podman staging tag {tag} remains"),
        Ok(false) => (),
        Err(error) => eprintln!("WARNING: Podman staging tag {tag} may remain: {error}"),
    }
}

fn podman_failure(operation: &str, output: &Output) -> String {
    let status = output.status;
    let stderr = String::from_utf8_lossy(&output.stderr);
    let diagnostic = stderr.trim_end();
    if diagnostic.is_empty() {
        format!("{operation} ({status})")
    } else {
        format!("{operation} ({status}): {diagnostic}")
    }
}
