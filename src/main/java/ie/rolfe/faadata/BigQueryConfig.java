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
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.google.auth.oauth2.GoogleCredentials;
import com.google.cloud.bigquery.BigQuery;
import com.google.cloud.bigquery.BigQueryOptions;
import com.google.cloud.bigquery.TableId;

/**
 * Connection settings for BigQuery.
 * <p>
 * Values are resolved in this order: environment variable, then
 * {@code ./bigquery.properties} (git-ignored), then built-in default.
 * Credentials are Google's Application Default Credentials (from
 * {@code gcloud auth application-default login}, GOOGLE_APPLICATION_CREDENTIALS,
 * or the machine's service account on Google Cloud) unless
 * {@code bigquery.credentials} names a service-account key file. Key files must
 * never be committed.
 */
public record BigQueryConfig(String project, String dataset, String location, String credentials) {

    private static final String LOCAL_PROPS = "bigquery.properties";

    /** The dataset name the SQL is written with; see {@link #sql(String)}. */
    static final String SQL_DATASET = "faa";

    private static final Pattern DATASET_REF = Pattern.compile("(?<![\\w.`])" + SQL_DATASET + "(?=[.;])");

    public static BigQueryConfig load() {
        Properties props = new Properties();
        Path local = Path.of(LOCAL_PROPS);
        if (Files.isReadable(local)) {
            try (InputStream in = Files.newInputStream(local)) {
                props.load(in);
            } catch (IOException e) {
                throw new IllegalStateException("Unable to read " + local.toAbsolutePath(), e);
            }
        }
        return new BigQueryConfig(
                resolve(props, "BIGQUERY_PROJECT", "bigquery.project", ""),
                resolve(props, "BIGQUERY_DATASET", "bigquery.dataset", SQL_DATASET),
                resolve(props, "BIGQUERY_LOCATION", "bigquery.location", "US"),
                resolve(props, "BIGQUERY_CREDENTIALS", "bigquery.credentials", ""));
    }

    private static String resolve(Properties props, String envName, String propName, String dflt) {
        String env = System.getenv(envName);
        if (env != null && !env.isBlank()) {
            return env;
        }
        return props.getProperty(propName, dflt).strip();
    }

    public BigQuery newClient() {
        return optionsBuilder().build().getService();
    }

    /** The settings every client shares, for callers that need more. */
    public BigQueryOptions.Builder optionsBuilder() {
        BigQueryOptions.Builder builder = BigQueryOptions.newBuilder().setLocation(location);
        if (!project.isEmpty()) {
            builder.setProjectId(project);
        }
        if (!credentials.isEmpty()) {
            try (InputStream in = Files.newInputStream(Path.of(credentials))) {
                builder.setCredentials(GoogleCredentials.fromStream(in));
            } catch (IOException e) {
                throw new IllegalStateException("Unable to read credentials " + credentials, e);
            }
        }
        return builder;
    }

    /**
     * The SQL, with every table reference {@code faa.x} (and {@code faa;}) pointed at the
     * configured dataset, so the same SQL serves a dataset with another name.
     */
    public String sql(String sql) {
        return dataset.equals(SQL_DATASET) ? sql
                : DATASET_REF.matcher(sql).replaceAll(Matcher.quoteReplacement(dataset));
    }

    /** A table named "table" or "faa.table", in the configured dataset. */
    public TableId table(String name) {
        String table = name.startsWith(SQL_DATASET + ".") ? name.substring(SQL_DATASET.length() + 1) : name;
        if (table.contains(".")) {
            throw new IllegalArgumentException("table " + name + ": give it as " + SQL_DATASET + ".<table>");
        }
        return project.isEmpty() ? TableId.of(dataset, table) : TableId.of(project, dataset, table);
    }
}
