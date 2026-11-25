# SGAC Parquet schema history and migration

The current audit and endpoint access schemas are in [README.md](README.md#parquet-schema). This history concerns audit output; endpoint access output has a separate schema.

## Previous audit projection (v0.3.1 through the schema before this change)

The previous audit projection contained:

| Columns | Type | Source |
| --- | --- | --- |
| `source_timestamp` | string | `Timestamp` |
| `atim` | required int64 | `ATIM`, microseconds since Unix epoch |
| `atyp` | required string | `ATYP` |
| `amid`, `rslt` | nullable string | `AMID`, `RSLT` |
| `request_account_id`, `bucket_owner_account_id` | nullable string | `S3AI`, `SBAI` |
| `request_account_name`, `bucket_owner_account_name` | nullable string | `SACC`, `SBAC` |
| `bucket`, `object_key` | nullable string | `S3BK`, `S3KY` |
| `client_ip`, `management_client_ip` | nullable string | `SAIP`, `MSIP` |
| `size` | nullable int64 | `CSIZ` |
| `uuid`, `ilm_rule`, `ilm_status` | nullable string | `UUID`, `RULE`, `STAT` |
| `object_path`, `locations` | nullable string | `PATH`, `LOCS` |
| `raw_json` | string | Parsed event |

The current schema adds nullable `version_id`, `delete_marker_version_id`, and `request_user_urn`. It does not change the separate requester and bucket-owner fields.

## v0.3.0 audit projection

The v0.3.0 README documented the following projection:

| Column | Type | Source |
| --- | --- | --- |
| `timestamp` | string | `Timestamp` |
| `atim` | int64 | `ATIM` |
| `atyp` | string | `ATYP` |
| `amid` | string | `AMID` |
| `rslt` | string | `RSLT` |
| `account_id` | string | `S3AI`, falling back to `SBAI` |
| `tenant_id` | string | `SACC`, falling back to `SBAC` |
| `bucket` | string | `S3BK` |
| `object_key` | string | `S3KY` |
| `client_ip` | string | `SAIP`, falling back to `MSIP` |
| `size` | int64 | `CSIZ` |
| `raw_json` | string | Parsed event |

The fallback columns cannot by themselves distinguish requester from bucket owner or S3 from management client IP. Use the individual fields in `raw_json` when available.

## Migrating audit Parquet

For mixed versions, DuckDB's `read_parquet(..., union_by_name = true)` fills missing columns with `NULL`. It does not populate them from `raw_json`; backfill separately if needed. Keep the original files until the rewritten dataset has been validated.

Export the parsed events as JSONL:

```sql
COPY (
  SELECT raw_json
  FROM read_parquet(
    's3://audit-results/logs/**/*.parquet',
    hive_partitioning = true,
    union_by_name = true
  )
)
TO '/data/sgac-events.jsonl'
(FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');
```

Alternatively, rebuild the current audit projection into a **separate** Parquet file:

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
    json_extract_string(raw_json, '$.SUSR') AS request_user_urn,
    json_extract_string(raw_json, '$.S3BK') AS bucket,
    json_extract_string(raw_json, '$.S3KY') AS object_key,
    json_extract_string(raw_json, '$.VSID') AS version_id,
    json_extract_string(raw_json, '$.DMRK') AS delete_marker_version_id,
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
    hive_partitioning = true,
    union_by_name = true
  )
)
TO '/data/sgac-current-schema.parquet'
(FORMAT PARQUET, COMPRESSION ZSTD);
```

Check `atim` and `atyp` for missing or invalid values before using migrated data: older files may not meet the current required-field rules. The query creates a flat file, not the original partitions or necessarily the exact Parquet required/optional annotations of SGAC output.

`raw_json` is the parsed event, not the original source line. Format 12 omits `CBID`, and selected escaped fields are normalized. Earlier parsers also converted numeric-looking `VSID`, `DMRK`, or `SUSR` values to integers, potentially losing leading zeroes; those cannot be recovered from `raw_json`. Reprocess the original logs when exact recovery is required.

## Interpreting ILM deletes

[IDEL](https://docs.netapp.com/us-en/storagegrid-121/audit/idel-ilm-initiated-delete.html) records the start of an ILM-initiated deletion. For snapshot due diligence, conservatively treat an IDEL affecting a version as globally gone or at risk of being missed, without waiting for ORLM or tracking sites. **This is an analytical assumption, not confirmation of grid-wide physical deletion or site-specific availability.** A delete-marker-creating IDEL can leave the prior version listed as non-current; `DMRK` identifies the new marker, while `VSID` identifies the affected version. `UUID` is a different StorageGRID identifier. The experiment notes from the SGII tool in my `sg-cosi` illustrate these distinctions.

[ORLM](https://docs.netapp.com/us-en/storagegrid-121/audit/orlm-object-rules-met.html) reports an ILM rules-met event; `STAT=PRGD` reports an object deleted from StorageGRID. It can arrive later and is not required by the conservative IDEL assumption. Do not treat every ORLM as a deletion or assume an ORLM by itself proves an ILM-initiated deletion.

For a versioned bucket, query IDEL over the snapshot-to-cutoff interval using `atim` (UTC microseconds), including the `!missing` partition when data is account-partitioned. IDEL often has `PATH` rather than `S3BK`, `S3KY`, or owner identity. Match `object_path` to the base bucket and key, and compare `version_id` with snapshot/version metadata to determine which version was affected. Investigate missing paths or version IDs rather than assuming no match; validate the PATH format for the grid. An ID alone does not determine whether a version was current at snapshot time.

Audit level, collection gaps, parsing errors, retention, and ingestion delays limit assurance. Ensure logs cover the entire interval, allow for late arrivals, and inspect unprocessed-line counts before interpreting no matches as evidence of no deletions.
