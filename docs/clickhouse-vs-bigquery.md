# ClickHouse vs BigQuery: what changed in the port

This project is a port of [clickhouse-faadata-demo](https://github.com/srmadscience/clickhouse-faadata-demo).
Both load the same raw files into the same tables, and run the same dashboards on them. This
page goes through every place where the code differs, and why.

Some parts are unchanged apart from the client calls: the download scripts and the data
mirror, `reproduce.sh`, the CSV reader in the Java loader, the benchmark's workload, and the
dashboards' layout, panels and variables. The ten-year load gives the same row counts in
both: 68,382,309 flights and 42,207,627 weather reports.

## At a glance

| | ClickHouse | BigQuery |
|---|---|---|
| Server | One you run (an EC2 instance in the demo) | Serverless; a dataset in a Google Cloud project |
| Connection settings | `clickhouse.properties`: URL, user, password | `bigquery.properties`: project, dataset, location, optional key file; otherwise Application Default Credentials |
| Scripts talk to it with | `curl` to the HTTP interface (`ch_query`, `ch_insert`) | the `bq` CLI (`bq_query`, `bq_run`, `bq_values`) |
| Java client | `com.clickhouse:client-v2` | `google-cloud-bigquery`, through `libraries-bom` |
| Table storage | `MergeTree` / `ReplacingMergeTree`, `ORDER BY` | partitioned and clustered tables |
| Getting data in | `INSERT` streams (CSV, or Native format) | load jobs (gzipped CSV, resumable upload) |
| Replacing data | `ALTER TABLE ... DROP PARTITION`, then insert | load into a partition with `WRITE_TRUNCATE`, or `DELETE` + `INSERT` in a transaction |
| Duplicates | `ReplacingMergeTree` removes them in the background | removed explicitly with `QUALIFY ROW_NUMBER()` |
| Grafana plugin | `grafana-clickhouse-datasource` | `grafana-bigquery-datasource` |
| Demo server | AWS CloudFormation: ClickHouse, Prometheus, node_exporter and Grafana on one EC2 instance | `gcp/create-vm.sh`: a Compute Engine VM running only Grafana and the loader |
| Cost model | the server, whether used or not | storage, plus bytes read by each query |

## Files

| ClickHouse | BigQuery | Change |
|---|---|---|
| `clickhouse.properties.example` | `bigquery.properties.example` | different settings, see above |
| `src/.../ClickHouseConfig.java` | `src/.../BigQueryConfig.java` | client set-up; also rewrites `faa.` to the configured dataset |
| `src/.../CsvNative.java` (517 lines) | `src/.../CsvConverter.java` (341 lines) | CSV to Native columns, vs CSV to CSV in table order |
| `src/test/.../CsvNativeTest.java` | `src/test/.../CsvConverterTest.java` | tests for the above |
| `sql/15_ontime_tail.sql`, `sql/16_ontime_by_tail.sql` | (removed) | `tail` is now a stored column, and clustering replaces the projection |
| `aws/faa-demo.yaml` | `gcp/create-vm.sh` | CloudFormation template vs a `gcloud` script |
| `grafana/provisioning/datasources/clickhouse.yaml` | `.../bigquery.yaml` | the datasource |
| `testresults_query.csv` | (not yet recorded) | benchmark history |

Every other SQL file, script and dashboard keeps its name, rewritten in BigQuery's dialect.

## Schema (`sql/`)

### Column types

| ClickHouse | BigQuery | Notes |
|---|---|---|
| `String`, `LowCardinality(String)` | `STRING NOT NULL` | BigQuery has no dictionary-encoded type; its columnar storage compresses repeated values anyway. Empty strings are `''`, never NULL, in both, so the SQL can test `tail = ''`. |
| `UInt8`, `UInt16`, `UInt32`, `Int8` | `INT64` (`NOT NULL` if it was not `Nullable`) | BigQuery has one integer type. |
| `Float32` | `FLOAT64` | BigQuery has one floating-point type. |
| `Nullable(T)` | a nullable column of the mapped type | |
| `Date`, `Date32` | `DATE` | |
| `DateTime('UTC')` | `TIMESTAMP` | |

The wider types are part of why BigQuery's logical size is larger. BigQuery bills storage on
uncompressed logical bytes, and the full load came to about 59 GB (`ontime` 32.7 GB,
`flight_weather` 15.3 GB, `weather` 9.5 GB), where ClickHouse stored about 10 GB compressed.

### Table layout

ClickHouse's `ORDER BY` sorts the data on disk, and its primary index lets a query skip
blocks. In BigQuery, partitioning (by month, as in ClickHouse) prunes whole partitions, and
clustering (up to four columns) sorts the data inside each partition so that blocks can be
skipped.

| Table | ClickHouse | BigQuery |
|---|---|---|
| `ontime` | `PARTITION BY toYYYYMM(FlightDate) ORDER BY (FlightDate, Origin, Reporting_Airline)`, plus the `by_tail` projection | `PARTITION BY DATE_TRUNC(FlightDate, MONTH) CLUSTER BY tail` |
| `weather` | `ReplacingMergeTree`, `PARTITION BY toYYYYMM(valid) ORDER BY (station, valid)` | `PARTITION BY TIMESTAMP_TRUNC(valid, MONTH) CLUSTER BY station, valid` |
| `flight_weather` | `ORDER BY (FlightDate, Origin, Reporting_Airline)` | monthly partitions, `CLUSTER BY Origin, Reporting_Airline` |
| `tail_day` | `ORDER BY (tail, FlightDate, Reporting_Airline)` | monthly partitions, `CLUSTER BY tail, Reporting_Airline` |
| `stations`, `airports` | `ReplacingMergeTree ORDER BY station` / `id` | `CLUSTER BY station` / `iata_code`, replaced whole on each load |
| registry tables | `MergeTree ORDER BY tail` etc. | `CLUSTER BY tail` etc. |

New in BigQuery: `weather_load`, a staging table with `weather`'s columns. The registry load
also creates a temporary `registry_load` table and drops it when it finishes.

### The `tail` column and the `by_tail` projection

In ClickHouse, `tail` is an `ALIAS` column on `ontime`, computed when a query reads it:
`upper(if(match(Tail_Number, '^[0-9]'), concat('N', Tail_Number), Tail_Number))`. It fixes
Allegiant's tail numbers, which lack the `N`. The `by_tail` projection keeps a second,
hidden copy of `ontime` sorted by that expression, so that one aircraft's history is
quick to read.

BigQuery has neither alias columns nor projections. So `tail` is a real column, filled
in by the loader (`CsvConverter.normaliseTail`, from the same rule), and `ontime` is
clustered by `tail`. A query for one aircraft then reads only that aircraft's blocks of
each month, with no second copy of the table. The benchmark no longer needs ClickHouse's
`optimize_read_in_order = 0` setting, which it used to stop ClickHouse from ignoring the
projection.

### Views

| Idiom | ClickHouse | BigQuery |
|---|---|---|
| A literal table | `SELECT * FROM values('bts_code String, iata_code String', ('PBI', 'DJT'), ...)` | `SELECT * FROM UNNEST([STRUCT('PBI' AS bts_code, 'DJT' AS iata_code), ...])` |
| One row per array element | `arrayJoin(arrayFilter(c -> c != '', [local_code, icao_code, ...]))` | `UNNEST([local_code, icao_code, ...]) AS code WITH OFFSET AS pos WHERE code != ''` |
| First row of each group | `ORDER BY ... LIMIT 1 BY iata_code` | `QUALIFY ROW_NUMBER() OVER (PARTITION BY iata_code ORDER BY ...) = 1` |
| Typed NULL | `CAST(NULL AS Nullable(Date32))` | `CAST(NULL AS DATE)` |

In `airport_station`, the BigQuery version adds the array position to the `ORDER BY`. That
way, when an airport has several matching codes, the order of preference
(`local_code`, `icao_code`, `gps_code`, `ident`) is stated explicitly. In `aircraft`, the
`QUALIFY` has to sit in a subquery, because it applies to only one branch of a `UNION ALL`.

### Dataset name

The SQL files hard-code `faa.`, as in ClickHouse. In BigQuery, the dataset name can be
configured: `bq_sql` in `scripts/lib.sh` and `BigQueryConfig.sql` in Java rewrite `faa.` to
the configured dataset before running a statement. `bq_sql` also adds a leading newline, so
that SQL beginning with a `--` comment is not taken for a `bq` flag.

## Loading (Java)

### How rows get to the server

ClickHouse's loader sends `INSERT` streams. By default it sends the CSV as it is
(`CSVWithNames`), and the server matches columns by name. With `--binary`, used for the
flights, `CsvNative` parses the CSV on the client and sends gzipped Native-format columns,
which leaves the server much less to do.

A BigQuery CSV load matches fields to columns by position, not by name. So `CsvConverter`
rewrites every file as headerless CSV in the table's column order. It:

- drops CSV columns the table doesn't have, and leaves NULL the table columns the CSV doesn't have,
- derives `tail` from `Tail_Number` (see above),
- writes NULL as `\N`, and passes that to the load job as its null marker. The marker must be
  set on `WriteChannelConfiguration`; the one on `CsvOptions` is ignored there,
- quotes every string, so that an empty string is `""` and not NULL,
- appends `:00` to IEM timestamps without seconds (`2025-01-01 00:51`). ClickHouse read
  these with `date_time_input_format=best_effort`.

The loader then gzips the output (at the fastest level) and streams it to a resumable-upload
load job, `--jobs N` at a time.

### Empty values

The loaders agree on empty strings, which are `''`, but not on empty numbers.
`CsvNative` copies ClickHouse's own CSV rules, under which a quoted empty field (`""`) is 0
in a number column; BTS writes cancelled flights' missing times (`DepTime` and others) that way.
`CsvConverter` makes every empty number NULL, quoted or not, which suits BigQuery and is
arguably more correct. A query that averages those columns over cancelled flights would
give different answers on the two databases.

### Replacing a month

| | ClickHouse | BigQuery |
|---|---|---|
| Flights | `ALTER TABLE faa.ontime DROP PARTITION 202501`, then insert. Not atomic. | `load faa.ontime --replace-partition`: each file loads into `ontime$202501` with `WRITE_TRUNCATE`, which replaces that month atomically. |
| Stations, airports | `TRUNCATE`, then insert | `load --replace` (`WRITE_TRUNCATE` on the table) |

### Waiting for a load job

`Loader.waitFor` polls the job until it is `DONE`, instead of calling `Job.waitFor`. In
one full load, `Job.waitFor` failed with an `InterruptedException` that nothing in the
program had caused, even though the job had succeeded. ClickHouse inserts are synchronous,
so its loader has no job to wait for.

## Scripts

### Running SQL

`ch_query` POSTs SQL to ClickHouse's HTTP port with `curl`, and `ch_insert` streams a file
into an `INSERT ... FORMAT` query. The BigQuery scripts use the `bq` CLI instead. `bq_query`
prints a table, `bq_run` runs statements silently, `bq_values` returns CSV values for
shell loops, and `bq_cli` passes the configured project and location to every call. Most
SQL functions change name: `countIf` → `COUNTIF`, `uniqExact` → `COUNT(DISTINCT)`, `any` →
`ANY_VALUE`, `toYear(d)` → `EXTRACT(YEAR FROM d)`, `toYYYYMM(d)` → `FORMAT_DATE('%Y%m', d)`,
`match` → `REGEXP_CONTAINS`, `multiIf` → `CASE`.

### Rebuilding derived tables: `build-tail-day.sh`, `build-flight-weather.sh`

The ClickHouse scripts loop over the months: they drop a month's partition and then insert
that month. The BigQuery scripts run one transaction instead: `BEGIN TRANSACTION; DELETE
...; INSERT ...; COMMIT`. It covers the whole table, or only the months given
(`scripts/build-tail-day.sh 202606`). Readers never see a half-built table, and a
rebuild of the whole table is a single statement.

### Matching flights to weather (`build-flight-weather.sh`)

This is the largest rewrite. Each flight takes the latest weather report at or before its
scheduled departure at the origin, and its scheduled arrival at the destination. Reports
more than 2 hours old are not used.

- **ClickHouse** does this with `ASOF LEFT JOIN ... ON station = ... AND valid <= sched_dep_utc`,
  one month at a time, reading weather only for that month plus a day before and two days after.
- **BigQuery** has no ASOF join. The script stacks the flights and the weather reports
  into one stream per station and day. A window function,
  `LAST_VALUE(w IGNORE NULLS) OVER (PARTITION BY station, day ORDER BY t, kind)`,
  then gives each flight the last report before it. Each report is also copied into the
  next day, so that a flight just after midnight can still match a report from late the
  evening before. It runs once for departures and once more for arrivals.
  Comparison against a brute-force join gave identical matches for every flight of the
  month it was tested on.

Converting local scheduled times to UTC is simpler in BigQuery.
`TIMESTAMP(datetime, tzname)` takes the time zone from a column. ClickHouse's `toDateTime`
needs a constant time zone, so the script generated one `multiIf` branch for every time
zone in use.

Other details:
- **Ceiling:** the lowest broken, overcast or obscured cloud layer. ClickHouse finds it
  with `arrayFilter`/`arrayMin`, BigQuery with `(SELECT MIN(l) FROM UNNEST([...]))`.
- **Unmatched rows:** ClickHouse's `join_use_nulls = 0` filled them with defaults, tested
  as `valid > toDateTime(0)`. BigQuery's are plain NULLs.

### Weather (`load-weather.sh`)

ClickHouse loads every year in one `--combine` insert straight into `weather`, and
`ReplacingMergeTree` removes duplicate `(station, valid)` rows in the background as it
merges parts. BigQuery doesn't deduplicate, and allows only 1,500 load jobs per table per
day. So each year's files go in one load job into `weather_load`. Then one transaction
deletes the rows in `weather` that have the same `(station, valid)`, inserts the new rows
with `QUALIFY ROW_NUMBER() OVER (PARTITION BY station, valid ORDER BY metar) = 1`, and
truncates the staging table. Re-loading a year is therefore safe, and duplicates never
reach `weather` at all. For 2025, 3,851,434 reports loaded and 3,850,840 remained.

### Aircraft registry (`load-registry.sh`)

ClickHouse streams each raw registry file to the server and parses it there with
`input('c1 String, ...')`. Personal data (individuals' names) is blanked in that SQL, which
means the raw file, addresses and all, is sent to the server first.

BigQuery has no `input()`. The script blanks with `awk` on the client instead: every field
the tables don't use (addresses among them), and the owner's name unless it belongs to an
organisation. Only then does the file go to the server, with `bq load`, into a staging
table of 39 `STRING` columns. That load uses `--quote=''`, because the files contain bare
quotes, and `--allow_jagged_rows`. SQL then builds the tables, using `SAFE.PARSE_DATE` and
`SAFE_CAST` where ClickHouse used `toDate32OrNull` and `toUInt16OrNull`.

### Stations (`load-stations.sh`, `stations_to_csv.py`)

ClickHouse inserted headerless CSV rows and let `ReplacingMergeTree` resolve any station
listed in more than one network file. For BigQuery, `stations_to_csv.py` writes a header,
so the Java loader can map columns by name, and keeps one row per station itself. The
OurAirports CSV goes through the Java loader as well.

### Schema (`create-database.sh`)

The script is the same, and still runs one statement at a time. Each statement is now a
`bq` call, about 2 s each. At the end it lists tables from `faa.__TABLES__` instead of
`system.tables`.

## Benchmark (`QueryBench`)

The workload, its random ranges and its output are unchanged. The differences:

| | ClickHouse | BigQuery |
|---|---|---|
| Parameters | `{tail:String}`, `{from:Date}` | `@tail`, `@from`, `@to` as `QueryParameterValue`s |
| Caching | none to avoid | `setUseQueryCache(false)`, so every query really runs |
| Round trips | one HTTP request | `JobCreationMode.JOB_CREATION_OPTIONAL` (short query mode) avoids creating a job when it can |
| Timeout | socket timeout on the client (a lost connection could wait for ever) | `setJobTimeoutMs`: BigQuery cancels the query |
| Settings | `optimize_read_in_order = 0` (see `by_tail`) | none |
| Results column | `clickhouse_version` | `server` (`BigQuery US`) |

## Grafana dashboards

All 82 queries were rewritten (by a one-off script) for the BigQuery plugin, keeping each
panel's layout, title, units and variables. Typical changes:

- **Date filters.** ClickHouse's `$__dateFilter(FlightDate)` becomes
  `FlightDate BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())`. `$__timeFilter(valid)` on
  timestamps is unchanged.
- **Time series.** Queries return `TIMESTAMP(FlightDate) AS time`, not a `DATE`.
- **Division.** ClickHouse returns `nan` or `inf` on division by zero; BigQuery raises an
  error. So ratios use `SAFE_DIVIDE`, which returns NULL.
- **Column names.** ClickHouse accepts any quoted alias. BigQuery rejects some characters,
  among them `/`, `(`, `°` and `◔`. Such columns get a safe alias in the SQL (`Cxl/1k`
  becomes `Cxl_1k`) and their label back from an "organize" transformation on the panel;
  14 panels need one.
- **Arrays.** ClickHouse array functions become `UNNEST` subqueries. For example, an
  aircraft's longest gap between flights was
  `arrayMax(arrayDifference(arraySort(groupUniqArray(toRelativeDayNum(FlightDate)))))`. It
  is now `ARRAY_AGG(DISTINCT FlightDate)` in the inner query, and a `LAG` over its
  `UNNEST` in the outer one.
- **Aliases in the same SELECT.** ClickHouse lets a column use an alias defined earlier
  in the same `SELECT` (`round(1000 * Cxl / Flights, 1)`). BigQuery doesn't, so the
  expression is repeated.

The datasource (`grafana/provisioning/datasources/bigquery.yaml`) authenticates in one of
two ways. It uses a service-account key, with Grafana given the private key in a file only
root and Grafana can read. On a Compute Engine VM, it can use the VM's own service account
(`gce`) instead. ClickHouse used a user name and password.

## Running in the cloud

The ClickHouse demo server (`aws/faa-demo.yaml` with `install-server.sh`) runs everything on
one EC2 instance: ClickHouse, Prometheus, node_exporter and Grafana. Grafana has two extra
monitoring dashboards ("Node Exporter Full" and "Clickhouse internal exporter"). SSH and
Grafana are open to a given address range.

There is no database server to run or monitor with BigQuery. `gcp/create-vm.sh` therefore
creates a smaller VM, which runs only Grafana and the loader. It also creates a service
account with the BigQuery Job User and Data Editor roles, and a firewall rule opening only
Grafana's port 3000. SSH goes through `gcloud compute ssh`. Deleting the VM leaves the
dataset in place.

## Results

The two versions load the same ten years. These are the BigQuery figures; see the
[README](../README.md#load-times) for details.

- **Full load:** 1 h 14 min 40 s from an empty dataset, run from an M2 Mac at home to the
  `US` multi-region. The two load steps take 61 of those minutes, converting and
  uploading on the client.
- **Benchmark:** 14.7 queries/s for one client with 8 threads, p50 375 ms; ranges up to a
  year stay under 0.8 s at p99.

The two databases' numbers are not directly comparable. ClickHouse's are from its own server
and setup, recorded in that repository's `testresults_*.csv`. BigQuery's include the
round trip from Europe to the US.
