#!/usr/bin/env bash
set -euo pipefail

sample_file=${1:-endpoint-logs.log}
image=${LOGSTASH_IMAGE:-docker.elastic.co/logstash/logstash:8.19.4}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output_file=$(mktemp)
trap 'rm -f "$output_file"' EXIT

docker run --rm -i \
  -v "$script_dir/storagegrid-access.conf:/usr/share/logstash/pipeline/logstash.conf:ro" \
  "$image" --log.level error < "$sample_file" > "$output_file"

total_count=$(wc -l < "$sample_file")
access_count=$(grep -Ec ' (endpoint|mgmt): ' "$sample_file" || true)
parsed_count=$(grep -c '^{' "$output_file" || true)
failure_count=$(grep -Ec '_storagegrid_(endpoint|mgmt)_grok_failure' "$output_file" || true)
ignored_count=$((total_count - access_count))

printf 'input=%d access=%d parsed=%d ignored_non_access=%d failures=%d\n' \
  "$total_count" "$access_count" "$parsed_count" "$ignored_count" "$failure_count"

if ((parsed_count != access_count || failure_count != 0)); then
  exit 1
fi
