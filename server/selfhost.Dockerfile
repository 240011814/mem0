# ============================================================
# Self-Hosted All-in-One Dockerfile
# Bundles: PostgreSQL 16 + Python API + Next.js Dashboard
# Managed by supervisord
# ============================================================

# ---- Stage 1: Build Next.js Dashboard ----
FROM node:20-alpine AS dashboard-builder

WORKDIR /app

# Install dependencies
COPY server/dashboard/package.json server/dashboard/yarn.lock* server/dashboard/package-lock.json* server/dashboard/pnpm-lock.yaml* ./
RUN \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile --network-timeout 600000; \
  elif [ -f package-lock.json ]; then npm ci; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && corepack prepare pnpm@10 --activate && pnpm i --frozen-lockfile; \
  else npm install; \
  fi

# Build
COPY server/dashboard/ .
ENV NEXT_TELEMETRY_DISABLED=1
ENV NEXT_PUBLIC_API_URL=NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_INSTANCE_NAME=NEXT_PUBLIC_INSTANCE_NAME
RUN npm run build

# ---- Stage 2: Final all-in-one image ----
FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies: PostgreSQL 16, Node.js 20, supervisor, tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg \
        supervisor \
        postgresql-16 postgresql-client-16 \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Poetry
RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH="/root/.local/bin:$PATH"

WORKDIR /app

# ---- Install Python dependencies (cached layer) ----
COPY server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- Install mem0 package ----
WORKDIR /app/packages
COPY pyproject.toml .
COPY poetry.lock .
COPY README.md .
COPY mem0 ./mem0
RUN pip install -e .[graph]

# ---- Copy server code ----
WORKDIR /app
COPY server/main.py server/auth.py server/db.py server/errors.py \
     server/models.py server/rate_limit.py server/schemas.py \
     server/server_state.py server/telemetry.py \
     server/alembic.ini ./
COPY server/alembic ./alembic
COPY server/init-db.sh ./init-db.sh
RUN chmod +x ./init-db.sh

# ---- Copy dashboard build output ----
COPY --from=dashboard-builder /app/.next/standalone ./dashboard/
COPY --from=dashboard-builder /app/.next/static ./dashboard/.next/static
COPY --from=dashboard-builder /app/public ./dashboard/public

# ---- Configuration files ----
COPY server/supervisord.conf /etc/supervisor/supervisord.conf
COPY server/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ---- PostgreSQL setup ----
RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql \
    && mkdir -p /var/log/supervisor

# ---- Environment defaults ----
ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=postgres
ENV POSTGRES_DB=postgres
ENV POSTGRES_HOST=127.0.0.1
ENV POSTGRES_PORT=5432
ENV POSTGRES_COLLECTION_NAME=mem0
ENV APP_DB_NAME=mem0_app
ENV JWT_SECRET=change-me-in-production
ENV AUTH_DISABLED=false
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=""
ENV NEXT_PUBLIC_API_URL=http://localhost:8000
ENV NEXT_PUBLIC_INSTANCE_NAME=Mem0
ENV DASHBOARD_URL=http://localhost:3000
ENV MEM0_TELEMETRY=false

# ---- Expose ports ----
# 8000 = API, 3000 = Dashboard, 5432 = PostgreSQL
EXPOSE 8000 3000 5432

# ---- Volumes ----
VOLUME ["/var/lib/postgresql/data"]

ENTRYPOINT ["/entrypoint.sh"]
