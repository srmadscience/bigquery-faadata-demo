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

# Builds the whole demo in a Google Cloud project: a service account that may
# use BigQuery, and a Compute Engine VM (Ubuntu 24.04) running as it, which
# clones this repository and runs scripts/install-server.sh: Grafana with the
# FAA dashboards, and the flights and weather from LOAD_FROM to LOAD_TO loaded
# into BigQuery. Only port 3000 (Grafana) is opened, to ALLOWED_CIDR; SSH goes
# through gcloud compute ssh. Follow the setup, about 10 to 20 minutes with the
# load, with:
#
#   gcloud compute ssh faa-demo --zone ZONE -- tail -f /var/log/faa-setup.log
#
#   gcp/create-vm.sh                                 create everything
#   ALLOWED_CIDR=$(curl -s https://checkip.amazonaws.com)/32 gcp/create-vm.sh
#   gcp/create-vm.sh --delete                        delete the VM and firewall rule
#
# Settings, as environment variables (defaults in brackets):
#   PROJECT           Google Cloud project [gcloud's current project]
#   ZONE              [us-central1-a]
#   NAME              VM, service account and firewall rule name [faa-demo]
#   MACHINE_TYPE      [e2-standard-4]; the VM runs Grafana and the loader only
#   ALLOWED_CIDR      addresses allowed to reach Grafana [0.0.0.0/0: set it!]
#   GRAFANA_PASSWORD  Grafana's admin password [hiredavid]
#   LOAD_FROM / LOAD_TO   months of flights to load [2016-01 / 2026-07];
#                     LOAD_FROM=none loads nothing
#   DATASET / LOCATION    BigQuery dataset and its location [faa / US]
#   REPO_URL / REPO_BRANCH  [https://github.com/srmadscience/bigquery-faadata-demo.git / main]
# Deleting the VM leaves the dataset; remove it with bq rm -r -f DATASET.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-a}"
NAME="${NAME:-faa-demo}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
ALLOWED_CIDR="${ALLOWED_CIDR:-0.0.0.0/0}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-hiredavid}"
LOAD_FROM="${LOAD_FROM:-2016-01}"
LOAD_TO="${LOAD_TO:-2026-07}"
DATASET="${DATASET:-faa}"
LOCATION="${LOCATION:-US}"
REPO_URL="${REPO_URL:-https://github.com/srmadscience/bigquery-faadata-demo.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
SA="$NAME@$PROJECT.iam.gserviceaccount.com"
[[ -n "$PROJECT" ]] || { echo "error: set PROJECT or gcloud config set project" >&2; exit 1; }
g() { gcloud --project "$PROJECT" --quiet "$@"; }

if [[ "${1:-}" == --delete ]]; then
  g compute instances delete "$NAME" --zone "$ZONE" || true
  g compute firewall-rules delete "$NAME-grafana" || true
  echo "Deleted the VM and firewall rule. The service account $SA and dataset $DATASET remain."
  exit 0
fi

echo "=== Enabling the Compute Engine, BigQuery and Cloud Resource Manager APIs"
# Grafana's BigQuery plugin calls Cloud Resource Manager to test the datasource.
g services enable compute.googleapis.com bigquery.googleapis.com cloudresourcemanager.googleapis.com

echo "=== Service account $SA"
g iam service-accounts describe "$SA" > /dev/null 2>&1 \
  || g iam service-accounts create "$NAME" --display-name "FAA demo: Grafana and loader"
# A new service account takes a few seconds to become visible to IAM; until then
# granting it a role fails with "does not exist", so retry for up to two minutes.
for role in roles/bigquery.jobUser roles/bigquery.dataEditor; do
  for attempt in $(seq 12); do
    err=$(g projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" --role "$role" \
      --condition None 2>&1 > /dev/null) && break
    (( attempt < 12 )) || { echo "$err" >&2; exit 1; }
    sleep 10
  done
done

echo "=== Firewall rule $NAME-grafana: port 3000 from $ALLOWED_CIDR"
g compute firewall-rules describe "$NAME-grafana" > /dev/null 2>&1 \
  || g compute firewall-rules create "$NAME-grafana" --allow tcp:3000 \
       --source-ranges "$ALLOWED_CIDR" --target-tags "$NAME"

# The startup script runs as root on every boot; install-server.sh is safe to
# re-run, but loading again would be slow, so it runs once. The Grafana
# password goes through instance metadata, readable only from the VM.
startup=$(mktemp); trap 'rm -f "$startup"' EXIT
cat > "$startup" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ -f /var/log/faa-setup.done ]] && exit 0
exec > >(tee -a /var/log/faa-setup.log) 2>&1
md() { curl -fsS -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
echo "=== $(date '+%H:%M:%S') Cloning $(md repo-url) ($(md repo-branch))"
export DEBIAN_FRONTEND=noninteractive
# A stalled mirror download can hang apt for good: time it out and retry.
for attempt in 1 2 3; do
  timeout -k 30 300 apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 update -q \
    && timeout -k 30 300 apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 install -y -q git \
    && break
  (( attempt < 3 )) || exit 1
  dpkg --configure -a || true
done
id ubuntu > /dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
REPO=/home/ubuntu/bigquery-faadata-demo
[[ -d "$REPO" ]] || sudo -u ubuntu git clone -q "$(md repo-url)" "$REPO"
sudo -u ubuntu git -C "$REPO" checkout -q "$(md repo-branch)"
GRAFANA_PASSWORD=$(md grafana-password) APP_USER=ubuntu \
  BIGQUERY_DATASET=$(md dataset) BIGQUERY_LOCATION=$(md location) \
  "$REPO/scripts/install-server.sh" "$(md load-from)" "$(md load-to)"
touch /var/log/faa-setup.done
EOF

echo "=== VM $NAME ($MACHINE_TYPE in $ZONE)"
g compute instances create "$NAME" --zone "$ZONE" --machine-type "$MACHINE_TYPE" \
  --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
  --boot-disk-size 50GB --boot-disk-type pd-balanced \
  --service-account "$SA" --scopes cloud-platform --tags "$NAME" \
  --metadata-from-file startup-script="$startup" \
  --metadata "repo-url=$REPO_URL,repo-branch=$REPO_BRANCH,grafana-password=$GRAFANA_PASSWORD,load-from=$LOAD_FROM,load-to=$LOAD_TO,dataset=$DATASET,location=$LOCATION"

ip=$(g compute instances describe "$NAME" --zone "$ZONE" --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')
echo
echo "Grafana (user admin; dashboards fill in as the data loads): http://$ip:3000"
echo "Setup log: gcloud compute ssh $NAME --zone $ZONE --project $PROJECT -- tail -f /var/log/faa-setup.log"
