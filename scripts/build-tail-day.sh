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

# Rebuilds faa.tail_day (flights per aircraft per day) from faa.ontime, in one
# transaction that replaces the months given, or all of them. Run after
# loading flights.
#
#   scripts/build-tail-day.sh            every month in faa.ontime
#   scripts/build-tail-day.sh 202501     just these months
set -euo pipefail
source "$(dirname "$0")/lib.sh"
bq_check_connection

where="TRUE"
if [[ $# -gt 0 ]]; then
  for m in "$@"; do [[ "$m" =~ ^[0-9]{6}$ ]] || { echo "error: months are YYYYMM, not $m" >&2; exit 1; }; done
  list=$(printf "'%s'," "$@")
  where="FORMAT_DATE('%Y%m', FlightDate) IN (${list%,})"
fi

bq_run "
  BEGIN TRANSACTION;
  DELETE FROM faa.tail_day WHERE $where;
  INSERT INTO faa.tail_day
  SELECT FlightDate, Reporting_Airline, tail,
         COUNT(*), COUNTIF(Cancelled = 0),
         COUNTIF(Cancelled = 1 AND CancellationCode = 'A'),
         COUNTIF(Cancelled = 1 AND CancellationCode != 'A'),
         COUNTIF(Diverted = 1),
         IFNULL(SUM(CarrierDelay), 0), COUNTIF(CarrierDelay >= 15)
  FROM faa.ontime
  WHERE $where
  GROUP BY FlightDate, Reporting_Airline, tail;
  COMMIT TRANSACTION;"

bq_query "
  SELECT (SELECT COUNT(*) FROM faa.ontime) AS ontime_flights,
         SUM(flights) AS tail_day_flights, COUNT(*) AS tail_day_rows
  FROM faa.tail_day"
