#!/bin/sh
set -eu

build_date="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
build_commit="$(/usr/bin/git -C "${SRCROOT}" rev-parse --verify HEAD 2>/dev/null || true)"
info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

case "${build_commit}" in
  [0-9a-fA-F][0-9a-fA-F]*) ;;
  *) build_commit="Unavailable" ;;
esac

/usr/libexec/PlistBuddy -c "Set :BleatBuildDate ${build_date}" "${info_plist}"
/usr/libexec/PlistBuddy -c "Set :BleatGitCommit ${build_commit}" "${info_plist}"
