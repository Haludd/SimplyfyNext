# syntax=docker/dockerfile:1.7
# The multi-platform index digest is pinned; update it only with a reviewed image
# refresh and a vulnerability scan. It currently resolves to Python 3.12 slim Trixie.
ARG PYTHON_IMAGE=python:3.12-slim-trixie@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

FROM ${PYTHON_IMAGE} AS builder

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
COPY scripts/resolve_linux_production_lock.sh /tmp/resolve_linux_production_lock.sh

# Resolve on Linux so platform wheels are selected for the target image.  A
# reviewed docker/pylock.linux.toml is checked for reproducible releases; the
# ephemeral fallback keeps an initial clean clone buildable before that file exists.
RUN if [ -f docker/pylock.linux.toml ]; then \
      /tmp/resolve_linux_production_lock.sh docker/pylock.linux.toml \
      && python -m pip install --no-cache-dir -r docker/pylock.linux.toml; \
    else \
      UPDATE_LINUX_LOCK=1 /tmp/resolve_linux_production_lock.sh /tmp/pylock.linux.toml \
      && python -m pip install --no-cache-dir -r /tmp/pylock.linux.toml; \
    fi \
    && python -m pip install --no-cache-dir --no-deps . \
    && python -m pip check \
    && cd /tmp \
    && python /tmp/package_smoke.py /build/data/caption_templates.example.json

# pip is only a build/install tool. Remove it from the copied venv so the final
# runtime does not carry pip's vendored packages or an unnecessary installer.
RUN python -m pip uninstall --yes pip setuptools

FROM ${PYTHON_IMAGE} AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    SIMPLYNEXT_ENVIRONMENT=production \
    SIMPLYNEXT_HOST=0.0.0.0 \
    SIMPLYNEXT_BEDROCK_ENABLED=false \
    SIMPLYNEXT_ANTHROPIC_ENABLED=false \
    SIMPLYNEXT_CAPTION_TEMPLATES_PATH=/app/data/caption_templates.example.json

WORKDIR /app
RUN groupadd --system simplynext \
    && useradd --system --gid simplynext --home-dir /app --no-create-home simplynext \
    && rm -f /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.12 \
    && rm -rf /usr/local/lib/python3.12/site-packages/pip \
        /usr/local/lib/python3.12/site-packages/pip-*.dist-info

COPY --from=builder /opt/venv /opt/venv
COPY --chown=simplynext:simplynext data/caption_templates.example.json /app/data/caption_templates.example.json

USER simplynext
EXPOSE 8000

# Railway injects PORT at runtime.  The application reads it with precedence over
# SIMPLYNEXT_PORT and always runs one Uvicorn worker.
ENTRYPOINT ["simplynext-api"]
