#!/usr/bin/env bash
# Check package names still exist in the repos (run on Arch / in the archlinux
# container after the BlackArch repo is set up). Uses a temporary pacman.conf
# with multilib enabled, so the host config is never modified.
#
# STRICT lists (config/packages.iso, packs/desktop.txt, packs/base.txt) are the
# OS itself and mkarchiso dies on a missing name, so those FAIL the check.
# Everything else is best-effort (build.sh / exarch-setup skip missing names),
# so those only WARN. aur-*.txt is skipped (AUR, not in the repos).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

conf="$(mktemp)"
trap 'rm -f "$conf"' EXIT
cp /etc/pacman.conf "$conf"
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$conf"
pacman --config "$conf" -Sy >/dev/null

hard=0
soft=0
check() { # file, strict(1/0)
  local f="$1" strict="$2" pkg
  while read -r pkg; do
    if ! pacman --config "$conf" -Si "$pkg" &>/dev/null && ! pacman --config "$conf" -Sg "$pkg" &>/dev/null; then
      if (( strict )); then
        echo "MISSING  $pkg  ($(basename "$f"))  <- breaks the ISO build"
        hard=$((hard + 1))
      else
        echo "warning: $pkg not found ($(basename "$f")), will be skipped"
        soft=$((soft + 1))
      fi
    fi
  done < <(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$f")
}

for f in "$ROOT/config/packages.iso" "$ROOT/packs/desktop.txt" "$ROOT/packs/base.txt"; do
  check "$f" 1
done
for f in "$ROOT"/packs/*.txt; do
  case "$(basename "$f")" in desktop.txt|base.txt|aur-*.txt) continue ;; esac
  check "$f" 0
done

if (( hard )); then
  echo "$hard ISO package(s) not found, fix these names first" >&2
  exit 1
fi
echo "ISO packages OK ($soft optional package(s) missing)"
