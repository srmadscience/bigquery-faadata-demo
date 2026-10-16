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

# Creates the faa dataset (and its tables and views) by running sql/*.sql
# against BigQuery in file-name order. Every statement uses IF NOT EXISTS or
# OR REPLACE, so it is safe to re-run. Needs bash and the bq CLI.
# To change a table's columns, partitioning or clustering, drop it first.
#
#   scripts/create-database.sh            run everything in sql/
#   scripts/create-database.sh FILE...    run only the given files
#   DRY_RUN=1 scripts/create-database.sh  print the statements, run nothing
#
# Connection settings: see scripts/lib.sh.
# Statements must end with ';' at the end of a line.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$PROJECT_DIR"

run_sql() {
  if [[ -n "${DRY_RUN:-}" ]]; then
    printf '%s\n\n' "$1"
  else
    bq_run "$1"
  fi
}

[[ -n "${DRY_RUN:-}" ]] || bq_check_connection

files=("$@")
[[ ${#files[@]} -gt 0 ]] || files=(sql/*.sql)

for file in "${files[@]}"; do
  echo "== $file"
  stmt=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(--|$) ]] && continue
    stmt+="$line"$'\n'
    if [[ "$line" =~ \;[[:space:]]*$ ]]; then
      echo "   ${stmt%%$'\n'*}"
      run_sql "$stmt"
      stmt=""
    fi
  done < "$file"
  if [[ -n "${stmt//[[:space:]]/}" ]]; then
    echo "error: $file has a statement without a terminating ';'" >&2
    exit 1
  fi
done

if [[ -z "${DRY_RUN:-}" ]]; then
  echo "Tables in $BQ_DATASET:"
  bq_query "SELECT table_id AS name, IF(type = 2, 'VIEW', 'TABLE') AS type, row_count
            FROM faa.__TABLES__ ORDER BY name"
fi
