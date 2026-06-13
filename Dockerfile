# Thin multi-arch wrapper around ProcessOne's official ejabberd image.
# ejabberd/ecs is amd64-only; ghcr.io/processone/ejabberd supports linux/amd64 and linux/arm64.
FROM ghcr.io/processone/ejabberd:latest

LABEL org.opencontainers.image.title="ejabberd-orbstack"
LABEL org.opencontainers.image.description="Multi-arch ejabberd image for OrbStack/Apple Silicon"
LABEL org.opencontainers.image.source="https://github.com/JovanHsu/ejabberd-orbstack-builder"
