use clap::Parser;
use enroot_to_oci::{HostEnvPolicy, StageOptions, convert_image};
use hpc_image_store::ImageSelector;
use std::{path::PathBuf, process::ExitCode};

#[derive(Parser)]
#[command(
    name = "enroot-to-oci",
    about = "Convert Enroot Squashfs images and import them into a Sarus Suite OCI store"
)]
struct Cli {
    /// Destination CAS directory
    #[arg(long, value_name = "PATH")]
    store: Option<PathBuf>,

    /// Omit assignments that use Enroot host substitutions. Conflicts with --resolve-host-env
    #[arg(
        long,
        conflicts_with = "resolve_host_env",
        overrides_with = "skip_dynamic_env"
    )]
    skip_dynamic_env: bool,

    /// Expand host substitutions into the image metadata. Conflicts with --skip-dynamic-env
    #[arg(long, overrides_with = "resolve_host_env")]
    resolve_host_env: bool,

    /// Keep a custom /etc/rc if its working directory cannot be recovered
    #[arg(long, overrides_with = "allow_unrecognized_rc")]
    allow_unrecognized_rc: bool,

    /// Input Enroot SquashFS image
    #[arg(value_name = "IMAGE.sqsh")]
    image: PathBuf,

    /// Destination image reference with an explicit tag
    #[arg(value_name = "IMAGE_REF", value_parser = parse_destination)]
    destination: ImageSelector,
}

fn parse_destination(value: &str) -> Result<ImageSelector, String> {
    let destination = ImageSelector::new(value).map_err(|error| error.to_string())?;
    if destination.tag().is_none() {
        return Err("CAS destination requires an explicit tag".into());
    }
    Ok(destination)
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let options = StageOptions {
        host_env: if cli.skip_dynamic_env {
            HostEnvPolicy::Skip
        } else if cli.resolve_host_env {
            HostEnvPolicy::Resolve
        } else {
            HostEnvPolicy::Prompt
        },
        allow_unrecognized_rc: cli.allow_unrecognized_rc,
    };
    match convert_image(&cli.image, &cli.destination, cli.store.as_deref(), options) {
        Ok(report) => {
            if let Some(digest) = &report.ignored_destination_digest {
                eprintln!(
                    "WARNING: Ignored destination digest {digest} for {}",
                    report.local_ref
                );
            }
            println!("Published {} {}", report.local_ref, report.stored_root);
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(error.exit_code())
        }
    }
}
