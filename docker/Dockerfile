# git-guard containerized QA toolchain.
#
# A small Debian-slim image carrying the full git-guard QA toolchain so the gate
# can run identically in CI, locally, or on a "naked" machine that lacks the
# tools. Build once, then run `bin/git-guard verify` (or the gate) against a
# repo MOUNTED at /work.
#
# Build:
#   docker build -t git-guard:local -f docker/Dockerfile .
#
# Self-test (runs the bundled verify against the image's own copy):
#   docker run --rm git-guard:local verify
#
# Run the gate against a mounted target repo:
#   docker run --rm -v "$PWD:/work" -w /work git-guard:local \
#       sh /opt/git-guard/hooks/common/qa_gate.sh
#
# Overlay a private rules dir (also mounted):
#   docker run --rm -v "$PWD:/work" -v "$RULES:/rules:ro" \
#       -e GIT_GUARD_RULES_DIR=/rules -w /work git-guard:local verify
#
# Pinned base for reproducibility; bump deliberately.
FROM debian:bookworm-slim

# Tool versions are pinned to "reasonable" floors; apt pins to the bookworm
# channel, the npm CLI is pinned exactly. uv installs ruff into a venv-free
# global location so `ruff` is on PATH.
ARG ASTGREP_VERSION=0.39.5
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/root/.local/bin:/usr/local/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1

# Core OS toolchain: git, a POSIX sh (dash is /bin/sh on Debian) + bash,
# shellcheck, jq, python3, ca-certs, curl (for uv), and nodejs/npm for the
# ast-grep CLI. --no-install-recommends keeps the image lean.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        bash \
        shellcheck \
        jq \
        python3 \
        nodejs \
        npm \
 && rm -rf /var/lib/apt/lists/*

# ruff via uv (fast, self-contained). uv installs to /root/.local/bin.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && /root/.local/bin/uv tool install "ruff" \
 && ln -sf /root/.local/share/uv/tools/ruff/bin/ruff /usr/local/bin/ruff || true

# ast-grep CLI (provides both `ast-grep` and `sg`). Pinned via npm.
RUN npm install -g "@ast-grep/cli@${ASTGREP_VERSION}" \
 && npm cache clean --force

# Ship git-guard itself inside the image at /opt/git-guard so the container is
# self-contained (can verify without a mounted repo). The build context is the
# repo root.
COPY . /opt/git-guard
ENV PATH=/opt/git-guard/bin:$PATH

# A scratch repo for git operations the gate may make; the gate is given a clean
# global git identity so its internal scratch commits never prompt.
RUN git config --global user.email "git-guard@localhost" \
 && git config --global user.name  "git-guard" \
 && git config --global commit.gpgsign false \
 && git config --global --add safe.directory '*'

WORKDIR /work

# Default: run the git-guard CLI. `docker run … git-guard:local verify` works
# because git-guard is on PATH; with no args it prints help.
ENTRYPOINT ["git-guard"]
CMD ["verify"]
