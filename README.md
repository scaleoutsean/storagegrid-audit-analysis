# StorageGRID Audit-log Converter (Go)

This is the Go version of SGAC, a streaming converter for StorageGRID audit-log entries. 
Due to a poor ROI on time invested, starting from v0.3 SGAC is shared as a binary-only utility.

| Utility | Status |
| :-----  | :----- |
| **sgac** (Go) | Binary-only releases |
| sgac.py | Find the utility and docs in [last Python release](https://github.com/scaleoutsean/storagegrid-audit-analysis/releases/tag/v0.2.4) |

## Usage

The command is:

```sh
./sgac convert --input <input> --output <output> [--type audit|access] [options]
```

Input may be a local file or `-` for stdin. JSONL may be written to a local file or `-` for stdout. Parquet output must use a file or directory path.

`--type audit` is the default and keeps the S3/StorageGRID audit behavior described below. Use `--type access` to parse only `endpoint:` access log rows into a separate schema. In either mode, the other record types are skipped; `mgmt:` parsing is not implemented.

### JSONL

```sh
./sgac convert \
  --input audit.log \
  --output audit.jsonl \
  --format jsonl \
  --log-format 12 \
  --ignore-errors
```

`--format jsonl` is the default. Each parsed audit event is written as one JSON object per line.

### Single Parquet file

```sh
./sgac convert \
  --input audit.log \
  --output audit.parquet \
  --format parquet \
  --log-format 12 \
  --ignore-errors
```

### Partitioned Parquet dataset

An output path that does not end in `.parquet` is treated as a Parquet dataset directory:

```sh
./sgac convert \
  --input audit.log \
  --output ./audit-parquet \
  --format parquet \
  --prefix sacc \
  --layout prefix-first \
  --log-format 12 \
  --ignore-errors
```

Default layout:

```text
date=YYYY-MM-DD/part-<timestamp>-<random>.parquet
date=YYYY-MM-DD/s3ai=<request-account-id>/part-<timestamp>-<random>.parquet
date=YYYY-MM-DD/sbai=<bucket-owner-account-id>/part-<timestamp>-<random>.parquet
date=YYYY-MM-DD/sacc=<request-account-name>/part-<timestamp>-<random>.parquet
date=YYYY-MM-DD/sbac=<bucket-owner-account-name>/part-<timestamp>-<random>.parquet
```

With `--layout prefix-first`:

```text
s3ai=<request-account-id>/date=YYYY-MM-DD/part-<timestamp>-<random>.parquet
sbai=<bucket-owner-account-id>/date=YYYY-MM-DD/part-<timestamp>-<random>.parquet
sacc=<request-account-name>/date=YYYY-MM-DD/part-<timestamp>-<random>.parquet
sbac=<bucket-owner-account-name>/date=YYYY-MM-DD/part-<timestamp>-<random>.parquet
```

`prefix-first` puts the selected source-field value at the root, which can help when designing object-store access-control boundaries. `date-first` is the default for centralized analytics. A prefix is only an event's partition key; it does not prove tenant isolation. Events without that field go under `!missing`, including ILM records such as `ORLM`. Do not grant tenant access to `!missing` without reviewing its contents.

Options:

- `--prefix none|s3ai|sbai|sacc|sbac` selects one exact source field for optional partitioning. The default is `none`.
- `--layout date-first|prefix-first` controls partition order. `prefix-first` requires a non-`none` prefix.
- `s3ai` is the tenant account ID of the user who sent the S3 request.
- `sbai` is the tenant account ID that owns the target bucket.
- `sacc` is the request sender's tenant account name; it is empty for anonymous requests.
- `sbac` is the target bucket owner's tenant account name.
- Missing or empty prefix values are written under `!missing` and counted in the final statistics.
- Values containing characters outside `A-Z`, `a-z`, `0-9`, `.`, `_`, and `-` are encoded as `~` followed by unpadded base64url of the original UTF-8 value. For example, `tenant one` becomes `~dGVuYW50IG9uZQ`. Safe values such as numeric IDs and `acme` remain readable. This encoding is reversible and avoids collisions from replacing characters with underscores.
- Partition dates use required `ATIM`, a UTC microsecond Unix timestamp. Parquet conversion fails if `ATIM` is absent or invalid; it does not substitute the source-line timestamp.
- Part filenames include a timestamp and random suffix so repeated conversions do not overwrite earlier files.

SGAC writes plain Parquet files only. It does not select or manage a lakehouse table format such as Delta, Iceberg, or Hudi.

## S3 output

SGAC writes JSONL or Parquet and can upload Parquet output to S3-compatible storage such as StorageGRID or the [Versity S3 Gateway (VGW)](https://github.com/versity/versitygw) for that because since saving audit logs from a system that needs to be audited to the same system might not be a great idea.

S3 output is currently Parquet-only.

Single object:

```sh
./sgac convert \
  --input audit.log \
  --output s3://audit-results/exports/audit.parquet \
  --format parquet \
  --endpoint https://storagegrid.example.com:10443 \
  --force-path-style \
  --log-format 12 \
  --ignore-errors
```

Partitioned dataset:

```sh
./sgac convert \
  --input audit.log \
  --output s3://audit-results/logs \
  --format parquet \
  --prefix sacc \
  --layout prefix-first \
  --endpoint https://storagegrid.example.com:10443 \
  --force-path-style \
  --log-format 12 \
  --ignore-errors
```

Endpoint access dataset:

```sh
./sgac convert \
  --input mixed-syslog.log \
  --output s3://audit-results/endpoint-access \
  --type access \
  --format parquet \
  --endpoint https://storagegrid.example.com:10443 \
  --force-path-style \
  --ignore-errors
```

Parquet files are first written to a temporary local staging directory. Files are uploaded only after they are closed successfully. S3 dataset uploads preserve the local relative partition paths.

S3 settings may be provided as flags or environment variables:

| Flag | Environment variable | Default |
| --- | --- | --- |
| `--region` | `AWS_REGION` | `us-east-1` |
| `--endpoint` | `S3_ENDPOINT` | empty |
| `--profile` | `AWS_PROFILE` | empty |
| `--access-key-id` | `AWS_ACCESS_KEY_ID` | empty |
| `--secret-access-key` | `AWS_SECRET_ACCESS_KEY` | empty |
| `--force-path-style` |  | `true` |
| `--insecure-tls` |  | `false` |

Use `--insecure-tls` only when intentionally connecting to an endpoint with an untrusted certificate.

## Temporary staging space

S3 output checks the staging filesystem before parsing and every 100,000 input records by default. It stops before uploading if the filesystem reaches 95% usage.

```text
--temp-dir <path>
--temp-max-used-percent 95
--temp-check-interval 100000
```

The default temp directory is selected in this order:

```text
SGAC_TEMP_DIR -> TEMP_DIR -> operating-system temp directory
```

The check interval is configurable for workloads with unusually large records or limited local storage.

## Parsed audit data

The parser supports StorageGRID log formats 11 and 12. The default is format 12. Every parsed audit entry must contain a valid integer `ATIM` and a non-empty `ATYP`; entries missing either are malformed for both JSONL and Parquet output.

It:

- extracts the first timestamp as `Timestamp`
- finds and parses `[AUDT:...]` messages
- removes StorageGRID field type suffixes such as `(CSTR)`, `(UI64)`, and `(FC32)`
- converts ordinary numeric values to integers where possible
- preserves `ATID`, `S3AI`, and `SBAI` as strings to avoid precision loss
- removes `CBID` from format 12 output
- normalizes escaped `SRCF`, `MRBD`, and `MRSP` values to match the existing SGAC behavior

In the default `--type audit` mode, `endpoint:` and `mgmt:` access rows are skipped and counted. With `--type access`, endpoint rows are parsed instead; audit and `mgmt:` rows are skipped. Management access-log parsing remains out of scope.

On the refreshed `s3-all.log`, access mode parsed 253,457 endpoint rows, skipped 332,091 audit/management rows, and found no malformed endpoint rows. Of the endpoint rows, 16,490 have HTTP status 400 or greater; status alone does not explain the failure cause.

Malformed or non-audit lines stop conversion by default. Use `--ignore-errors` to continue and count them as unprocessed lines.

No `ATYP` event types are filtered from Parquet output. The refreshed `s3-all.log` contains 585,548 lines: 265,320 audit entries, 253,457 endpoint access-log lines, and 66,771 management access-log lines. In default `--type audit` mode, endpoint and management lines are skipped; all audit event types present in the file are retained. With `--ignore-errors`, malformed lines in the selected type are counted as unprocessed.

The following 17 `ATYP` values were observed in `s3-all.log`. Counts are specific to this sample, not an exhaustive StorageGRID event-type registry.

| `ATYP` | Sample count | Meaning |
| --- | ---: | --- |
| `SGET` | 198,859 | S3 GET |
| `ORLM` | 21,820 | Object Rules Met; ILM rule satisfied |
| `SPUT` | 20,350 | S3 PUT |
| `SDEL` | 17,999 | S3 DELETE |
| `SHEA` | 4,074 | S3 HEAD |
| `MGAU` | 801 | Management audit message |
| `SPOS` | 537 | S3 POST |
| `OVWR` | 421 | Object Overwrite |
| `ASRO` | 147 | Observed in sample; retained without interpretation |
| `ETAF` | 146 | Security Authentication Failed |
| `SYSU` | 56 | Node Start |
| `SYST` | 40 | Node Stopping |
| `SYSD` | 40 | Node Stop |
| `LKCU` | 23 | Observed in sample; retained without interpretation |
| `IDEL` | 3 | ILM Initiated Delete |
| `SUPD` | 2 | S3 metadata or bucket compliance update |
| `EBDL` | 2 | Observed in sample; retained without interpretation |

Every audit record is retained in `--type audit` regardless of `ATYP`. S3 request types carry requester/bucket-owner fields; ILM events such as `ORLM` instead carry fields such as `RULE`, `STAT`, `PATH`, `LOCS`, `UUID`, and `CSIZ`. Identity columns are therefore null for those events rather than populated from unrelated fields.

## Parquet schema

Parquet contains a typed analytical projection plus the complete parsed event in `raw_json`. Optional source fields become Parquet `NULL` when absent. Empty source values remain empty strings; they are not substituted from another field.

| Column | Type | Source |
| --- | --- | --- |
| `source_timestamp` | string | First timestamp token on the input line; may be the syslog timestamp |
| `atim` | int64, required | `ATIM`, event time in microseconds since Unix epoch |
| `atyp` | string, required | `ATYP`, event type |
| `amid` | nullable string | `AMID` |
| `rslt` | nullable string | `RSLT` |
| `request_account_id` | nullable string | `S3AI`, request sender's tenant account ID |
| `bucket_owner_account_id` | nullable string | `SBAI`, target bucket owner's tenant account ID |
| `request_account_name` | nullable string | `SACC`, request sender's tenant account name |
| `bucket_owner_account_name` | nullable string | `SBAC`, target bucket owner's tenant account name |
| `bucket` | nullable string | `S3BK` |
| `object_key` | nullable string | `S3KY`; not present on bucket-only requests |
| `client_ip` | nullable string | `SAIP`, S3 request sender address |
| `management_client_ip` | nullable string | `MSIP`, management request client address |
| `size` | nullable int64 | `CSIZ`; absence remains `NULL`, not zero |
| `uuid` | nullable string | `UUID` |
| `ilm_rule` | nullable string | `RULE` |
| `ilm_status` | nullable string | `STAT` |
| `object_path` | nullable string | `PATH` |
| `locations` | nullable string | `LOCS` |
| `raw_json` | string | Complete parsed audit record |

`S3AI`/`SACC` describe the request sender. `SBAI`/`SBAC` describe the target bucket owner and can differ for cross-account access. `SAIP` and `MSIP` belong to different event families and are not merged. Other source fields remain available in `raw_json`; the typed columns are a convenience projection, not a field whitelist.

### Endpoint access schema (`--type access`)

Endpoint access output uses a separate schema and is not mixed with audit rows. Directory Parquet output is partitioned by UTC date from `access_timestamp`; audit identity `--prefix` values are not supported because endpoint rows do not contain an authoritative tenant/account identity.

| Column | Type | Source |
| --- | --- | --- |
| `syslog_timestamp` | string | Timestamp at the start of the source line |
| `node` | string | StorageGRID node name |
| `access_timestamp` | string | Timestamp inside the `endpoint:` record |
| `remote_addr` | string | Client address as logged by the endpoint |
| `status` | int64 | HTTP status |
| `bytes_sent` | int64 | Response bytes logged by the endpoint |
| `request_length` | int64 | Request length logged by the endpoint |
| `request_time` | float64 | Endpoint request duration in seconds |
| `endpoint_id` | nullable string | Endpoint UUID; absent before endpoint selection |
| `upstream_addr` | nullable string | Backend StorageGRID address; absent when no upstream was selected |
| `request` | string | Request line, including path and query string |
| `http_host` | nullable string | HTTP Host value; `-` is represented as `NULL` |
| `raw_line` | string | Complete original endpoint log line |

For mixed log files, access mode skips audit and management rows. Malformed endpoint rows fail by default or are counted as unprocessed with `--ignore-errors`. Request paths and query strings can contain sensitive data. `remote_addr` is the address recorded by StorageGRID and should not automatically be treated as the originating client when proxies/load balancers are involved. HTTP status alone does not identify why a request failed or prove an S3 key is stale.

Example local conversion:

```sh
./sgac convert \
  --input mixed-syslog.log \
  --output ./endpoint-access \
  --type access \
  --format parquet \
  --ignore-errors
```

## Migrating Parquet schemas

Because each Parquet row stores its parsed audit event in `raw_json`, DuckDB can export those events or build a new projection without the original audit files.

Export one standalone JSON object per line to an intermediate file:

```sql
COPY (
  SELECT raw_json
  FROM read_parquet(
    's3://audit-results/logs/**/*.parquet',
    hive_partitioning = true
  )
)
TO '/data/sgac-events.jsonl'
(FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');
```

The single unquoted column contains the JSON text itself. The resulting JSONL can be reparsed with `read_json_auto` or another JSONL tool.

Alternatively, extract the fields needed by a revised schema and write new Parquet directly:

```sql
COPY (
  SELECT
    json_extract_string(raw_json, '$.Timestamp') AS source_timestamp,
    TRY_CAST(json_extract_string(raw_json, '$.ATIM') AS BIGINT) AS atim,
    json_extract_string(raw_json, '$.ATYP') AS atyp,
    json_extract_string(raw_json, '$.AMID') AS amid,
    json_extract_string(raw_json, '$.RSLT') AS rslt,
    json_extract_string(raw_json, '$.S3AI') AS request_account_id,
    json_extract_string(raw_json, '$.SBAI') AS bucket_owner_account_id,
    json_extract_string(raw_json, '$.SACC') AS request_account_name,
    json_extract_string(raw_json, '$.SBAC') AS bucket_owner_account_name,
    json_extract_string(raw_json, '$.S3BK') AS bucket,
    json_extract_string(raw_json, '$.S3KY') AS object_key,
    json_extract_string(raw_json, '$.SAIP') AS client_ip,
    json_extract_string(raw_json, '$.MSIP') AS management_client_ip,
    TRY_CAST(json_extract_string(raw_json, '$.CSIZ') AS BIGINT) AS size,
    json_extract_string(raw_json, '$.UUID') AS uuid,
    json_extract_string(raw_json, '$.RULE') AS ilm_rule,
    json_extract_string(raw_json, '$.STAT') AS ilm_status,
    json_extract_string(raw_json, '$.PATH') AS object_path,
    json_extract_string(raw_json, '$.LOCS') AS locations,
    raw_json
  FROM read_parquet(
    's3://audit-results/logs/**/*.parquet',
    hive_partitioning = true
  )
)
TO '/data/sgac-schema-vnext.parquet'
(FORMAT PARQUET, COMPRESSION ZSTD);
```

`raw_json` is the complete **parsed** event, not the original source line. The parser intentionally omits `CBID` for log format 12 and normalizes selected escaped fields. Keep the original audit logs if future migrations may need to recover omitted fields, change parsing behavior, or reproduce the original source text.

## Query examples

The examples below use DuckDB and an S3-backed Parquet dataset. Configure the S3-compatible endpoint once for the DuckDB session; use your normal credential-chain or secret-management approach for credentials:

```sql
INSTALL httpfs;
LOAD httpfs;

CREATE SECRET sgac_s3 (
  TYPE S3,
  PROVIDER CREDENTIAL_CHAIN,
  ENDPOINT 'storagegrid.example.com:10443',
  REGION 'us-east-1',
  URL_STYLE 'path',
  USE_SSL true
);
```

For centralized data, query the complete dataset:

```sql
SELECT COUNT(*)
FROM read_parquet('s3://audit-results/logs/**/*.parquet', hive_partitioning = true);
```

For data partitioned by request-sender account name, query only that exact `SACC` prefix. Use `SBAC` instead when the intended grouping is the target bucket owner:

```sql
SELECT COUNT(*)
FROM read_parquet('s3://audit-results/logs/sacc=acme/**/*.parquet', hive_partitioning = true);
```

Replace the example timestamps below with the desired `ATIM` range in microseconds since the Unix epoch. The end of the range is exclusive.

### Client IPs accessing an object

Find unique client IPs that accessed one object for a tenant. Remove the `object_key` predicate to find all client IPs in the tenant and time range.

```sql
SELECT DISTINCT client_ip
FROM read_parquet(
  's3://audit-results/logs/sacc=acme/**/*.parquet',
  hive_partitioning = true
)
WHERE atyp IN ('SGET', 'SPUT', 'SDEL')
  AND object_key = 'reports/monthly.csv'
  AND atim >= 1725148800000000
  AND atim <  1727740800000000
ORDER BY client_ip;
```

### Total S3 egress

Calculate logical bytes associated with successful GET events, optionally narrowed to a bucket:

```sql
SELECT
  COALESCE(SUM(size), 0) AS total_egress_bytes,
  COUNT(*) AS get_requests
FROM read_parquet(
  's3://audit-results/logs/**/*.parquet',
  hive_partitioning = true
)
WHERE atyp = 'SGET'
  AND rslt = 'SUCS'
  AND atim >= 1725148800000000
  AND atim <  1727740800000000
  AND bucket = 'customer-data';
```

Remove the `bucket` predicate for a global summary, or query a tenant prefix to scope the summary physically.

### Failed operations

Group unsuccessful S3 API operations by bucket, operation, client IP, and result code:

```sql
SELECT
  bucket,
  atyp,
  client_ip,
  rslt,
  COUNT(*) AS failures
FROM read_parquet(
  's3://audit-results/logs/**/*.parquet',
  hive_partitioning = true
)
WHERE rslt <> 'SUCS'
GROUP BY bucket, atyp, client_ip, rslt
ORDER BY failures DESC;
```

### Request volume by bucket

Summarize request counts and recorded bytes by bucket and operation:

```sql
SELECT
  bucket,
  atyp,
  COUNT(*) AS requests,
  COALESCE(SUM(size), 0) AS bytes
FROM read_parquet(
  's3://audit-results/logs/**/*.parquet',
  hive_partitioning = true
)
WHERE atyp IN ('SGET', 'SPUT', 'SDEL')
GROUP BY bucket, atyp
ORDER BY requests DESC;
```

The `size` value for `SGET` is the logical content size recorded in the audit event. It is not necessarily wire-level network traffic after retries, encryption, protocol overhead, or range-request behavior.

### Endpoint access log queries

These examples use the separate dataset written with `--type access`:
`s3://audit-results/endpoint-access/`. They use `access_timestamp` for a rolling 24-hour window. Query strings are omitted from the displayed path because they may contain sensitive parameters.

#### Clients receiving failed responses in the last 24 hours

This groups failed requests by client IP, status, and path. It includes 4xx responses such as 400/404/401 and 5xx responses; status 499 is also included if present.

```sql
WITH recent_failures AS (
  SELECT
    remote_addr,
    status,
    regexp_extract(request, '^[A-Z]+[ ]+([^? ]+)', 1) AS path
  FROM read_parquet(
    's3://audit-results/endpoint-access/**/*.parquet',
    hive_partitioning = true
  )
  WHERE TRY_CAST(access_timestamp AS TIMESTAMPTZ) >= current_timestamp - INTERVAL '24 hours'
    AND status >= 400
    AND status < 600
)
SELECT remote_addr, status, path, COUNT(*) AS failed_requests
FROM recent_failures
GROUP BY remote_addr, status, path
ORDER BY failed_requests DESC;
```

#### Locate endpoint or upstream nodes with elevated 5xx responses

Compare HTTP Host, endpoint UUID, and selected upstream. This helps distinguish a problem concentrated on one endpoint or backend from errors spread across the service. Client-aborted 499 responses are not counted as server errors here.

```sql
WITH recent AS (
  SELECT http_host, endpoint_id, upstream_addr, status, request_time
  FROM read_parquet(
    's3://audit-results/endpoint-access/**/*.parquet',
    hive_partitioning = true
  )
  WHERE TRY_CAST(access_timestamp AS TIMESTAMPTZ) >= current_timestamp - INTERVAL '24 hours'
)
SELECT
  COALESCE(http_host, '(unavailable)') AS http_host,
  COALESCE(endpoint_id, '(unavailable)') AS endpoint_id,
  COALESCE(upstream_addr, '(unavailable)') AS upstream_addr,
  COUNT(*) AS requests,
  COUNT_IF(status >= 500 AND status < 600) AS server_errors,
  ROUND(100.0 * COUNT_IF(status >= 500 AND status < 600) / COUNT(*), 2) AS server_error_percent,
  QUANTILE_CONT(request_time, 0.95) AS p95_request_time_seconds
FROM recent
GROUP BY http_host, endpoint_id, upstream_addr
HAVING COUNT_IF(status >= 500 AND status < 600) > 0
ORDER BY server_errors DESC;
```

## Output statistics

Each conversion reports:

- total input lines
- successfully parsed records of the selected `--type`
- lines of other record types skipped (`endpoint`/`mgmt` in audit mode; audit/`mgmt` in access mode)
- unprocessed lines
- missing partition-prefix values in audit mode, when applicable
- uploaded Parquet file count and byte count, for S3 output

The Go converter does not currently include a built-in syslog listener or query/report commands.

## Change Log

- v0.4.0 (2026/10/02)
  - New: mode for StorageGRID access log parsing (requires StorageGRID access logs to be forwarded)

- v0.3.1 (2026/09/28)
  - Changed: Parquet schema for accuracy and usability. Instructions for converting old to new Parquet files are included in README.md

- v0.3.0 (2026/09/20)
  - Changed: uses Go. The source code is no longer distributed to decrease maintainer's effort
  - New: flexible Parquet output option, optional output segregation, optional output to S3

- v0.2.4 (2026/09/14)
  - Changed: skip non-Audit log messages from StorageGRID log in case access and management log entries are included the file (previously parsing those lines would simply fail, causing no harm)
  - New: add simple access log parser for out-of-scope access logs (generated and potentially logged by NGINX S3 API gateway(s)). Potentially useful when forwarding from syslog server to SIEM, as here we don't do anything with them

- v0.2.3 (2026/07/13)
  - New: may survive encounters with StorageGRID audit log version 12
  - New: `--log-format`. Default: 12
  - New: `--validate-json`. Default: disabled
  - New: captures `UUID` field from log version 12

- v0.2.2 (2021/12/26)
  - Strip existing JSON escapes from nested JSON in audit log before converting log to JSON in SGAC

- v0.2.1 (2021/10/20)
  - Force-convert ATID value to string

- v0.2 (2021/10/20)
  - Force-convert S3AI and SBAI values to string

- v0.1 (2021/08/08)
  - Now converts to JSON
  - Options and "modes" removed
  - Seems to successfully convert all lines to JSON (tested with 350K lines of audit logs from StorageGIRD v11.5, including Object Lock logs)

- 2021/06/24
  - Add details about management and access logs
  - Update links to StorageGRID v11.5 and note new fields added in 11.5
  - Add one code (MTME) to the Python script

- 2020/11/03
  - Add SQL queries to illustrate reports that can be obtained from `showback`-mode CSV
  - Clarify more precisely about MRSP parsing

- 2020/11/02
  - Add `--data showback` option to extract to CSV a smaller subset of data and only rows related to main S3 and ILM operations

- 2020/11/01
  - Add about 10 new keys/fields that have appeared since the original Python script was released
  - Silently drop MRSP key-value pairs because the script cannot handle them
  - Add debug_file argument for issues (except MRSP) with log parsing
  - Minor changes to the script
