# Linters and IaC tooling in one reproducible image, so `make lint` behaves the same on
# every machine and in CI. Dependencies are hash-pinned (tools/requirements.txt).
ARG PYTHON_IMAGE=python:3.12.15-slim-trixie
ARG DOCKER_CLI_IMAGE=docker:29.9.2-cli

# Molecule reaches its test containers with `docker exec`: only the CLI binary is needed.
FROM ${DOCKER_CLI_IMAGE} AS docker-cli

FROM ${PYTHON_IMAGE}
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# rsync: Molecule's Docker driver uses it to pass the build context of test images.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends rsync \
    && rm -rf /var/lib/apt/lists/*

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
