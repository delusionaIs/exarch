#!/usr/bin/env bash
# Enable Arch's [multilib] repo in a pacman.conf (default /etc/pacman.conf).
# Uncomments the stock section if it's there; if the layout changed and no
# active [multilib] section exists afterwards, appends one. Safe to run twice.
set -euo pipefail
conf="${1:-/etc/pacman.conf}"

grep -q '^\[multilib\]' "$conf" && exit 0

# stock layout: "#[multilib]" (or "# [multilib]") followed by "#Include = ..."
sed -i -E '/^#[[:space:]]*\[multilib\]/,/^#[[:space:]]*Include/ s/^#[[:space:]]*//' "$conf"

if ! grep -q '^\[multilib\]' "$conf"; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$conf"
fi
