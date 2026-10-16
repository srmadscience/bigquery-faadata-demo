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

-- Maps each BTS airport code (IATA) to its IEM weather station and time zone.
-- IEM uses FAA ids in the lower 48 (JFK) but ICAO ids elsewhere (PAFA for FAI,
-- TJSJ for SJU), so try every code OurAirports knows for the airport.
-- Re-coded and closed airports are covered by faa.airport_aliases and faa.airport_closed.
-- Join flights to weather with:  ontime.Origin = airport_station.airport,
--                                weather.station = airport_station.station
CREATE OR REPLACE VIEW faa.airport_station AS
SELECT
    a.iata_code AS airport,
    s.station   AS station,
    -- IEM lists the Virgin Islands as Atlantic/Bermuda, which observes DST;
    -- the USVI does not, so that would be an hour off for half the year.
    IF(s.network = 'VI_ASOS', 'America/St_Thomas', s.tzname) AS tzname,
    a.name      AS airport_name,
    a.latitude_deg  AS lat,
    a.longitude_deg AS lon
FROM
(
    SELECT ap.iata_code, ap.name, ap.latitude_deg, ap.longitude_deg, code, pos,
           -- prefer open airports with scheduled service when an IATA code is reused
           ap.type = 'closed' AS closed, ap.scheduled_service != 'yes' AS unscheduled
    FROM
    (
        SELECT * FROM faa.airports WHERE iata_code != ''
        UNION ALL
        -- old codes still used by BTS (see 35_airport_aliases.sql)
        SELECT ap.* REPLACE (al.bts_code AS iata_code)
        FROM faa.airports AS ap
        INNER JOIN faa.airport_aliases AS al ON ap.iata_code = al.iata_code
        UNION ALL
        -- closed airports with no codes left (see 35_airport_aliases.sql)
        SELECT ap.* REPLACE (cl.bts_code AS iata_code, cl.station AS local_code)
        FROM faa.airports AS ap
        INNER JOIN faa.airport_closed AS cl ON ap.ident = cl.ident
    ) AS ap,
    UNNEST([ap.local_code, ap.icao_code, ap.gps_code, ap.ident]) AS code WITH OFFSET AS pos
    WHERE code != ''
) AS a
INNER JOIN faa.stations AS s ON s.station = a.code
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (PARTITION BY a.iata_code ORDER BY a.closed, a.unscheduled, a.pos) = 1;
