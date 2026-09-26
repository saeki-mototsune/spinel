# syntax=docker/dockerfile:1

# The environment spinel runs in: the compiler, spin and the tools, plus the
# C toolchain a compiled program needs, on Ubuntu 24.04 -- the same toolchain
# CI's ubuntu-latest/gcc lane builds and tests with (gcc 13, glibc 2.39,
# OpenSSL 3.0). Published by .github/workflows/docker.yml on every push to
# master as ghcr.io/<owner>/spinel (the tags are listed there).
#
#   docker run --rm -v "$PWD:/work" ghcr.io/<owner>/spinel spinel app.rb
#   docker run --rm -v "$PWD:/work" ghcr.io/<owner>/spinel spin build
#   docker run --rm -it -v "$PWD:/work" ghcr.io/<owner>/spinel   # a shell
#
# The context carries no .git (.dockerignore), so the release and revision
# `spinel --version` prints come in as build args and reach the Makefile
# through .spinel-dist, exactly as a `make dist` source archive carries them.
# The workflow passes what the Makefile's own stamp rule computed; a bare
# `docker build .` says "spinel unreleased (unknown)".
#
#   docker build --build-arg SPINEL_RELEASE=2026.09.12+5 \
#                --build-arg SPINEL_BUILD_REV=$(git rev-parse --short HEAD) .

ARG BASE_IMAGE=ubuntu:24.04

# ---- build ------------------------------------------------------------------
FROM ${BASE_IMAGE} AS build
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gcc libc6-dev make \
      libcrypt-dev libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# The vendored parsers (prism, rbs) on a layer of their own: `make deps` reads
# nothing but the Makefile, so the download is redone only when it changes.
COPY Makefile common.mk ./
RUN make deps

COPY . .

ARG SPINEL_RELEASE=unreleased
ARG SPINEL_BUILD_REV=unknown
RUN printf '%s\n%s\n' "$SPINEL_BUILD_REV" "$SPINEL_RELEASE" > .spinel-dist \
 && make -j"$(nproc)" all \
 && make install PREFIX=/usr/local

# ---- runtime ----------------------------------------------------------------
FROM ${BASE_IMAGE}
ARG DEBIAN_FRONTEND=noninteractive
# What a compiled program needs: cc and the libc headers to build, libcrypt
# (every program links -lcrypt, for String#crypt), libssl and libz for the
# openssl and zlib packages. git fetches the spin package index and `spin add
# --git`; patch and make serve a package's own `[[build]]`. CRuby is not
# included: the compiler never needs it, only `spin test --regen` and
# `spinel diff` do (they compare against it).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates gcc libc6-dev make git patch \
      libcrypt-dev libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# The installed tree as `make install` lays it out: everything under
# lib/spinel (the compiler finds its runtime and packages beside itself), the
# spinel-* tools as files and the two entry points as the same symlinks.
COPY --from=build /usr/local/lib/spinel /usr/local/lib/spinel
COPY --from=build /usr/local/bin/spinel-* /usr/local/bin/
RUN ln -s /usr/local/lib/spinel/spinel /usr/local/bin/spinel \
 && ln -s /usr/local/lib/spinel/spin   /usr/local/bin/spin

# The toolchain compiles and runs a program from this image, not just from
# the build stage: a header or library missing here would fail every user.
RUN spinel --version && spin --version \
 && printf 'puts "spinel ok: #{[1, 2, 3].sum}"\n' > /tmp/smoke.rb \
 && spinel -E /tmp/smoke.rb \
 && rm -f /tmp/smoke.rb

WORKDIR /work
CMD ["bash"]
