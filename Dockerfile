# syntax=docker/dockerfile:1

# ============================================================
# wacrm — production image (Next.js 16 standalone output)
#
# Multi-stage build:
#   deps    → install node_modules from the lockfile only
#   builder → `next build` (emits .next/standalone)
#   runner  → minimal runtime: standalone server + static assets
#
# IMPORTANT — build-time public env:
#   NEXT_PUBLIC_* values are inlined into the client bundle at
#   `next build`, so they MUST be supplied as build args, not just at
#   runtime. The two Supabase public vars are read by the browser client
#   (src/lib/supabase/client.ts). Build with:
#
#     docker build \
#       --build-arg NEXT_PUBLIC_SUPABASE_URL=https://xxx.supabase.co \
#       --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key \
#       --build-arg NEXT_PUBLIC_SITE_URL=https://crm.example.com \
#       -t wacrm-app:latest .
#
# These are public values (they ship to the browser anyway) — the
# service-role key, ENCRYPTION_KEY, META_APP_SECRET, etc. stay OUT of the
# image and are injected only at runtime via env_file / compose.
# ============================================================

# node:22-alpine — LTS, satisfies package.json engines ">=20.0.0".
FROM node:22-alpine AS base
# libc6-compat: some prebuilt native binaries expect glibc symbols on Alpine.
RUN apk add --no-cache libc6-compat
WORKDIR /app

# ------------------------------------------------------------
# deps — install dependencies against the lockfile only, so this
# layer is cached until package.json / package-lock.json change.
# ------------------------------------------------------------
FROM base AS deps
COPY package.json package-lock.json ./
# Prefer the reproducible, lockfile-exact install. Fall back to `npm install`
# if the committed lockfile has drifted out of sync with package.json
# (e.g. optional native deps like @emnapi/* resolving to newer patches) so a
# stale lock doesn't hard-block the deploy.
RUN npm ci || npm install

# ------------------------------------------------------------
# builder — compile the app. Needs the NEXT_PUBLIC_* build args.
# ------------------------------------------------------------
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL

ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ------------------------------------------------------------
# runner — minimal production image.
# ------------------------------------------------------------
FROM base AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# Run as an unprivileged user.
RUN addgroup --system --gid 1001 nodejs \
 && adduser  --system --uid 1001 nextjs

# public/ and the static chunks are NOT bundled into standalone by Next —
# copy them alongside the traced server so server.js can serve them.
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

# server.js is the standalone entrypoint emitted by `next build`.
CMD ["node", "server.js"]
