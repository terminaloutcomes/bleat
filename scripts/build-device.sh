#!/usr/bin/env bash
set -euo pipefail
exec cargo run --quiet --locked --package scripts --bin build-device
