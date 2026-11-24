FROM mcr.microsoft.com/devcontainers/base:debian13

ARG SLURM_VERSION=26.5.4

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates bats acl \
        bzip2 tar curl pkg-config util-linux squashfs-tools jq acl attr \
        podman uidmap passt crun iptables fuse-overlayfs \
    && rm -rf /var/lib/apt/lists/*

COPY containers.conf /etc/containers/containers.conf
RUN printf 'unqualified-search-registries = ["docker.io"]\n' \
        > /etc/containers/registries.conf \
    && printf '[storage]\ndriver = "overlay"\n' > /etc/containers/storage.conf

# The outer rootless container maps IDs through 65536 and reserves 1000 for vscode.
RUN printf 'vscode:1001:64536\n' > /etc/subuid \
    && printf 'vscode:1001:64536\n' > /etc/subgid

ENV CARGO_HOME=/home/vscode/.cargo \
    RUSTUP_HOME=/home/vscode/.rustup \
    PATH=/home/vscode/.cargo/bin:${PATH}

USER vscode
ARG RUST_TOOLCHAIN=stable
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/integration-rustup.sh \
    && sh /tmp/integration-rustup.sh -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN" \
    && rm /tmp/integration-rustup.sh \
    && rustup component add rustfmt clippy

CMD ["sleep", "infinity"]
