/*
 * Copyright 2026 David Rolfe
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package ie.rolfe.faadata;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.channels.Channels;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.stream.Stream;
import java.util.zip.Deflater;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import com.google.cloud.bigquery.BigQuery;
import com.google.cloud.bigquery.CsvOptions;
import com.google.cloud.bigquery.Field;
import com.google.cloud.bigquery.Job;
import com.google.cloud.bigquery.JobId;
import com.google.cloud.bigquery.JobInfo;
import com.google.cloud.bigquery.JobStatistics.LoadStatistics;
import com.google.cloud.bigquery.QueryJobConfiguration;
import com.google.cloud.bigquery.StandardTableDefinition;
import com.google.cloud.bigquery.Table;
import com.google.cloud.bigquery.TableDataWriteChannel;
import com.google.cloud.bigquery.TableId;
import com.google.cloud.bigquery.TimePartitioning;
import com.google.cloud.bigquery.WriteChannelConfiguration;

/**
 * Command-line entry point.
 *
 * <pre>
 *   ping                          check connectivity and that the dataset exists
 *   schema &lt;file.sql&gt;...          run ';'-separated DDL statements
 *   load &lt;table&gt; [--replace | --replace-partition] [--combine] [--jobs N] &lt;path&gt;...
 *                                 load CSV files (plain, .gz or .zip) into a table
 *   bench &lt;workload&gt; [options]     time randomly generated queries (see {@link QueryBench})
 * </pre>
 *
 * Each file is one BigQuery load job: the loader matches the CSV's columns to
 * the table's by name (see {@link CsvConverter}) and streams the result,
 * gzipped, as a resumable upload, so memory use is independent of file size.
 * Load jobs are free, but BigQuery allows 1,500 a day per table.
 * <p>
 * By default the rows are appended. --replace replaces the whole table.
 * --replace-partition replaces just the partition holding the file's first row
 * (the job fails if any row belongs to another), which is how a month of
 * flights is reloaded. --combine puts all the files under each path in one load
 * job, which is much faster for many small files. --jobs N runs N load jobs at a time.
 */
