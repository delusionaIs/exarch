#!/usr/bin/env bash
# Build the ISO from any machine with Docker (Linux, or Windows via Docker
# Desktop + WSL2). Output lands in ./out.
#   SKIP_AUR=1 ./scripts/build-in-docker.sh   # faster, no Noctalia/AUR tools
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

aur_step='bash scripts/build-aur-repo.sh'
[[ "${SKIP_AUR:-0}" == 1 ]] && aur_step='true'

docker run --rm --privileged \
  -e BLACKARCH_STRAP_SHA256="${BLACKARCH_STRAP_SHA256:-}" \
  -v "$ROOT":/repo -w /repo \
  archlinux:latest \
  bash -c "pacman -Syu --noconfirm --needed archiso git && $aur_step && bash ./build.sh"
