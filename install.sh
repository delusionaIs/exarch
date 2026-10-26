#!/usr/bin/env bash
# Run from a clone of this repo on a fresh Arch install:  sudo ./install.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXARCH_DATA="$ROOT" exec bash "$ROOT/airootfs/usr/local/bin/exarch-setup" "$@"
