#!/bin/sh
set -eu

build_date="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if ! build_commit="$(/usr/bin/git -C "${SRCROOT}" rev-parse --short=8 --verify HEAD 2>/dev/null)"; then
  echo "error: Could not determine the Git commit for this build." >&2
  exit 1
fi

if [ "${#build_commit}" -lt 8 ]; then
  echo "error: Git returned an invalid short commit for this build." >&2
  exit 1
fi

case "${build_commit}" in
  *[!0-9a-fA-F]*)
    echo "error: Git returned an invalid short commit for this build." >&2
    exit 1
    ;;
esac

/usr/libexec/PlistBuddy -c "Set :BleatBuildDate ${build_date}" "${info_plist}"
/usr/libexec/PlistBuddy -c "Set :BleatGitCommit ${build_commit}" "${info_plist}"
