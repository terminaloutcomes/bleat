#!/bin/sh
set -eu

build_date="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

/usr/libexec/PlistBuddy -c "Set :BleatBuildDate ${build_date}" "${info_plist}"
