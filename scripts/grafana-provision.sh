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

# Configures a Grafana server over SSH: a Linux package install (/etc/grafana,
# /var/lib/grafana, systemd service grafana-server) with the
# grafana-bigquery-datasource plugin, reached with key login and passwordless sudo.
# grafana.ssh=local configures a Grafana on this machine instead, without SSH.
#   - installs the BigQuery datasource and dashboard provider from grafana/provisioning/
#   - copies grafana/dashboards/*.json to the dashboard folder Grafana watches
#   - with a service-account key, gives Grafana its private key in a file only
#     root and Grafana can read
#   - restarts Grafana and reports provisioning errors from its log
# Safe to re-run; re-run after adding or changing dashboards.
#
# Settings: bigquery.* and grafana.* in bigquery.properties (see
# bigquery.properties.example), or the environment variables below.
#
#   scripts/grafana-provision.sh
#   GRAFANA_SSH=me@grafana-host scripts/grafana-provision.sh
#   GRAFANA_SSH=local scripts/grafana-provision.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

GRAFANA_SSH="${GRAFANA_SSH:-$(prop grafana.ssh)}"
[[ -n "$GRAFANA_SSH" ]] || { echo "error: set grafana.ssh=user@host in bigquery.properties, or GRAFANA_SSH" >&2; exit 1; }
GRAFANA_URL="${GRAFANA_URL:-$(prop grafana.url)}"
GRAFANA_HOST=${GRAFANA_SSH#*@}; [[ "$GRAFANA_SSH" != local ]] || GRAFANA_HOST=localhost
GRAFANA_URL="${GRAFANA_URL:-http://$GRAFANA_HOST:3000}"
GRAFANA_PORT=$(sed -E 's#^[a-z]+://[^/:]+:?([0-9]*).*#\1#' <<< "$GRAFANA_URL"); GRAFANA_PORT="${GRAFANA_PORT:-3000}"
[[ -n "$BQ_PROJECT" ]] || { echo "error: set bigquery.project in bigquery.properties, or BIGQUERY_PROJECT" >&2; exit 1; }
# How Grafana logs in to BigQuery: with the key file, or as the VM's service account.
AUTH="${GRAFANA_BIGQUERY_AUTH:-$(prop grafana.bigquery.auth)}"
[[ -n "$AUTH" ]] || { [[ -n "$BQ_CREDENTIALS" ]] && AUTH=key || AUTH=gce; }
case "$AUTH" in
  key) [[ -f "$BQ_CREDENTIALS" ]] || { echo "error: grafana.bigquery.auth=key needs bigquery.credentials, a key file" >&2; exit 1; }
       CLIENT_EMAIL=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["client_email"])' "$BQ_CREDENTIALS") ;;
  gce) CLIENT_EMAIL="" ;;
  *)   echo "error: grafana.bigquery.auth must be key or gce, not $AUTH" >&2; exit 1 ;;
esac

PROV="$PROJECT_DIR/grafana/provisioning"

# remote COMMAND...: runs a shell command on the Grafana server, as ssh would.
if [[ "$GRAFANA_SSH" == local ]]; then
  remote() { bash -c "$*"; }
else
  remote() { ssh -o BatchMode=yes "$GRAFANA_SSH" "$@"; }
fi

echo "Installing provisioning files on $GRAFANA_SSH (BigQuery project $BQ_PROJECT, $AUTH login)"
if [[ "$AUTH" == key ]]; then
  # The private key travels over SSH stdin (never on a command line).
  python3 -I -c 'import json, sys; sys.stdout.write(json.load(open(sys.argv[1]))["private_key"])' "$BQ_CREDENTIALS" \
    | remote "sudo install -o root -g grafana -m 640 /dev/stdin /etc/grafana/faa-bigquery-key.pem"
  jwt_only='s/ *# jwt only$//'
else
  jwt_only='/# jwt only$/d'
fi
sed -e "s/__AUTH__/$([[ $AUTH == key ]] && echo jwt || echo gce)/" -e "s/__PROJECT__/$BQ_PROJECT/" \
    -e "s/__LOCATION__/$BQ_LOCATION/" -e "s/__CLIENT_EMAIL__/$CLIENT_EMAIL/" -e "$jwt_only" \
    "$PROV/datasources/bigquery.yaml" \
  | remote "sudo install -o root -g grafana -m 640 /dev/stdin /etc/grafana/provisioning/datasources/faa-bigquery.yaml"
remote "sudo install -o root -g grafana -m 640 /dev/stdin /etc/grafana/provisioning/dashboards/faa.yaml" \
  < "$PROV/dashboards/faa.yaml"

remote "sudo install -d -o grafana -g grafana -m 755 /var/lib/grafana/dashboards/faa"
for f in "$PROJECT_DIR"/grafana/dashboards/*.json; do
  [[ -f "$f" ]] || continue
  # The queries name the faa dataset; point them at BQ_DATASET.
  bq_sql "$(cat "$f")" \
    | remote "sudo install -o grafana -g grafana -m 644 /dev/stdin '/var/lib/grafana/dashboards/faa/$(basename "$f")'"
  echo "  dashboard $(basename "$f")"
done

echo "Restarting Grafana"
since=$(remote "date '+%Y-%m-%d %H:%M:%S'")
remote "sudo systemctl restart grafana-server"
for _ in $(seq 30); do
  remote "curl -fs http://localhost:$GRAFANA_PORT/api/health > /dev/null" && break
  sleep 2
done
remote "systemctl is-active grafana-server"

errors=$(remote "sudo journalctl -u grafana-server --since '$since' --no-pager" \
  | grep -E 'logger=provisioning[^ ]* .*level=(error|warn)' || true)
if [[ -n "$errors" ]]; then
  echo "Provisioning problems:" >&2
  echo "$errors" >&2
  exit 1
fi
echo "Grafana provisioned: datasource 'BigQuery FAA' (uid bigquery-faa). Dashboards:"
for f in "$PROJECT_DIR"/grafana/dashboards/*.json; do
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print("  %s: %s/d/%s" % (d["title"], sys.argv[2], d["uid"]))' "$f" "$GRAFANA_URL"
done
