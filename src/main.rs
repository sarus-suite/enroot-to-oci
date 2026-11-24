use clap::Parser;
use enroot_to_oci::load_transfer_settings;
use hpc_image_store::ImageSelector;
use std::{path::PathBuf, process::ExitCode};

#[derive(Parser)]
#[command(
    name = "enroot-to-oci",
    about = "Convert Enroot Squashfs images and import them into a Sarus Suite OCI store"
)]
struct Cli {
    /// Select the CAS directory with --store PATH or --store=PATH
    #[arg(long, value_name = "PATH")]
    store: Option<PathBuf>,

    /// Omit assignments that use Enroot host substitutions
    #[arg(
        long,
        conflicts_with = "resolve_host_env",
        overrides_with = "skip_dynamic_env"
    )]
    skip_dynamic_env: bool,

    /// Expand host substitutions into the image metadata
    #[arg(long, overrides_with = "resolve_host_env")]
    resolve_host_env: bool,

    /// Keep a custom /etc/rc if its working directory cannot be recovered
    #[arg(long, overrides_with = "allow_unrecognized_rc")]
    allow_unrecognized_rc: bool,

    /// Input Enroot SquashFS image
    #[arg(value_name = "IMAGE.sqsh")]
    image: PathBuf,

    /// Requested CAS destination selector
    #[arg(value_name = "IMAGE_TAG")]
    destination: ImageSelector,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    if let Err(error) = load_transfer_settings(cli.store.as_deref()) {
        eprintln!("{error}");
        return ExitCode::FAILURE;
    }

    eprintln!(
        "SquashFS conversion is pending: {} to {}",
        cli.image.display(),
        cli.destination
    );
    ExitCode::FAILURE
}
