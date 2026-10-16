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

-- IEM ASOS observations (METAR routine + special reports), times in UTC.
-- https://mesonet.agron.iastate.edu/request/download.phtml
-- Units: tmpf/dwpf/feel F, relh %, drct degrees, sknt/gust knots, p01i inches
-- (0.0001 = trace; test with p01i < 0.001), alti inHg, mslp mb, vsby miles, skyl feet.
-- One row per (station, valid): load-weather.sh loads each year into
-- faa.weather_load, then replaces the rows it holds and drops duplicates, so
-- reloads are safe.
CREATE TABLE IF NOT EXISTS faa.weather
(
    station           STRING NOT NULL,
    valid             TIMESTAMP NOT NULL,
    lon               FLOAT64 NOT NULL,
    lat               FLOAT64 NOT NULL,
    elevation         FLOAT64,
    tmpf              FLOAT64,
    dwpf              FLOAT64,
    relh              FLOAT64,
    drct              FLOAT64,
    sknt              FLOAT64,
    p01i              FLOAT64,
    alti              FLOAT64,
    mslp              FLOAT64,
    vsby              FLOAT64,
    gust              FLOAT64,
    skyc1             STRING NOT NULL,
    skyc2             STRING NOT NULL,
    skyc3             STRING NOT NULL,
    skyc4             STRING NOT NULL,
    skyl1             FLOAT64,
    skyl2             FLOAT64,
    skyl3             FLOAT64,
    skyl4             FLOAT64,
    wxcodes           STRING NOT NULL,
    ice_accretion_1hr FLOAT64,
    ice_accretion_3hr FLOAT64,
    ice_accretion_6hr FLOAT64,
    peak_wind_gust    FLOAT64,
    peak_wind_drct    FLOAT64,
    peak_wind_time    TIMESTAMP,
    feel              FLOAT64,
    metar             STRING NOT NULL,
    snowdepth         FLOAT64
)
PARTITION BY TIMESTAMP_TRUNC(valid, MONTH)
CLUSTER BY station, valid;

-- Staging table for load-weather.sh: holds the last batch loaded.
CREATE TABLE IF NOT EXISTS faa.weather_load
(
    station           STRING NOT NULL,
    valid             TIMESTAMP NOT NULL,
    lon               FLOAT64 NOT NULL,
    lat               FLOAT64 NOT NULL,
    elevation         FLOAT64,
    tmpf              FLOAT64,
    dwpf              FLOAT64,
    relh              FLOAT64,
    drct              FLOAT64,
    sknt              FLOAT64,
    p01i              FLOAT64,
    alti              FLOAT64,
    mslp              FLOAT64,
    vsby              FLOAT64,
    gust              FLOAT64,
    skyc1             STRING NOT NULL,
    skyc2             STRING NOT NULL,
    skyc3             STRING NOT NULL,
    skyc4             STRING NOT NULL,
    skyl1             FLOAT64,
    skyl2             FLOAT64,
    skyl3             FLOAT64,
    skyl4             FLOAT64,
    wxcodes           STRING NOT NULL,
    ice_accretion_1hr FLOAT64,
    ice_accretion_3hr FLOAT64,
    ice_accretion_6hr FLOAT64,
    peak_wind_gust    FLOAT64,
    peak_wind_drct    FLOAT64,
    peak_wind_time    TIMESTAMP,
    feel              FLOAT64,
    metar             STRING NOT NULL,
    snowdepth         FLOAT64
);
