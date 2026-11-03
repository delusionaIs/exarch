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
bash "$ROOT/scripts/enable-multilib.sh" "$conf"
pacman --config "$conf" -Sy >/dev/null
pacman --config "$conf" -Sl multilib 2>/dev/null | grep -q . ||
  echo "warning: multilib repo is empty or missing: $(grep -n multilib "$conf" | tr '\n' ' ')"

hard=0
soft=0
# @aur names: ask the AUR's web API whether the package exists
aur_exists() {
  curl -fsS --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=$1" 2>/dev/null |
    grep -q "\"Name\":\"$1\""
}
check() { # file, strict(1/0)
  local f="$1" strict="$2" pkg
  while read -r pkg; do
    if [[ "$pkg" == *@aur ]]; then
      if command -v curl &>/dev/null && ! aur_exists "${pkg%@aur}"; then
        echo "warning: ${pkg%@aur} not found in the AUR ($(basename "$f")), will be skipped"
        soft=$((soft + 1))
      fi
      continue
    fi
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
