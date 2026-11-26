use clap::Parser;
use hpc_image_store::{CheckScope, ImageSelector, Store, StoreConfig, TransferContext};
use std::{error::Error, path::PathBuf, process::Command};

/// Verify a converter publication and restore it to an unused local Podman tag.
#[derive(Parser)]
struct Args {
    store: PathBuf,
    reference: String,
    publication: String,
    restored_tag: String,
    #[arg(long)]
    podman: PathBuf,
    #[arg(long)]
    skopeo: PathBuf,
}

fn main() -> Result<(), Box<dyn Error>> {
    let args = Args::parse();
    let store = Store::new(StoreConfig::new(args.store)?);
    let reference = ImageSelector::new(&args.reference)?;
    let resolved = store
        .resolve(&reference)?
        .ok_or_else(|| format!("Published reference {} is missing", args.reference))?;
    let resolved = ImageSelector::new(resolved)?;
    let digest = resolved
        .digest()
        .ok_or("Resolved reference lacks a digest")?;
    let expected = format!("Published {} {digest}\n", args.reference);
    if args.publication != expected {
        return Err(format!("Expected {expected:?}, got {:?}", args.publication).into());
    }

    let report = store.check(&CheckScope::Image(reference))?;
    if report.has_errors() {
        return Err(format!("CAS check failed for {}: {report:#?}", args.reference).into());
    }

    let destination = ImageSelector::new(&args.restored_tag)?;
    let context = TransferContext {
        podman: args.podman,
        skopeo: args.skopeo,
        ..TransferContext::default()
    };
    let status = Command::new(&context.podman)
        .args(["image", "exists", "--", destination.as_str()])
        .status()?;
    match status.code() {
        Some(1) => {}
        Some(0) => return Err(format!("Podman tag already exists: {destination}").into()),
        _ => return Err(format!("Cannot check Podman tag {destination}: {status}").into()),
    }
    let exported = store.export(&resolved, Some(&destination), &context)?;
    if exported.local_ref.as_str() != args.reference
        || &exported.stored_manifest != digest
        || exported.destination != args.restored_tag
    {
        return Err(format!("Unexpected export report: {exported:?}").into());
    }
    Ok(())
}
