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

-- BTS "Reporting Carrier On-Time Performance (1987-present)", one row per flight.
-- https://www.transtats.bts.gov/Fields.asp?gnoyr_VQ=FGJ
-- Column names match the BTS CSV header: the loader matches CSV fields to columns
-- by name. Times (CRSDepTime etc.) are local to the airport, as HHMM numbers
-- (729 = 07:29; 2400 = midnight). Empty numbers are NULL; empty strings are ''.
-- One partition per month: load-flights.sh replaces a whole month on reload.
--
-- tail is not in the CSV: the loader fills it in from Tail_Number (see
-- CsvConverter.normaliseTail). Allegiant (G4) reports tail numbers without the
-- US "N" prefix (816NV rather than N816NV); no other carrier does, and the
-- prefixed forms never collide with another tail. A few are in lower case
-- (n346FR). It is empty for some cancelled flights (no aircraft assigned); a
-- handful are placeholders such as '#N/A' or 'SS1', which match no registration.
-- The table is clustered by tail, so one aircraft's history reads only its own
-- blocks instead of every flight in the date range.
CREATE TABLE IF NOT EXISTS faa.ontime
(
    Year                            INT64 NOT NULL,
    Quarter                         INT64 NOT NULL,
    Month                           INT64 NOT NULL,
    DayofMonth                      INT64 NOT NULL,
    DayOfWeek                       INT64 NOT NULL,
    FlightDate                      DATE NOT NULL,
    Reporting_Airline               STRING NOT NULL,
    DOT_ID_Reporting_Airline        INT64 NOT NULL,
    IATA_CODE_Reporting_Airline     STRING NOT NULL,
    Tail_Number                     STRING NOT NULL,
    Flight_Number_Reporting_Airline INT64 NOT NULL,
    OriginAirportID                 INT64 NOT NULL,
    OriginAirportSeqID              INT64 NOT NULL,
    OriginCityMarketID              INT64 NOT NULL,
    Origin                          STRING NOT NULL,
    OriginCityName                  STRING NOT NULL,
    OriginState                     STRING NOT NULL,
    OriginStateFips                 STRING NOT NULL,
    OriginStateName                 STRING NOT NULL,
    OriginWac                       INT64 NOT NULL,
    DestAirportID                   INT64 NOT NULL,
    DestAirportSeqID                INT64 NOT NULL,
    DestCityMarketID                INT64 NOT NULL,
    Dest                            STRING NOT NULL,
    DestCityName                    STRING NOT NULL,
    DestState                       STRING NOT NULL,
    DestStateFips                   STRING NOT NULL,
    DestStateName                   STRING NOT NULL,
    DestWac                         INT64 NOT NULL,
    CRSDepTime                      INT64 NOT NULL,
    DepTime                         INT64,
    DepDelay                        FLOAT64,
    DepDelayMinutes                 FLOAT64,
    DepDel15                        FLOAT64,
    DepartureDelayGroups            INT64,
    DepTimeBlk                      STRING NOT NULL,
    TaxiOut                         FLOAT64,
    WheelsOff                       INT64,
    WheelsOn                        INT64,
    TaxiIn                          FLOAT64,
    CRSArrTime                      INT64 NOT NULL,
    ArrTime                         INT64,
    ArrDelay                        FLOAT64,
    ArrDelayMinutes                 FLOAT64,
    ArrDel15                        FLOAT64,
    ArrivalDelayGroups              INT64,
    ArrTimeBlk                      STRING NOT NULL,
    Cancelled                       FLOAT64 NOT NULL,
    CancellationCode                STRING NOT NULL,
    Diverted                        FLOAT64 NOT NULL,
    CRSElapsedTime                  FLOAT64,
    ActualElapsedTime               FLOAT64,
    AirTime                         FLOAT64,
    Flights                         FLOAT64 NOT NULL,
    Distance                        FLOAT64 NOT NULL,
    DistanceGroup                   INT64 NOT NULL,
    CarrierDelay                    FLOAT64,
    WeatherDelay                    FLOAT64,
    NASDelay                        FLOAT64,
    SecurityDelay                   FLOAT64,
    LateAircraftDelay               FLOAT64,
    FirstDepTime                    INT64,
    TotalAddGTime                   FLOAT64,
    LongestAddGTime                 FLOAT64,
    DivAirportLandings              INT64,
    DivReachedDest                  FLOAT64,
    DivActualElapsedTime            FLOAT64,
    DivArrDelay                     FLOAT64,
    DivDistance                     FLOAT64,
    Div1Airport                     STRING NOT NULL,
    Div1AirportID                   INT64,
    Div1AirportSeqID                INT64,
    Div1WheelsOn                    INT64,
    Div1TotalGTime                  FLOAT64,
    Div1LongestGTime                FLOAT64,
    Div1WheelsOff                   INT64,
    Div1TailNum                     STRING NOT NULL,
    Div2Airport                     STRING NOT NULL,
    Div2AirportID                   INT64,
    Div2AirportSeqID                INT64,
    Div2WheelsOn                    INT64,
    Div2TotalGTime                  FLOAT64,
    Div2LongestGTime                FLOAT64,
    Div2WheelsOff                   INT64,
    Div2TailNum                     STRING NOT NULL,
    Div3Airport                     STRING NOT NULL,
    Div3AirportID                   INT64,
    Div3AirportSeqID                INT64,
    Div3WheelsOn                    INT64,
    Div3TotalGTime                  FLOAT64,
    Div3LongestGTime                FLOAT64,
    Div3WheelsOff                   INT64,
    Div3TailNum                     STRING NOT NULL,
    Div4Airport                     STRING NOT NULL,
    Div4AirportID                   INT64,
    Div4AirportSeqID                INT64,
    Div4WheelsOn                    INT64,
    Div4TotalGTime                  FLOAT64,
    Div4LongestGTime                FLOAT64,
    Div4WheelsOff                   INT64,
    Div4TailNum                     STRING NOT NULL,
    Div5Airport                     STRING NOT NULL,
    Div5AirportID                   INT64,
    Div5AirportSeqID                INT64,
    Div5WheelsOn                    INT64,
    Div5TotalGTime                  FLOAT64,
    Div5LongestGTime                FLOAT64,
    Div5WheelsOff                   INT64,
    Div5TailNum                     STRING NOT NULL,
    tail                            STRING NOT NULL
)
PARTITION BY DATE_TRUNC(FlightDate, MONTH)
CLUSTER BY tail;
