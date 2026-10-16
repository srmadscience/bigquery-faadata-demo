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

# Loads IEM CSVs from data/raw/weather/ (or the files/dirs given) into faa.weather.
# Each year directory (or file given) goes in as one load job into
# faa.weather_load: one job per station file would be slower, and BigQuery
# allows only 1,500 load jobs a day per table. Then, in one transaction, the
# observations it holds replace those with the same (station, valid) in
# faa.weather, keeping one of any duplicates, so re-loading is safe.
#
#   scripts/load-weather.sh
#   scripts/load-weather.sh data/raw/weather/2025
set -euo pipefail
source "$(dirname "$0")/lib.sh"
bq_check_connection
ensure_loader

paths=("$@")
[[ ${#paths[@]} -gt 0 ]] || paths=("$PROJECT_DIR"/data/raw/weather/[0-9][0-9][0-9][0-9])
[[ -e "${paths[0]}" ]] || { echo "No weather files found; run fetch-weather.sh first." >&2; exit 1; }

for path in "${paths[@]}"; do
  java -jar "$LOADER_JAR" load faa.weather_load --replace --combine "$path"
  bq_run "
    DECLARE lo, hi TIMESTAMP;
    SET (lo, hi) = (SELECT AS STRUCT MIN(valid), MAX(valid) FROM faa.weather_load);
    BEGIN TRANSACTION;
    DELETE FROM faa.weather
    WHERE valid BETWEEN lo AND hi
      AND STRUCT(station, valid) IN (SELECT AS STRUCT station, valid FROM faa.weather_load);
    INSERT INTO faa.weather
    SELECT * FROM faa.weather_load
    WHERE TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY station, valid ORDER BY metar) = 1;
    COMMIT TRANSACTION;
    TRUNCATE TABLE faa.weather_load;"
done

bq_query "SELECT EXTRACT(YEAR FROM valid) AS year, COUNT(DISTINCT station) AS stations, COUNT(*) AS observations
          FROM faa.weather GROUP BY year ORDER BY year"
