.DEFAULT_GOAL := quality

PYTHON ?= python
IMAGE ?= simplynext-backend:local
SMOKE_HOST_PORT ?= 18000
SMOKE_NONDEFAULT_HOST_PORT ?= 18765
EVIDENCE_OUTPUT ?= release-evidence.json

.PHONY: quality package-smoke production-lock docker-build container-smoke \
	container-smoke-nondefault release-evidence

quality:
	SIMPLYNEXT_BEDROCK_ENABLED=false \
	SIMPLYNEXT_ANTHROPIC_ENABLED=false \
	SIMPLYNEXT_CAPTION_TEMPLATES_PATH=data/caption_templates.example.json \
	SIMPLYNEXT_LATTICE_VOCABULARY_VERSION=sgsl_demo_v1 \
	SIMPLYNEXT_RECOGNITION_LANGUAGE=asl \
	$(PYTHON) -m pytest
	$(PYTHON) -m ruff check src tests scripts
	SIMPLYNEXT_LATTICE_VOCABULARY_VERSION=sgsl_demo_v1 $(PYTHON) -m mypy src scripts
	$(PYTHON) -m pip check

package-smoke:
	$(PYTHON) scripts/package_smoke.py data/caption_templates.example.json

# Resolve this on Python 3.12 Linux. A missing or changed reviewed output fails
# unless the operator explicitly sets UPDATE_LINUX_LOCK=1 after reviewing it.
production-lock:
	scripts/resolve_linux_production_lock.sh docker/pylock.linux.toml

docker-build:
	docker build --pull -t $(IMAGE) .

container-smoke:
	scripts/container_smoke.sh $(IMAGE) $(SMOKE_HOST_PORT) 8000

container-smoke-nondefault:
	scripts/container_smoke.sh $(IMAGE) $(SMOKE_NONDEFAULT_HOST_PORT) 8765

release-evidence:
	scripts/release_evidence.sh $(IMAGE) $(EVIDENCE_OUTPUT)
