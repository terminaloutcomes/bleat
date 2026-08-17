#!/usr/bin/env zsh

set -euo pipefail

readonly script_directory="${0:A:h}"
readonly repository_root="${script_directory:h}"

integer dry_run=0

usage() {
  cat <<'EOF'
Usage: ./scripts/clean-build-artifacts.sh [options]

Remove ignored, repository-owned build artifacts without touching tracked test
fixtures, Git data, or build caches outside the repository.

Options:
  --dry-run          Show what would be removed without deleting it
  -h, --help         Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
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

readonly -a artifact_roots=(
  ".build"
  "build"
  "bleat-api/target"
  "TestSupport/ServerHarness/app-live-artifacts"
)

remove_item() {
  local relative_path="$1"
  local absolute_path="${repository_root}/${relative_path}"

  if (( dry_run )); then
    print -- "Would remove ${relative_path}"
    return
  fi
  print -- "Removing ${relative_path}"
  /bin/rm -rf -- "$absolute_path"
}

for artifact_root in "${artifact_roots[@]}"; do
  absolute_root="${repository_root}/${artifact_root}"
  [[ -d "$absolute_root" && ! -L "$absolute_root" ]] || continue

  while IFS= read -r -d '' artifact; do
    relative_artifact="${artifact#"${repository_root}"/}"

    remove_item "$relative_artifact"
  done < <(find "$absolute_root" -mindepth 1 -maxdepth 1 -print0)
done
