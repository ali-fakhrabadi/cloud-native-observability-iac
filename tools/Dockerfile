# Linters and IaC tooling in one reproducible image, so `make lint` behaves the same on
# every machine and in CI. Dependencies are hash-pinned (tools/requirements.txt).
ARG PYTHON_IMAGE=python:3.12.15-slim-trixie
FROM ${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Optional PyPI mirror for restricted networks. Hash pinning means a mirror cannot
# substitute different files.
ARG PIP_INDEX_URL=""
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --require-hashes ${PIP_INDEX_URL:+--index-url "$PIP_INDEX_URL"} \
        -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

ARG TOOLS_UID=1000
RUN useradd --create-home --uid "${TOOLS_UID}" tools
USER tools
WORKDIR /work
