#!/bin/bash
# Installs or updates the Streetnav server inside the Debian 13 container (run as root, from the
# directory holding this repo's server/ folder). Idempotent. Secrets live in /etc/streetnav/streetnav.env.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
APP=/opt/streetnav
ENV_FILE=/etc/streetnav/streetnav.env

id streetnav >/dev/null 2>&1 || useradd --system --home "$APP" --shell /usr/sbin/nologin streetnav
install -d -o root -g root -m 755 "$APP"
install -d -o root -g streetnav -m 750 /etc/streetnav
install -d -o postgres -g postgres -m 750 /var/backups/streetnav

# PostgreSQL sized for a 2 GB container, local connections only
cp "$SRC/deploy/postgresql-streetnav.conf" /etc/postgresql/17/main/conf.d/streetnav.conf
systemctl restart postgresql

# Secrets: generated once, never overwritten
if [ ! -f "$ENV_FILE" ]; then
  db_password="$(openssl rand -hex 24)"
  {
    echo "STREETNAV_DATABASE_URL=postgresql://streetnav:${db_password}@127.0.0.1:5432/streetnav"
    echo "STREETNAV_API_TOKEN=$(openssl rand -hex 32)"
    echo "RWGPS_API_KEY="
    echo "RWGPS_AUTH_TOKEN="
  } > "$ENV_FILE"
  chown root:streetnav "$ENV_FILE"; chmod 640 "$ENV_FILE"
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'streetnav') THEN
    CREATE ROLE streetnav LOGIN PASSWORD '${db_password}';
  END IF;
END \$\$;
SQL
  runuser -u postgres -- psql -q -tc "SELECT 1 FROM pg_database WHERE datname = 'streetnav'" | grep -q 1 \
    || runuser -u postgres -- createdb -O streetnav -E UTF8 -T template0 --locale=C.UTF-8 streetnav
fi
runuser -u postgres -- psql -q -d streetnav -c "CREATE EXTENSION IF NOT EXISTS postgis"
for f in "$SRC"/sql/*.sql; do
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d streetnav < "$f"  # read by root: postgres cannot open /root
done
runuser -u postgres -- psql -q -d streetnav -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO streetnav; GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO streetnav"

# Application code and its virtualenv
rm -rf "$APP/streetnav_server"
cp -r "$SRC/streetnav_server" "$APP/"
[ -d "$APP/venv" ] || python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install -q --upgrade pip
"$APP/venv/bin/pip" install -q -r "$SRC/requirements.txt"

install -m 755 "$SRC/deploy/streetnav-backup" /usr/local/bin/streetnav-backup
cp "$SRC"/deploy/*.service "$SRC"/deploy/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now streetnav-api.service streetnav-backup.timer
systemctl restart streetnav-api.service
if grep -q '^RWGPS_AUTH_TOKEN=.\+' "$ENV_FILE"; then
  systemctl enable --now streetnav-rwgps.timer
else
  echo "RWGPS_API_KEY / RWGPS_AUTH_TOKEN empty in $ENV_FILE: Ride with GPS import not scheduled yet"
fi
echo "Streetnav installed."
