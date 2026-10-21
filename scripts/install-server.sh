#!/usr/bin/env bash
# Copyright 2026 David Rolfe
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Turns a fresh Ubuntu 24.04 Google Compute Engine VM into a complete demo
# server: Grafana with the BigQuery plugin and the FAA dashboards, and this
# repository with the data loaded into BigQuery. The VM's service account is
# used throughout, so it needs the BigQuery Job User and BigQuery Data Editor
# roles. Used by gcp/create-vm.sh; run as root from a clone of the repository:
#
#   sudo GRAFANA_PASSWORD=secret scripts/install-server.sh [FROM_YYYY-MM TO_YYYY-MM]
#
# FROM/TO (default 2016-01 to last month) is the range of flights to load; pass
# "none" to skip loading. Settings, as environment variables:
#   GRAFANA_PASSWORD   password for Grafana's admin user (required)
#   APP_USER           owner of the repository and runner of the load (default:
#                      the owner of the repository directory)
#   BIGQUERY_PROJECT   project for the dataset (default: the VM's project)
#   BIGQUERY_DATASET   dataset (default faa)
#   BIGQUERY_LOCATION  where the dataset lives (default US)
# Grafana listens on port 3000. Safe to re-run.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "${GRAFANA_PASSWORD:-}" ]] || { echo "error: set GRAFANA_PASSWORD" >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_USER="${APP_USER:-$(stat -c %U "$REPO")}"
FROM="${1:-2016-01}"
TO="${2:-$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)}"
PROJECT="${BIGQUERY_PROJECT:-$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)}"
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "=== $(date '+%H:%M:%S') $*"; }

# apt-get, but a stalled mirror download can't hang it for good: each attempt
# gets ten minutes (normally seconds) before it is killed and tried again.
apt_get() {
  local attempt
  for attempt in 1 2 3; do
    timeout -k 30 600 apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 "$@" && return
    echo "apt-get $* failed or timed out (attempt $attempt)" >&2
    dpkg --configure -a || true
  done
  return 1
}

step "Packages"
apt_get update -q
apt_get install -y -q curl gnupg git unzip python3 openjdk-21-jdk-headless maven
# The bq CLI, from the Google Cloud SDK (not on every image).
if ! command -v bq > /dev/null; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  apt_get update -q
  apt_get install -y -q google-cloud-cli
fi

step "Grafana"
if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/grafana.gpg
  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt_get update -q
fi
apt_get install -y -q grafana
# grafana cli runs as root here, so the plugin it installs must be handed to
# the grafana user.
grafana cli plugins install grafana-bigquery-datasource
chown -R grafana:grafana /var/lib/grafana/plugins
systemctl enable grafana-server
systemctl restart grafana-server
for _ in $(seq 60); do curl -fs http://localhost:3000/api/health > /dev/null && break; sleep 1; done
grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
  admin reset-admin-password "$GRAFANA_PASSWORD" > /dev/null
echo "Grafana admin password set"

step "Repository"
PROPS="$REPO/bigquery.properties"
cat > "$PROPS" <<EOF
bigquery.project=$PROJECT
bigquery.dataset=${BIGQUERY_DATASET:-faa}
bigquery.location=${BIGQUERY_LOCATION:-US}
grafana.ssh=local
grafana.bigquery.auth=gce
EOF
chown "$APP_USER" "$PROPS"
chmod 600 "$PROPS"
as_app() { sudo -u "$APP_USER" -H bash -c "cd '$REPO' && $*"; }
as_app scripts/create-database.sh > /dev/null
as_app 'mvn -q -B package -DskipTests'
# FAA datasource and dashboards; grafana-provision.sh runs as root here, so its
# sudo calls need no password.
(cd "$REPO" && scripts/grafana-provision.sh)

if [[ "$FROM" != none ]]; then
  step "Loading flights $FROM to $TO (see scripts/reproduce.sh)"
  as_app "scripts/reproduce.sh --time 'install-server.sh on $(hostname)' $FROM $TO"
fi

step "Done"
echo "Grafana: port 3000, user admin. Dashboards: FAA folder."
