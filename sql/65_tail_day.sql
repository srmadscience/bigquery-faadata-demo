-- Copyright 2026 David Rolfe
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- One row per aircraft per airline per day, summarising faa.ontime for the
-- Aircraft Reliability dashboard: about a quarter of the rows, and clustered by
-- tail so one aircraft's history reads only its own blocks. Built by
-- scripts/build-tail-day.sh (rebuild after loading flights). Rows with an
-- empty tail hold the flights that had no aircraft assigned. An aircraft almost
-- never flies for two airlines in a day, so COUNT(*) = aircraft-days.
CREATE TABLE IF NOT EXISTS faa.tail_day
(
    FlightDate        DATE NOT NULL,
    Reporting_Airline STRING NOT NULL,
    tail              STRING NOT NULL,
    flights           INT64 NOT NULL,   -- scheduled, including cancelled
    completed         INT64 NOT NULL,   -- not cancelled (diverted included)
    cxl_carrier       INT64 NOT NULL,   -- cancelled by the carrier (code A)
    cxl_other         INT64 NOT NULL,   -- cancelled for weather, NAS or security (B, C, D)
    diverted          INT64 NOT NULL,
    carrier_delay     FLOAT64 NOT NULL, -- sum of CarrierDelay minutes
    delayed15         INT64 NOT NULL    -- CarrierDelay >= 15
)
PARTITION BY DATE_TRUNC(FlightDate, MONTH)
CLUSTER BY tail, Reporting_Airline;
