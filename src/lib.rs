use hpc_image_store::{StoreConfig, TransferContext};
use raster::config::VarExpand;
use std::path::{Path, PathBuf};

pub fn load_transfer_settings(
    store_override: Option<&Path>,
) -> Result<(StoreConfig, TransferContext), String> {
    let config = raster::load_config_xdg(VarExpand::Must, &None)
        .map_err(|error| format!("Cannot load Sarus configuration: {error}"))?;

    let store_path = match store_override {
        Some(path) => path.to_path_buf(),
        None if config.hpc_image_store.is_empty() => {
            return Err(
                "Set hpc_image_store in the Sarus configuration or supply --store PATH".into(),
            );
        }
        None => PathBuf::from(config.hpc_image_store),
    };

    let store = StoreConfig::new(store_path).map_err(|error| error.to_string())?;
    let context = TransferContext {
        podman: config.podman_path.into(),
        skopeo: config.skopeo_path.into(),
        ..TransferContext::default()
    };
    Ok((store, context))
}
