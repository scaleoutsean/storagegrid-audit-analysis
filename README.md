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
./sgac convert --input <input> --output <output> [options]
```

Input may be a local file or `-` for stdin. JSONL may be written to a local file or `-` for stdout. Parquet output must use a file or directory path.

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
  --prefix tenantid \
  --layout prefix-first \
  --log-format 12 \
  --ignore-errors
```

Default layout:

```text
date=YYYY-MM-DD/part-<timestamp>-<random>.parquet
date=YYYY-MM-DD/accountid=<id>/part-<timestamp>-<random>.parquet
date=YYYY-MM-DD/tenantid=<id>/part-<timestamp>-<random>.parquet
```

With `--layout prefix-first`:

```text
accountid=<id>/date=YYYY-MM-DD/part-<timestamp>-<random>.parquet
tenantid=<id>/date=YYYY-MM-DD/part-<timestamp>-<random>.parquet
```

`prefix-first` is useful when tenant or account prefixes are used as object-store access-control boundaries. `date-first` is the default for centralized analytics.

Options:

- `--prefix none|accountid|tenantid` selects optional partitioning. The default is `none`.
- `--layout date-first|prefix-first` controls partition order. `prefix-first` requires `--prefix accountid` or `--prefix tenantid`.
- `--prefix accountid` uses `S3AI`, falling back to `SBAI`.
- `--prefix tenantid` uses the `SACC` tenant/account name, falling back to `SBAC`.
- Missing prefix values are written under `unknown` and counted in the final statistics.
- Partition dates use `ATIM` as a UTC microsecond Unix timestamp, falling back to `Timestamp`.
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
  --prefix tenantid \
  --layout prefix-first \
  --endpoint https://storagegrid.example.com:10443 \
  --force-path-style \
  --log-format 12 \
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

The parser supports StorageGRID log formats 11 and 12. The default is format 12.

It:

- extracts the first timestamp as `Timestamp`
- finds and parses `[AUDT:...]` messages
- removes StorageGRID field type suffixes such as `(CSTR)`, `(UI64)`, and `(FC32)`
- converts ordinary numeric values to integers where possible
- preserves `ATID`, `S3AI`, and `SBAI` as strings to avoid precision loss
- removes `CBID` from format 12 output
- normalizes escaped `SRCF`, `MRBD`, and `MRSP` values to match the existing SGAC behavior

Lines identified as `endpoint:` or `mgmt:` access logs are currently no-op branches. They are skipped and counted; they are not parsed into the output. Access-log parsing remains a separate Logstash concern for now.

Malformed or non-audit lines stop conversion by default. Use `--ignore-errors` to continue and count them as unprocessed lines.

## Parquet schema

Parquet contains a stable analytical projection plus the complete parsed event in `raw_json`:

| Column | Type | Source |
| --- | --- | --- |
| `timestamp` | string | `Timestamp` |
| `atim` | int64 | `ATIM` |
| `atyp` | string | `ATYP` |
| `amid` | string | `AMID` |
| `rslt` | string | `RSLT` |
| `account_id` | string | `S3AI`, fallback `SBAI` |
| `tenant_id` | string | `SACC`, fallback `SBAC` (usually tenant/account name) |
| `bucket` | string | `S3BK` |
| `object_key` | string | `S3KY` |
| `client_ip` | string | `SAIP`, fallback `MSIP` |
| `size` | int64 | `CSIZ` |
| `raw_json` | string | Complete parsed audit record |

The schema is intentionally small and does not discard the other audit fields: they remain available inside `raw_json` for later queries and schema expansion.

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

For physically isolated tenant data, query only that tenant's prefix. This is useful when object-store permissions are assigned per tenant:

```sql
SELECT COUNT(*)
FROM read_parquet('s3://audit-results/logs/tenantid=acme/**/*.parquet', hive_partitioning = true);
```

Replace the example timestamps below with the desired `ATIM` range in microseconds since the Unix epoch. The end of the range is exclusive.

### Client IPs accessing an object

Find unique client IPs that accessed one object for a tenant. Remove the `object_key` predicate to find all client IPs in the tenant and time range.

```sql
SELECT DISTINCT client_ip
FROM read_parquet(
  's3://audit-results/logs/tenantid=acme/**/*.parquet',
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

Group unsuccessful operations by bucket, operation, client IP, and result code:

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

## Output statistics

Each conversion reports:

- total input lines
- successfully parsed audit lines
- skipped endpoint/mgmt access-log lines
- unprocessed lines
- missing partition-prefix values, when applicable
- uploaded Parquet file count and byte count, for S3 output

The Go converter does not currently include a built-in syslog listener or query/report commands.

## Change Log

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
