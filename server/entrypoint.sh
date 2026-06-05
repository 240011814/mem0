#!/bin/bash
set -e

# ---- Initialize PostgreSQL data directory (first run only) ----
if [ ! -f /var/lib/postgresql/data/PG_VERSION ]; then
    echo "Initializing PostgreSQL data directory..."
    mkdir -p /var/lib/postgresql/data
    chown -R postgres:postgres /var/lib/postgresql
    su - postgres -c "/usr/lib/postgresql/16/bin/initdb -D /var/lib/postgresql/data"

    # Enable password auth for local connections
    echo "local all all trust" > /var/lib/postgresql/data/pg_hba.conf
    echo "host all all 127.0.0.1/32 md5" >> /var/lib/postgresql/data/pg_hba.conf
    echo "host all all ::1/128 md5" >> /var/lib/postgresql/data/pg_hba.conf
fi

# ---- Start PostgreSQL for initialization ----
echo "Starting PostgreSQL for initialization..."
su - postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/data -w start"

# Wait for PostgreSQL to be ready
until pg_isready -h 127.0.0.1 -U postgres -q; do
    sleep 1
done

# ---- Create database and user ----
export POSTGRES_USER="${POSTGRES_USER:-postgres}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-postgres}"

# Set password for postgres user
psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
    ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';
EOSQL

# Run init-db.sh if it exists (creates mem0_app database)
if [ -f /app/init-db.sh ]; then
    echo "Running init-db.sh..."
    bash /app/init-db.sh
fi

# ---- Run Alembic migrations ----
echo "Running Alembic migrations..."
cd /app
alembic upgrade head

# ---- Stop PostgreSQL (supervisord will restart it) ----
echo "Stopping temporary PostgreSQL..."
su - postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/data -w stop"

# ---- Replace dashboard NEXT_PUBLIC_* placeholders ----
if [ -d /app/dashboard/.next ]; then
    cd /app/dashboard
    printenv | grep '^NEXT_PUBLIC_' | while IFS='=' read -r key value; do
        escaped=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')
        find .next/ -type f -exec sed -i "s|$key|$escaped|g" {} \;
    done
    echo "Done replacing NEXT_PUBLIC_* placeholders in dashboard"
fi

# ---- Start supervisord ----
echo "Starting all services..."
exec supervisord -c /etc/supervisor/supervisord.conf
