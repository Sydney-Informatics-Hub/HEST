# syntax=docker.io/docker/dockerfile:1.29@sha256:572cebbc2b15e6f84c077742952674889cb63cd5e9b80abdffcbe587b6f19183

ARG BASE_IMAGE=nvidia/cuda:12.9.0-base-ubuntu24.04@sha256:48e21b10467354655f5073c05eebdeaac9818c6b40d70f334f7ad2df000463d8
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.13.9@sha256:d3b601f0c7b118bc1753febf7c41cc80981df678445e0254284eecf84db79a7d
# most recent 3.11 patch release available in uv 0.13.9
ARG PYTHON_VERSION=3.11.18

# use as copy source only
FROM ${UV_IMAGE} AS uv

# ---------------------------------------------------------------------------
# Builder: uv-managed Python + locked venv. Build-only tools stay in this stage.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

# global ARGs must be re-declared to be visible inside a stage
ARG PYTHON_VERSION

# uv binaries for package management
COPY --from=uv /uv /uvx /bin/

# git + CA certs: uv needs the git CLI to fetch the TRIDENT git dependency.
# No libvips-dev/compiler here, so pyvips builds in ABI mode (loads libvips.so at runtime).
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Paths must be identical in builder and runtime: the venv stores absolute paths
# (bin/python symlinks into /opt/python). /opt is world-readable; /root is not.
ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_PYTHON=${PYTHON_VERSION} \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

RUN --mount=type=cache,target=/root/.cache/uv \
    uv python install ${PYTHON_VERSION}

WORKDIR /build

# 1) Dependencies only (big, rarely changes) -> cached layer independent of src/
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-editable --extra gpu

# 2) HEST itself, installed non-editable so the venv is self-contained
COPY pyproject.toml uv.lock ./
COPY src ./src
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable --extra gpu

# ---------------------------------------------------------------------------
# Runtime: CUDA base + runtime shared libs only.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

# Non-secret build metadata (safe as a build arg)
ARG VCS_REF=unknown

# libvips42t64: libvips for pyvips (ABI mode)
# libgl1, libglib2.0-0t64: required by opencv-python (pulled in by ultralytics)
# OpenSlide itself comes from the openslide-bin wheel in the venv.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libvips42t64 \
      libgl1 \
      libglib2.0-0t64 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/venv /opt/venv
COPY LICENSE.md /opt/hest/LICENSE.md

# Single writable cache root. Bind-mount scratch here at runtime, e.g.
#   singularity exec --nv --bind /scratch/<proj>/$USER/hest-cache:/cache hest.sif ...
# 1777 so it also works unmounted under plain `docker run` (container writable layer).
RUN mkdir -p /cache && chmod 1777 /cache

ENV PATH=/opt/venv/bin:${PATH} \
    PYTHONUNBUFFERED=1 \
    XDG_CACHE_HOME=/cache \
    HF_HOME=/cache/huggingface \
    TORCH_HOME=/cache/torch \
    YOLO_CONFIG_DIR=/cache/ultralytics \
    MPLCONFIGDIR=/cache/matplotlib \
    NUMBA_CACHE_DIR=/cache/numba \
    CUPY_CACHE_DIR=/cache/cupy

LABEL org.opencontainers.image.title="hest" \
      org.opencontainers.image.description="HEST-Library with RAPIDS/cuCIM (CUDA 12) for batch use" \
      org.opencontainers.image.source="https://github.com/Sydney-Informatics-Hub/HEST" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="CC-BY-NC-SA-4.0"

CMD ["python"]
