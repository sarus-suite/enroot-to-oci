#!/usr/bin/env bash
set -euo pipefail

id
podman version
podman info --format 'Podman storage uses {{.Store.GraphDriverName}} at {{.Store.GraphRoot}}. Rootless networking uses {{.Host.RootlessNetworkCmd}}.'
skopeo --version
copy_help=$(skopeo copy --help)
for option in --dest-shared-blob-dir --src-shared-blob-dir --preserve-digests; do
    if ! grep -Eq -- "(^|[[:space:]])$option([[:space:]]|$)" <<< "$copy_help"; then
        printf 'Skopeo copy is missing %s\n' "$option" >&2
        exit 1
    fi
done
