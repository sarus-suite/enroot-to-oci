#!/usr/bin/env bash
set -euo pipefail

id
podman version
podman info --format 'Podman storage uses {{.Store.GraphDriverName}} at {{.Store.GraphRoot}}. Rootless networking uses {{.Host.RootlessNetworkCmd}}.'
