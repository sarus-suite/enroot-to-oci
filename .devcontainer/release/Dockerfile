FROM rust:1.100.0-slim-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends binutils git \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --shell /bin/bash vscode

USER vscode
