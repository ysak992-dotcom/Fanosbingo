# Functions service: auth, and the operations RLS cannot express.
#
# Built for arm64 to match the Graviton (t4g.small) instance. An x86 image
# pushes happily and then fails at runtime with "exec format error".
#
# BUILD CONTEXT IS THE REPOSITORY ROOT, so the RDS CA bundle in docker/ is
# shared rather than duplicated:
#   podman build -f services/functions/Dockerfile .

# --platform=$BUILDPLATFORM: install NATIVELY, do not emulate.
#
# This stage used to inherit the target platform, so `npm install` ran as arm64
# under QEMU on an x86 runner. On 2026-07-30 that killed a deploy outright:
#
#   #11 [deps 4/4] RUN npm install --omit=dev --no-audit --no-fund
#   #11 13.82 qemu: uncaught target signal 4 (Illegal instruction) - core dumped
#
# and the build then sat wedged for thirteen minutes rather than failing, so it
# read as a slow build rather than a broken one. Node under QEMU hits illegal
# instructions intermittently; earlier builds of this image got away with it.
#
# Emulating it was never necessary. EVERY dependency here is pure JavaScript --
# express, jsonwebtoken, pg, @aws-sdk/client-kms, viem -- so node_modules has no
# architecture. Installing on the builder's own architecture and copying the
# result into the arm64 stage is both correct and several minutes faster, because
# nothing is emulated.
#
# THE ASSUMPTION IS CHECKED BELOW, not just asserted. If someone adds a
# dependency with a native addon, cross-installing would place an x86 binary in
# an arm64 image and fail at runtime with an unhelpful error. The guard turns
# that into a build failure with an explanation.
FROM --platform=$BUILDPLATFORM docker.io/library/node:22-alpine AS deps

WORKDIR /app

# Manifests only, so a source-only change reuses the cached dependency layer.
COPY services/functions/package.json services/functions/package-lock.json* ./

# `npm ci` rather than `npm install`: it installs exactly the lockfile, and fails
# if the lockfile and package.json disagree, instead of quietly resolving to
# something the lockfile never described. The ticker already did this.
RUN npm ci --omit=dev --no-audit --no-fund

# The guard for the cross-install above. A compiled addon is a .node file.
RUN if find node_modules -name '*.node' -print -quit 2>/dev/null | grep -q .; then \
      echo "FATAL: a dependency ships a native addon (.node):" >&2; \
      find node_modules -name '*.node' >&2; \
      echo "This stage installs on the BUILD architecture, so that binary would" >&2; \
      echo "be the wrong one for the arm64 runtime image. Either drop the" >&2; \
      echo "dependency or remove --platform=\$BUILDPLATFORM and accept QEMU." >&2; \
      exit 1; \
    fi

# ---------------------------------------------------------------------------

FROM docker.io/library/node:22-alpine

# dumb-init so PID 1 forwards signals. Without it Node never receives SIGTERM on
# task replacement, never drains, and in-flight requests are cut mid-transaction.
RUN apk add --no-cache dumb-init

# Amazon's RDS CA bundle. RDS presents a certificate signed by a CA that is not
# in Node's default trust store, so an unconfigured connection dies with
# "self-signed certificate in certificate chain". Baking the published bundle in
# lets us verify properly instead of reaching for rejectUnauthorized:false,
# which encrypts while verifying nothing.
COPY docker/rds-global-bundle.pem /opt/rds-global-bundle.pem
ENV PGSSLROOTCERT=/opt/rds-global-bundle.pem

# NO PACKAGE MANAGER IN THE RUNTIME IMAGE.
#
# node:22-alpine bundles npm, and npm bundles its own copy of tar. On
# 2026-08-14 that copy is 7.5.11, carrying CVE-2026-59873 (CRITICAL, fixed in
# 7.5.19) -- a denial of service through a crafted gzip bomb during extraction.
# Found by pointing the deploy workflow's new image scan at this base, which is
# the whole reason that scan exists: nothing in this repository changed, and
# nothing in this repository could have noticed.
#
# SUPPRESSING IT IN .trivyignore WAS THE OBVIOUS MOVE AND IS THE WRONG ONE. The
# finding is real; what makes it harmless here is that nothing at runtime
# extracts a tarball, because nothing at runtime runs npm. The CMD is
# `node src/index.js`. So the honest fix is to make that true structurally
# rather than to assert it in an ignore file that nobody rereads.
#
# Deleting npm also removes a package manager from a container that terminates
# requests from the internet, which is worth doing on its own -- an attacker who
# reaches code execution here no longer has an installer waiting for them.
#
# Dependencies are already present: they are COPIED from the deps stage above,
# which is where npm ci runs. Nothing below this line needs npm to exist.
# yarn and corepack go too. They carry no CRITICAL finding today, but leaving
# them would make the heading above false, and a comment that overstates what the
# code does is the failure mode this repository keeps finding.
RUN rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm \
           /usr/local/bin/npx \
           /usr/local/bin/corepack \
           /usr/local/bin/yarn \
           /usr/local/bin/yarnpkg \
           /opt/yarn-v* \
 && ! command -v npm \
 && ! command -v yarn \
 && ! command -v corepack

ENV NODE_ENV=production
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY services/functions/package.json ./
COPY services/functions/src ./src

# Run unprivileged. The node image ships a `node` user for exactly this.
USER node

EXPOSE 8080

# No HEALTHCHECK here. A container health check whose binary is missing reports
# UNKNOWN forever and hangs the ECS deployment at IN_PROGRESS -- which cost real
# time on postgrest. Caddy health-checks /healthz instead, which tests the path
# traffic actually takes.

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
