#!/bin/bash
# Scan for YAML scenario files that haven't been migrated to playbook format.
# Run from any directory — scans the repos passed as arguments.
# Usage: ./scan-unmigrated-yaml.sh /path/to/repo1 /path/to/repo2 ...
#
# A file is "unmigrated" if it:
#   1. Is a .scenario.yaml or .playbook.yaml file
#   2. Does NOT start with 'playbook:'
#
# Also flags stale terminology in docs and comments.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

REPOS="${@}"
if [ -z "${REPOS}" ]; then
  echo "Usage: $0 /path/to/repo1 /path/to/repo2 ..."
  exit 1
fi

echo "=== Unmigrated scenario YAML files ==="
UNMIGRATED=0
MIGRATED=0
for repo in ${REPOS}; do
  repo_name=$(basename "${repo}")
  while IFS= read -r file; do
    first_line=$(head -1 "${file}")
    if echo "${first_line}" | grep -q '^playbook:'; then
      MIGRATED=$((MIGRATED + 1))
    else
      echo -e "  ${RED}unmigrated${NC}: ${repo_name}/$(python3 -c "import os; print(os.path.relpath('${file}', '${repo}'))")"
      UNMIGRATED=$((UNMIGRATED + 1))
    fi
  done < <(find "${repo}" -name "*.scenario.yaml" -o -name "*.playbook.yaml" 2>/dev/null | grep -v '/target/' | grep -v '/node_modules/' | grep -v '/dist/')
done
echo ""
echo -e "  ${GREEN}migrated${NC}: ${MIGRATED}  ${RED}unmigrated${NC}: ${UNMIGRATED}"

echo ""
echo "=== Stale terminology scan ==="
STALE_TERMS=("casehub yaml" "casehub YAML" "step script" "step-script")
for repo in ${REPOS}; do
  repo_name=$(basename "${repo}")
  for term in "${STALE_TERMS[@]}"; do
    count=$(grep -ri "${term}" "${repo}" --include="*.md" --include="*.ts" --include="*.java" --include="*.yaml" -l 2>/dev/null | grep -v '/target/' | grep -v '/node_modules/' | wc -l | tr -d ' ')
    if [ "${count}" -gt 0 ]; then
      echo -e "  ${YELLOW}${term}${NC}: ${count} files in ${repo_name}"
    fi
  done
done
