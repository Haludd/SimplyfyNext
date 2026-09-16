# syntax=docker/dockerfile:1.7
# The multi-platform index digest is pinned; update it only with a reviewed image
# refresh and a vulnerability scan. It currently resolves to Python 3.12 slim Trixie.
ARG PYTHON_IMAGE=python:3.12-slim-trixie@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

FROM ${PYTHON_IMAGE} AS patched-base
# Security updates published since the pinned official base. Retain the resolved
# OS inventory + image digest in release evidence; the scanner remains mandatory.
RUN apt-get update \
    && apt-get upgrade --yes --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

FROM patched-base AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH

WORKDIR /build
RUN python -m venv --copies /opt/venv

# Copy only files needed to build the normal wheel.  The final stage receives the
# installed distribution, never the checkout or this build toolchain.
COPY pyproject.toml README.md requirements.txt ./
COPY src ./src
COPY data ./data
COPY docker ./docker
COPY scripts/package_smoke.py /tmp/package_smoke.py
# Releases install the checked-in Linux AMD64 lock. Resolution is a separate,
# explicit update/review action; a missing lock must fail the image build.
RUN python -m pip install --no-cache-dir --upgrade pip==26.2.1 \
    && python -m pip install --no-cache-dir -r docker/pylock.linux.toml \
    && python -m pip install --no-cache-dir --no-deps . \
    && python -m pip check \
    && cd /tmp \
    && python /tmp/package_smoke.py /build/data/word_templates.example.json

# pip is only a build/install tool. Remove it from the copied venv so the final
# runtime does not carry pip's vendored packages or an unnecessary installer.
RUN python -m pip uninstall --yes pip setuptools

FROM patched-base AS runtime
ARG SOURCE_REVISION=unreviewed
LABEL org.opencontainers.image.revision=${SOURCE_REVISION}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    SIMPLYNEXT_ENVIRONMENT=production \
    SIMPLYNEXT_HOST=0.0.0.0 \
    SIMPLYNEXT_BEDROCK_ENABLED=false \
    SIMPLYNEXT_ANTHROPIC_ENABLED=false

WORKDIR /app
RUN groupadd --system --gid 10001 simplynext \
    && useradd --system --uid 10001 --gid simplynext --home-dir /app --no-create-home simplynext \
    && mkdir /app/spend \
    && chown simplynext:simplynext /app/spend \
    && rm -f /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.12 \
    && rm -rf /usr/local/lib/python3.12/site-packages/pip \
        /usr/local/lib/python3.12/site-packages/pip-*.dist-info

COPY --from=builder /opt/venv /opt/venv
COPY --chown=simplynext:simplynext data/word_templates.example.json /app/data/word_templates.example.json
COPY scripts/production_preflight.py /app/ops/production_preflight.py
COPY --chmod=755 docker/entrypoint.sh /app/ops/entrypoint.sh

EXPOSE 8000

# Railway remounts the persistent volume root-owned on every container start, so the
# container must still start as root. entrypoint.sh re-chowns the volume and then
# drops to the unprivileged simplynext user via setpriv before exec'ing the app;
# Railway injects PORT at runtime, which the application reads with precedence over
# SIMPLYNEXT_PORT, and always runs one Uvicorn worker.
ENTRYPOINT ["/app/ops/entrypoint.sh", "simplynext-api"]
