#!/usr/bin/env bash
# show-cluster.sh — render the config for a UC Davis HPC cluster from clusters.yml.
#
# clusters.yml is the single source of truth for per-cluster facts. This script
# extracts a named cluster's block so you (or an agent) can read it without a
# YAML parser. It is read-only and safe to run anywhere, including a login node.
#
# Usage:
#   show-cluster.sh            # list all configured clusters
#   show-cluster.sh hive       # print the hive config block
#
# Resolution: an exact cluster name first, then a match on the login host or an
# alias (e.g. show-cluster.sh hive.hpc.ucdavis.edu resolves to hive).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML="$SELF_DIR/../clusters.yml"

[ -f "$YAML" ] || { echo "clusters.yml not found next to this script: $YAML" >&2; exit 1; }

list_clusters() {
  grep '^  - name:' "$YAML" | sed 's/^  - name: *//; s/ *$//'
}

# Print a cluster's block (from its `- name:` to just before the next one).
print_block() {
  awk -v want="$1" '
    /^  - name: / { cur=$3; if (cur==want) { active=1; print; next } if (active) exit }
    active { print }
  ' "$YAML"
}

# Resolve a query (name, host, or alias) to a canonical cluster name.
resolve() {
  local q="$1" name
  while read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$q" ] && { echo "$name"; return 0; }
  done < <(list_clusters)
  # Not an exact name: find the first block that mentions the query as a host or alias.
  awk -v q="$q" '
    /^  - name: / {
      if (cur != "" && cur_block ~ q) { print cur; found=1; exit }
      cur=$3; cur_block=""
      next
    }
    { cur_block = cur_block "\n" $0 }
    END { if (!found && cur != "" && cur_block ~ q) print cur }
  ' "$YAML"
}

if [ $# -eq 0 ]; then
  echo "Configured UC Davis HPC clusters:"
  list_clusters
  echo
  echo "Usage: show-cluster.sh <cluster>   e.g. show-cluster.sh hive"
  exit 0
fi

name=$(resolve "$1") || true
if [ -z "$name" ]; then
  echo "no cluster matches: $1 (run show-cluster.sh to list)" >&2
  exit 1
fi
print_block "$name"
