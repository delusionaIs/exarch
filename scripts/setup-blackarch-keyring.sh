#!/usr/bin/env bash
# Add the BlackArch repo + signing key to this machine using BlackArch's
# official strap.sh. Safe to run twice.
#
# Supply-chain note: set BLACKARCH_STRAP_SHA256 to the checksum published on
# https://blackarch.org/downloads.html#install-repo and the script refuses to
# run a strap.sh that doesn't match. Without it, the hash is printed so you
# can compare by hand.
set -euo pipefail

if pacman -Q blackarch-keyring &>/dev/null && grep -q '^\[blackarch\]' /etc/pacman.conf; then
  echo "BlackArch repo already set up"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL https://blackarch.org/strap.sh -o "$tmp/strap.sh"
actual="$(sha256sum "$tmp/strap.sh" | cut -d' ' -f1)"
echo "strap.sh sha256: $actual"

if [[ -n "${BLACKARCH_STRAP_SHA256:-}" ]]; then
  if [[ "$actual" != "$BLACKARCH_STRAP_SHA256" ]]; then
    echo "strap.sh checksum mismatch, refusing to run it" >&2
    exit 1
  fi
  echo "checksum verified"
else
  echo "warning: BLACKARCH_STRAP_SHA256 not set, checksum not verified" >&2
fi

bash "$tmp/strap.sh"
