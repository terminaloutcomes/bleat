#!/usr/bin/env zsh

set -euo pipefail

readonly script_directory="${0:A:h}"
readonly repository_root="${script_directory:h}"

typeset older_than_days="7"
integer dry_run=0
integer remove_all=0

usage() {
  cat <<'EOF'
Usage: ./scripts/clean-build-artifacts.sh [options]

Remove ignored, repository-owned build artifacts without touching tracked test
fixtures, Git data, or build caches outside the repository.

Options:
  --older-than DAYS  Remove artifacts at least DAYS old (default: 7)
  --all              Remove all artifacts in the known output directories
  --dry-run          Show what would be removed without deleting it
  -h, --help         Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --older-than)
      if (( $# < 2 )); then
        print -u2 -- "--older-than requires a number of days"
        exit 2
      fi
      older_than_days="$2"
      shift 2
      ;;
    --all)
      remove_all=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 -- "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$older_than_days" || "$older_than_days" == *[^0-9]* ]]; then
  print -u2 -- "--older-than must be a non-negative whole number"
  exit 2
fi

readonly cutoff_epoch=$(( $(date +%s) - (older_than_days * 86400) ))
readonly -a artifact_roots=(
  ".build"
  "build"
  "bleat-api/target"
  "TestSupport/ServerHarness/app-live-artifacts"
)

integer removed_count=0
integer reclaimed_kib=0

item_mtime() {
  local item="$1"

  if stat -f '%m' -- "$item" >/dev/null 2>&1; then
    stat -f '%m' -- "$item"
  else
    stat -c '%Y' -- "$item"
  fi
}

item_size_kib() {
  du -sk -- "$1" | awk '{print $1}'
}

remove_item() {
  local relative_path="$1"
  local absolute_path="${repository_root}/${relative_path}"
  integer size_kib

  size_kib="$(item_size_kib "$absolute_path")"
  reclaimed_kib=$(( reclaimed_kib + size_kib ))
  removed_count=$(( removed_count + 1 ))

  if (( dry_run )); then
    print -- "Would remove ${relative_path} ($(du -sh -- "$absolute_path" | awk '{print $1}'))"
    return
  fi

  print -- "Removing ${relative_path} ($(du -sh -- "$absolute_path" | awk '{print $1}'))"
  /bin/rm -rf -- "$absolute_path"
}

for artifact_root in "${artifact_roots[@]}"; do
  absolute_root="${repository_root}/${artifact_root}"
  [[ -d "$absolute_root" && ! -L "$absolute_root" ]] || continue

  while IFS= read -r -d '' artifact; do
    relative_artifact="${artifact#"${repository_root}"/}"

    if (( remove_all )) || (( $(item_mtime "$artifact") <= cutoff_epoch )); then
      remove_item "$relative_artifact"
    fi
  done < <(find "$absolute_root" -mindepth 1 -maxdepth 1 -print0)
done

if (( removed_count == 0 )); then
  print -- "No matching build artifacts found."
  exit 0
fi

reclaimed_mib=$(( reclaimed_kib / 1024 ))
if (( dry_run )); then
  print -- "Would remove ${removed_count} items and reclaim approximately ${reclaimed_mib} MiB."
else
  print -- "Removed ${removed_count} items and reclaimed approximately ${reclaimed_mib} MiB."
fi
