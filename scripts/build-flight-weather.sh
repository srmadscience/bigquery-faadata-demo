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

# Rebuilds faa.flight_weather (flights joined to the weather at both ends) in
# one transaction that replaces the months given, or all of them. Run after
# loading flights, stations or weather.
#
#   scripts/build-flight-weather.sh            every month in faa.ontime
#   scripts/build-flight-weather.sh 202501     just these months
#
# BigQuery has no ASOF JOIN, so each end finds its METAR with a window instead:
# flights and observations go into one stream per station, in time order (an
# observation before a flight at the same minute), and LAST_VALUE(... IGNORE
# NULLS) carries the latest observation forward onto each flight. Reports over
# 2 hours old are not used, so the stream is split by station and day, with
# each observation also put into the next day's: every window is small, and
# the whole build runs as one query.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
bq_check_connection

flights="TRUE"
weather="TRUE"
if [[ $# -gt 0 ]]; then
  for m in "$@"; do [[ "$m" =~ ^[0-9]{6}$ ]] || { echo "error: months are YYYYMM, not $m" >&2; exit 1; }; done
  list=$(printf "'%s'," "$@")
  flights="FORMAT_DATE('%Y%m', FlightDate) IN (${list%,})"
  # The observations those months' flights can match: departures start at most
  # 11 hours before their month in UTC, and the last arrivals (checked over
  # 2016-2026) end within a day of it.
  first=$(printf '%s\n' "$@" | sort | head -1); last=$(printf '%s\n' "$@" | sort | tail -1)
  weather="valid >= TIMESTAMP_SUB(TIMESTAMP('${first:0:4}-${first:4:2}-01'), INTERVAL 1 DAY)
           AND valid < TIMESTAMP_ADD(TIMESTAMP(DATE_ADD(DATE '${last:0:4}-${last:4:2}-01', INTERVAL 1 MONTH)), INTERVAL 2 DAY)"
fi

# obs PREFIX: the matched observation's fields, NULL (or '') if it is over 2 hours old.
obs() {
  local w="$1w" t
  [[ $1 == o ]] && t=fl.sched_dep_utc || t=sched_arr_utc
  local fresh="$w.valid IS NOT NULL AND TIMESTAMP_DIFF($t, $w.valid, MINUTE) <= 120"
  echo "IF($fresh, $w.valid, NULL) AS ${1}_obs_time,
        IF($fresh, $w.tmpf, NULL) AS ${1}_tmpf, IF($fresh, $w.sknt, NULL) AS ${1}_sknt,
        IF($fresh, $w.gust, NULL) AS ${1}_gust, IF($fresh, $w.vsby, NULL) AS ${1}_vsby,
        IF($fresh, $w.ceiling, NULL) AS ${1}_ceiling, IF($fresh, $w.p01i, NULL) AS ${1}_p01i,
        IF($fresh, $w.wxcodes, '') AS ${1}_wxcodes, IF($fresh, $w.category, '') AS ${1}_category,
        IF($fresh, $w.wx, '') AS ${1}_wx"
}

bq_run "
BEGIN TRANSACTION;
DELETE FROM faa.flight_weather WHERE $flights;
INSERT INTO faa.flight_weather
WITH
-- Each flight, with its stations and its scheduled times in UTC. BTS local
-- times are HHMM numbers, with midnight as 2400.
f AS (
  SELECT fl, o_station, d_station, fl.sched_dep_utc,
         TIMESTAMP_ADD(fl.sched_dep_utc, INTERVAL CAST(IFNULL(CRSElapsedTime, 0) AS INT64) MINUTE) AS sched_arr_utc
  FROM (
    SELECT STRUCT(o.FlightDate, o.Reporting_Airline, o.tail, o.Origin, o.Dest, o.CRSDepTime,
                  TIMESTAMP(DATETIME(DATE_ADD(o.FlightDate, INTERVAL IF(o.CRSDepTime >= 2400, 1, 0) DAY),
                                     TIME(DIV(o.CRSDepTime, 100) - IF(o.CRSDepTime >= 2400, 24, 0),
                                          MOD(o.CRSDepTime, 100), 0)),
                            ao.tzname) AS sched_dep_utc,
                  o.DepDelay, o.DepDel15, o.ArrDelay, o.ArrDel15, o.Cancelled, o.CancellationCode,
                  o.Diverted, o.WeatherDelay, o.NASDelay) AS fl,
           o.CRSElapsedTime, ao.station AS o_station, ad.station AS d_station
    FROM faa.ontime AS o
    INNER JOIN faa.airport_station AS ao ON ao.airport = o.Origin
    LEFT JOIN faa.airport_station AS ad ON ad.airport = o.Dest
    WHERE $flights AND ao.tzname != ''
  )
),
-- Weather with derived ceiling, flight category and present-weather class.
wx AS (
  SELECT station, valid,
         STRUCT(valid, tmpf, sknt, gust, vsby, p01i, wxcodes, ceiling,
                CASE WHEN vsby IS NULL AND ceiling IS NULL AND skyc1 = '' THEN ''
                     WHEN ceiling < 500 OR vsby < 1 THEN 'LIFR'
                     WHEN ceiling < 1000 OR vsby < 3 THEN 'IFR'
                     WHEN ceiling <= 3000 OR vsby <= 5 THEN 'MVFR'
                     ELSE 'VFR' END AS category,
                CASE WHEN REGEXP_CONTAINS(wxcodes, r'TS') THEN 'Thunderstorm'
                     WHEN REGEXP_CONTAINS(wxcodes, r'FZ') THEN 'Freezing'
                     WHEN REGEXP_CONTAINS(wxcodes, r'SN|SG|PL|GS|GR') THEN 'Snow/ice'
                     WHEN REGEXP_CONTAINS(wxcodes, r'FG') THEN 'Fog'
                     WHEN REGEXP_CONTAINS(wxcodes, r'RA|DZ|SH') THEN 'Rain'
                     ELSE 'None' END AS wx) AS w
  FROM (
    SELECT *,
           (SELECT MIN(l) FROM UNNEST([
                IF(skyc1 IN ('BKN', 'OVC', 'VV'), skyl1, NULL), IF(skyc2 IN ('BKN', 'OVC', 'VV'), skyl2, NULL),
                IF(skyc3 IN ('BKN', 'OVC', 'VV'), skyl3, NULL), IF(skyc4 IN ('BKN', 'OVC', 'VV'), skyl4, NULL)]) AS l)
             AS ceiling
    FROM faa.weather
    WHERE $weather
  )
),
-- Each observation in its own day's window and the next day's.
wx_days AS (
  SELECT station, valid, DATE_ADD(DATE(valid), INTERVAL d DAY) AS day, w
  FROM wx, UNNEST([0, 1]) AS d
),
dep AS (
  SELECT * EXCEPT (kind, w) FROM (
    SELECT kind, fl, d_station, sched_arr_utc,
           LAST_VALUE(w IGNORE NULLS) OVER (PARTITION BY station, day ORDER BY t, kind) AS ow, w
    FROM (
      SELECT 1 AS kind, o_station AS station, sched_dep_utc AS t, DATE(sched_dep_utc) AS day,
             fl, d_station, sched_arr_utc, NULL AS w
      FROM f
      UNION ALL
      SELECT 0, station, valid, day, NULL, NULL, NULL, w FROM wx_days
    )
  )
  WHERE kind = 1
),
arr AS (
  SELECT * EXCEPT (kind, w) FROM (
    SELECT kind, fl, ow, sched_arr_utc,
           LAST_VALUE(w IGNORE NULLS) OVER (PARTITION BY station, day ORDER BY t, kind) AS dw, w
    FROM (
      SELECT 1 AS kind, d_station AS station, sched_arr_utc AS t, DATE(sched_arr_utc) AS day,
             fl, ow, sched_arr_utc, NULL AS w
      FROM dep
      UNION ALL
      SELECT 0, station, valid, day, NULL, NULL, NULL, w FROM wx_days
    )
  )
  WHERE kind = 1
)
SELECT fl.FlightDate, fl.Reporting_Airline, fl.tail, fl.Origin, fl.Dest, fl.CRSDepTime,
       fl.sched_dep_utc, sched_arr_utc, fl.DepDelay, fl.DepDel15, fl.ArrDelay, fl.ArrDel15,
       fl.Cancelled, fl.CancellationCode, fl.Diverted, fl.WeatherDelay, fl.NASDelay,
       $(obs o),
       $(obs d)
FROM arr;
COMMIT TRANSACTION;"

bq_query "
  SELECT COUNT(*) AS flights,
         ROUND(100 * COUNTIF(o_category != '') / COUNT(*), 1) AS pct_origin_wx,
         ROUND(100 * COUNTIF(d_category != '') / COUNT(*), 1) AS pct_dest_wx,
         (SELECT COUNT(*) FROM faa.ontime) AS ontime_flights
  FROM faa.flight_weather"
