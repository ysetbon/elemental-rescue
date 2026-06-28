# =============================================================================
#  Dockerfile — containerizes the Elemental Rescue multiplayer relay (server.js)
# =============================================================================
#
#  WHAT THIS DOES, IN ONE SENTENCE:
#  It bakes "a Linux machine with Node.js + our relay code + its one dependency"
#  into a single portable image, so the relay runs identically on your laptop,
#  a teammate's laptop, or any cloud server — no "works on my machine" surprises.
#
#  This file is a RECIPE. Each instruction below adds one read-only "layer" to
#  the image. Docker caches layers, so ordering them cheap→expensive (and
#  rarely-changing→often-changing) makes rebuilds fast. We exploit that below.
#
#  Mental model:
#    Dockerfile  = the recipe          (this file)
#    image       = the baked cake      (`docker build` produces it)
#    container   = a slice being eaten (`docker run` starts one from the image)
#
#  Build it:   docker build -t elemental-relay .
#  Run it:     docker run --rm -p 8910:8910 elemental-relay
#  Then open:  http://localhost:8910   → "elemental-rescue relay: ok"
# -----------------------------------------------------------------------------

# ---- 1. Base image ----------------------------------------------------------
# Every image starts FROM another image. We don't build Linux + Node from
# scratch; we stand on an official, pre-built one.
#
#   node      → the official Node.js image (Node + npm already installed)
#   20        → Node major version. package.json says "node >=18"; 20 is a safe LTS.
#   -alpine   → built on Alpine Linux, a tiny (~5 MB) distro. The full image is
#               ~50 MB instead of ~1 GB. Smaller = faster pulls, smaller attack
#               surface. (Trade-off: Alpine uses musl libc, not glibc — fine here
#               because `ws` is pure JS with no native build step.)
#
# TIP: pin a digest (node:20-alpine@sha256:...) in real production for fully
# reproducible builds. A bare tag like "20-alpine" can change over time.
FROM node:20-alpine

# ---- 2. Working directory ---------------------------------------------------
# Sets the "current folder" inside the image for every command after this, and
# is where the container starts. Docker creates it if it doesn't exist.
WORKDIR /app

# ---- 3. Dependencies FIRST (the layer-cache trick) --------------------------
# Why copy ONLY package files before the rest of the source? Layer caching.
#
# Docker caches each layer and reuses it on the next build *unless its inputs
# changed*. `npm ci` (install) is the slow step. If we copied all our code
# first, then ANY one-character edit to server.js would invalidate the cache and
# force a full reinstall every build.
#
# By copying just package.json + package-lock.json first, the expensive install
# layer is only rebuilt when your DEPENDENCIES actually change — editing
# server.js reuses the cached node_modules instantly.
COPY package.json package-lock.json ./

# `npm ci` ("clean install") installs the EXACT versions from package-lock.json —
# reproducible, unlike `npm install` which may resolve newer versions.
#   --omit=dev          → skip devDependencies (we have none, but it's the habit;
#                         it keeps prod images lean and is what render.yaml uses)
#   && npm cache clean  → drop npm's download cache so it doesn't bloat the layer
RUN npm ci --omit=dev && npm cache clean --force

# ---- 4. Now the application code -------------------------------------------
# Copy the rest of the build context (everything not excluded by .dockerignore).
# This layer changes whenever you edit code — but step 3's install layer above
# stays cached, so rebuilds are fast.
COPY . .

# ---- 5. Run as a non-root user (security) -----------------------------------
# The node:* images ship a ready-made unprivileged user named "node". By default
# containers run as root; if the process is ever exploited, root-in-container is
# a bigger blast radius. Dropping to "node" is a cheap, standard hardening step.
USER node

# ---- 6. Document the port (and configuration) -------------------------------
# server.js listens on process.env.PORT (default 8910). EXPOSE is DOCUMENTATION —
# it records "this container serves on 8910" but does NOT publish the port. You
# still publish it at run time with `-p 8910:8910` (host:container).
ENV PORT=8910
EXPOSE 8910

# ---- 7. Healthcheck (optional but instructive) ------------------------------
# Docker periodically runs this command inside the container; if it fails, the
# container is marked "unhealthy" (orchestrators like Compose/Kubernetes can act
# on that). We hit the plain HTTP endpoint server.js answers for Render's probe.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/ || exit 1

# ---- 8. The start command ---------------------------------------------------
# CMD is the default process the container runs. "exec form" (JSON array) means
# node becomes PID 1 directly and receives signals (Ctrl-C / `docker stop`)
# cleanly — unlike the shell form, which wraps it in /bin/sh and can swallow them.
CMD ["node", "server.js"]
