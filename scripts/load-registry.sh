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

# Replaces faa.registry_master, faa.registry_dereg and faa.registry_models with
# the newest data/raw/registry/ReleasableAircraft_*.zip (or the zip given),
# refreshes the faa.aircraft_info snapshot, then reports how many BTS tail
# numbers it identifies.
#
#   scripts/load-registry.sh
#   scripts/load-registry.sh data/raw/registry/ReleasableAircraft_20261010.zip
#
# The FAA files are comma-separated with space-padded fields, a UTF-8 BOM and a
# trailing comma. Columns are read by position (see the FAA's ardata.pdf): each
# file is loaded with bq into faa.registry_load, where every field is a STRING
# (c1..cN), then trimmed and typed here. Owner street addresses are never
# loaded into the registry tables; owner names only for organisations.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
bq_check_connection

zip="${1:-$(ls -1 "$PROJECT_DIR"/data/raw/registry/ReleasableAircraft_*.zip 2>/dev/null | tail -1)}"
[[ -f "$zip" ]] || { echo "No registry zip found; run fetch-registry.sh first." >&2; exit 1; }
echo "Loading $(basename "$zip")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; bq_cli rm -f -t "$BQ_DATASET.registry_load" > /dev/null 2>&1 || true' EXIT
schema=$(for i in $(seq 1 39); do printf 'c%d:STRING,' "$i"; done); schema=${schema%,}

# stage FILE KEEP [AWK_CONDITION NAME_FIELD]: replaces faa.registry_load with
# FILE from the zip, with every field but those listed in KEEP blanked before
# it leaves this machine (addresses and the like), and the owner's name in
# NAME_FIELD blanked unless AWK_CONDITION says it is an organisation. The files
# never quote fields but do contain literal quotes ("B"-BALLOON); rows have 14
# to 40 fields, the last empty.
stage() {
  unzip -p "$zip" "$1" | awk -F, -v OFS=, -v keep="$2" -v name="${4:-0}" "
    BEGIN { n = split(keep, k, \" \"); for (i = 1; i <= n; i++) kept[k[i]] = 1 }
    NR > 1 {
      if (name && !(${3:-1})) \$name = \"\"
      for (i = 1; i <= NF; i++) if (!(i in kept)) \$i = \"\"
    }
    { print }" | gzip -1 > "$tmp/$1.gz"
  bq_cli load --replace --source_format=CSV --skip_leading_rows=1 --quote='' \
    --allow_jagged_rows --ignore_unknown_values \
    "$BQ_DATASET.registry_load" "$tmp/$1.gz" "$schema" 2>&1 > /dev/null | grep -v '^Upload complete' >&2 || true
  rm "$tmp/$1.gz"
}
t() { echo "IFNULL(TRIM($1), '')"; }
d() { echo "SAFE.PARSE_DATE('%Y%m%d', TRIM($1))"; }
year() { echo "NULLIF(SAFE_CAST(TRIM($1) AS INT64), 0)"; }
# Organisation registrant types; 1 (individual) and 4 (co-owned) are people.
ORG="TRIM(c6) IN ('2', '3', '5', '7', '8', '9')"

stage MASTER.txt "1 2 3 4 5 6 7 16 17 18 19 20 21 24 30 34" "\$6 ~ /^ *[235789] *\$/" 7
bq_run "
  TRUNCATE TABLE faa.registry_master;
  INSERT INTO faa.registry_master
  SELECT CONCAT('N', $(t c1)), $(t c2), $(t c3), $(t c4), $(year c5),
         $(t c6), IF($ORG, $(t c7), ''), $(t c18), $(t c19), $(t c20), $(t c21), $(t c34),
         $(d c24), $(d c17), $(d c16), $(d c30)
  FROM faa.registry_load"

stage DEREG.txt "1 2 3 4 5 11 12 13 17 18 22 38" \
  "\$5 ~ /(^|[^A-Z])(INC|LLC|CORP|CORPORATION|CO|COMPANY|LTD|BANK|AIRLINES?|AIRWAYS|LEASING|AVIATION|GOVERNMENT)([^A-Z]|\$)/" 5
# DEREG has no registrant type, so names are kept only when they look like an
# organisation (a company suffix such as INC/LLC/CORP/BANK/AIRLINES). TRUST is
# deliberately not one: personal family trusts carry an individual's name.
bq_run "
  TRUNCATE TABLE faa.registry_dereg;
  INSERT INTO faa.registry_dereg
  SELECT CONCAT('N', $(t c1)), $(t c2), $(t c3), $(t c11), $(year c12), $(t c4),
         IF(REGEXP_CONTAINS(TRIM(c5), r'\b(INC|LLC|CORP|CORPORATION|CO|COMPANY|LTD|BANK|AIRLINES?|AIRWAYS|LEASING|AVIATION|GOVERNMENT)\b'),
            TRIM(c5), ''),
         $(t c13), $(d c17), $(d c18), $(d c22), $(t c38)
  FROM faa.registry_load"

stage ACFTREF.txt "1 2 3 4 5 6 8 9 10 11"
bq_run "
  TRUNCATE TABLE faa.registry_models;
  INSERT INTO faa.registry_models
  SELECT $(t c1), $(t c2), $(t c3), $(t c4), $(t c5), $(t c6),
         SAFE_CAST(TRIM(c8) AS INT64), SAFE_CAST(TRIM(c9) AS INT64), $(t c10), SAFE_CAST(TRIM(c11) AS INT64)
  FROM faa.registry_load"

bq_run "
  TRUNCATE TABLE faa.aircraft_info;
  INSERT INTO faa.aircraft_info
  SELECT tail, registered, make_model, year_mfr, seats, registrant, cancel_date FROM faa.aircraft"

bq_query "SELECT 'registry_master' AS t, COUNT(*) AS n FROM faa.registry_master
          UNION ALL SELECT 'registry_dereg', COUNT(*) FROM faa.registry_dereg
          UNION ALL SELECT 'registry_models', COUNT(*) FROM faa.registry_models
          UNION ALL SELECT 'aircraft_info', COUNT(*) FROM faa.aircraft_info"
echo "BTS tail numbers identified:"
bq_query "
  SELECT COUNT(*) AS tails, COUNTIF(a.tail IS NOT NULL) AS identified,
         COUNTIF(a.registered = 1) AS currently_registered,
         ROUND(100 * SAFE_DIVIDE(COUNTIF(a.tail IS NOT NULL), COUNT(*)), 1) AS pct
  FROM (SELECT DISTINCT tail FROM faa.ontime WHERE tail != '') AS o
  LEFT JOIN faa.aircraft_info AS a ON a.tail = o.tail"
