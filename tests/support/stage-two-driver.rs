use clap::Parser;
use enroot_to_oci::{HostEnvPolicy, StageOptions, load_transfer_settings, stage_image};
use std::{path::PathBuf, process::ExitCode};

/// Exercise staging with a tag owned by the test.
#[derive(Parser)]
struct Args {
    /// Load the configured Podman path from Sarus using this test store path.
    #[arg(long)]
    store: Option<PathBuf>,

    #[arg(long, conflicts_with = "resolve_host_env")]
    skip_dynamic_env: bool,

    #[arg(long)]
    resolve_host_env: bool,

    #[arg(long)]
    allow_unrecognized_rc: bool,

    image: PathBuf,
    staging_tag: String,
}

fn main() -> ExitCode {
    let args = Args::parse();
    let podman = if let Some(store) = args.store.as_deref() {
        match load_transfer_settings(Some(store)) {
            Ok((_, context)) => context.podman,
            Err(error) => {
                eprintln!("{error}");
                return ExitCode::FAILURE;
            }
        }
    } else {
        PathBuf::from("podman")
    };

    let options = StageOptions {
        host_env: if args.skip_dynamic_env {
            HostEnvPolicy::Skip
        } else if args.resolve_host_env {
            HostEnvPolicy::Resolve
        } else {
            HostEnvPolicy::Prompt
        },
        allow_unrecognized_rc: args.allow_unrecognized_rc,
    };
    match stage_image(&args.image, &podman, &args.staging_tag, options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(error.exit_code())
        }
    }
}