public class Loader {

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            usage();
            return;
        }
        BigQueryConfig config = BigQueryConfig.load();
        if (args[0].equals("bench")) {
            QueryBench.run(config, List.of(args).subList(1, args.length));
            return;
        }
        BigQuery bigquery = config.newClient();
        switch (args[0]) {
            case "ping" -> ping(bigquery, config);
            case "schema" -> schema(bigquery, config, List.of(args).subList(1, args.length));
            case "load" -> {
                if (args.length < 3) {
                    usage();
                    System.exit(1);
                }
                load(bigquery, config, args[1], List.of(args).subList(2, args.length));
            }
            default -> {
                usage();
                System.exit(1);
            }
        }
    }

    private static void usage() {
        System.err.println("usage: Loader ping | schema <file.sql>... | load <table> [--replace | --replace-partition] [--combine] [--jobs N] <file-or-dir>...\n"
                + "     | bench flight-history [--rate Q] [--threads N] [--duration S] [--timeout S] [--seed N] [--log file.csv]");
    }

    private static void ping(BigQuery bigquery, BigQueryConfig config) throws Exception {
        bigquery.query(QueryJobConfiguration.of("SELECT 1"));
        String project = bigquery.getOptions().getProjectId();
        System.out.println("Connected to BigQuery project " + project + ", location " + config.location()
                + "; dataset " + config.dataset()
                + (bigquery.getDataset(config.dataset()) == null ? " does not exist yet" : " exists"));
    }

    private static void schema(BigQuery bigquery, BigQueryConfig config, List<String> files) throws Exception {
        for (String file : files) {
            for (String stmt : Files.readString(Path.of(file)).split(";")) {
                String sql = stripComments(stmt).strip();
                if (!sql.isEmpty()) {
                    System.out.println("Executing: " + sql.lines().findFirst().orElse(""));
                    bigquery.query(QueryJobConfiguration.of(config.sql(sql)));
                }
            }
        }
    }

    private static String stripComments(String sql) {
        return sql.lines().filter(l -> !l.strip().startsWith("--")).reduce("", (a, b) -> a + b + "\n");
    }

    private enum Mode { APPEND, REPLACE, REPLACE_PARTITION }

    private static void load(BigQuery bigquery, BigQueryConfig config, String tableName, List<String> args)
            throws Exception {
        List<String> paths = new ArrayList<>();
        Mode mode = Mode.APPEND;
        boolean combine = false;
        int jobs = 1;
        for (int i = 0; i < args.size(); i++) {
            switch (args.get(i)) {
                case "--replace" -> mode = Mode.REPLACE;
                case "--replace-partition" -> mode = Mode.REPLACE_PARTITION;
                case "--combine" -> combine = true;
                case "--jobs" -> jobs = Integer.parseInt(args.get(++i));
                default -> paths.add(args.get(i));
            }
        }
        TableId tableId = config.table(tableName);
        Table table = bigquery.getTable(tableId);
        if (table == null) {
            throw new IllegalArgumentException("table " + tableName + " not found in dataset " + config.dataset());
        }
        StandardTableDefinition definition = table.getDefinition();
        List<Field> schema = definition.getSchema().getFields();
        TimePartitioning partitioning = definition.getTimePartitioning();
        if (mode == Mode.REPLACE_PARTITION && (partitioning == null || partitioning.getField() == null)) {
            throw new IllegalArgumentException("--replace-partition: " + tableName + " is not partitioned by a column");
        }
        if (mode == Mode.REPLACE && (combine ? paths.size() : expand(paths).size()) > 1) {
            throw new IllegalArgumentException("--replace with more than one load job would keep only the last");
        }

        // One load job per file, or per path with --combine.
        List<List<Path>> batches = new ArrayList<>();
        if (combine) {
            for (String path : paths) {
                batches.add(expand(List.of(path)));
            }
        } else {
            for (Path file : expand(paths)) {
                batches.add(List.of(file));
            }
        }
        ExecutorService pool = Executors.newFixedThreadPool(jobs);
        long totalRows = 0;
        try {
            List<Future<Long>> results = new ArrayList<>();
            for (List<Path> files : batches) {
                Mode m = mode;
                results.add(pool.submit(() -> {
                    long start = System.nanoTime();
                    TableId target = m == Mode.REPLACE_PARTITION
                            ? TableId.of(tableId.getProject(), tableId.getDataset(),
                                    tableId.getTable() + "$" + partition(files.get(0), partitioning))
                            : tableId;
                    long rows = loadJob(bigquery, config, target, schema, files, m != Mode.APPEND);
                    System.out.printf("%s -> %s: %,d rows in %.1fs%n",
                            files.size() == 1 ? files.get(0) : files.get(0).getParent() + " (" + files.size() + " files)",
                            target.getTable(), rows, (System.nanoTime() - start) / 1e9);
                    return rows;
                }));
            }
            for (Future<Long> result : results) {
                try {
                    totalRows += result.get();
                } catch (ExecutionException e) {
                    throw e.getCause() instanceof Exception cause ? cause : e;
                }
            }
        } finally {
            pool.shutdownNow();
        }
        System.out.printf("Total: %,d rows%n", totalRows);
    }

    /** Runs one load job of {@code files} into {@code target}, and returns the rows loaded. */
    private static long loadJob(BigQuery bigquery, BigQueryConfig config, TableId target, List<Field> schema,
                                List<Path> files, boolean truncate) throws Exception {
        WriteChannelConfiguration load = WriteChannelConfiguration.newBuilder(target)
                .setFormatOptions(CsvOptions.newBuilder().setAllowQuotedNewLines(true).build())
                // set here: WriteChannelConfiguration ignores the CsvOptions one
                .setNullMarker(CsvConverter.NULL_MARKER)
                .setCreateDisposition(JobInfo.CreateDisposition.CREATE_NEVER)
                .setWriteDisposition(truncate ? JobInfo.WriteDisposition.WRITE_TRUNCATE
                        : JobInfo.WriteDisposition.WRITE_APPEND)
                .setMaxBadRecords(0)
                .build();
        JobId jobId = JobId.newBuilder().setLocation(config.location())
                .setJob("faa_load_" + UUID.randomUUID().toString().replace("-", "")).build();
        TableDataWriteChannel channel = bigquery.writer(jobId, load);
        channel.setChunkSize(16 << 20);
        // BigQuery recognises gzip by its header; the fastest level shrinks the
        // upload about sixfold for much less CPU than parsing takes.
        try (OutputStream upload = Channels.newOutputStream(channel);
             GZIPOutputStream gz = new GZIPOutputStream(upload, 1 << 16) {
                 {
                     def.setLevel(Deflater.BEST_SPEED);
                 }
             }) {
            for (Path file : files) {
                convert(file, schema, gz);
            }
        }
        Job job = channel.getJob().waitFor();
        if (job == null) {
            throw new IOException("load job " + jobId.getJob() + " disappeared");
        }
        if (job.getStatus().getError() != null) {
            throw new IOException("load job " + jobId.getJob() + " into " + target.getTable() + " failed: "
                    + job.getStatus().getError() + ", " + job.getStatus().getExecutionErrors());
        }
        return ((LoadStatistics) job.getStatistics()).getOutputRows();
    }

    /** Writes one file, or the CSV inside one zip, to {@code out} as {@link CsvConverter} output. */
    private static void convert(Path file, List<Field> schema, OutputStream out) throws IOException {
        try (InputStream in = open(file)) {
            CsvConverter.CsvReader csv = new CsvConverter.CsvReader(in);
            new CsvConverter(CsvConverter.readHeader(csv), schema).write(csv, out);
        }
    }

    /**
     * The partition, e.g. 202501, that the first row of {@code file} belongs
     * to: its value of the partitioning column, truncated to the partitioning unit.
     */
    private static String partition(Path file, TimePartitioning partitioning) throws IOException {
        try (InputStream in = open(file)) {
            CsvConverter.CsvReader csv = new CsvConverter.CsvReader(in);
            int column = CsvConverter.readHeader(csv).indexOf(partitioning.getField());
            if (column < 0) {
                throw new IOException(file + " has no column " + partitioning.getField());
            }
            String value = "";
            boolean more = csv.hasMore();
            for (int i = 0; more; i++) {
                more = csv.next();
                if (i == column) {
                    value = csv.text();
                    break;
                }
            }
            String date = value.replace("-", "");   // YYYYMMDD...
            if (date.length() < 8) {
                throw new IOException(file + ": cannot tell the partition from '" + value + "'");
            }
            return switch (partitioning.getType()) {
                case YEAR -> date.substring(0, 4);
                case MONTH -> date.substring(0, 6);
                case DAY -> date.substring(0, 8);
                default -> throw new IOException("--replace-partition: " + partitioning.getType() + " partitions are not supported");
            };
        }
    }

    /** A CSV file's contents: plain, gzipped, or the first .csv inside a zip (as BTS publishes them). */
    private static InputStream open(Path file) throws IOException {
        String name = file.getFileName().toString().toLowerCase();
        InputStream raw = Files.newInputStream(file);
        if (name.endsWith(".gz")) {
            return new GZIPInputStream(raw, 1 << 16);
        }
        if (name.endsWith(".zip")) {
            ZipInputStream zip = new ZipInputStream(raw);
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                if (!entry.isDirectory() && entry.getName().toLowerCase().endsWith(".csv")) {
                    return zip;
                }
            }
            zip.close();
            throw new IOException(file + " has no .csv inside");
        }
        return raw;
    }

    private static List<Path> expand(List<String> paths) throws IOException {
        List<Path> files = new ArrayList<>();
        for (String p : paths) {
            Path path = Path.of(p);
            if (Files.isDirectory(path)) {
                try (Stream<Path> s = Files.walk(path)) {
                    s.filter(Files::isRegularFile)
                            .filter(f -> !f.getFileName().toString().startsWith("."))
                            .sorted()
                            .forEach(files::add);
                }
            } else {
                files.add(path);
            }
        }
        return files;
    }
}
