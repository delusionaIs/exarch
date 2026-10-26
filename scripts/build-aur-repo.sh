#!/usr/bin/env bash
# Build the AUR packages in packs/aur-core.txt (plus their AUR dependencies)
# into a local pacman repo that build.sh puts on the ISO.
#
# Runs as root in a throwaway Arch container: creates an unprivileged
# "builder" user (makepkg refuses root), bootstraps paru, builds everything.
# A package that fails to build is skipped, never fatal.
#
# Supply-chain note: this executes AUR PKGBUILDs. Keep the list short, prefer
# -bin packages from upstream releases, and review PKGBUILD diffs on updates.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${LOCALREPO:-$ROOT/work/localrepo}"

log()  { printf '\e[1;35m[aur]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[aur]\e[0m %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || { echo "run as root (in the build container)" >&2; exit 1; }

# multilib for any lib32 deps
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel git sudo >/dev/null

if ! id builder &>/dev/null; then
  useradd -m builder
  echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
  chmod 440 /etc/sudoers.d/builder
fi

if ! command -v paru &>/dev/null; then
  log "Bootstrapping paru"
  sudo -u builder bash -c '
    set -e
    d=$(mktemp -d); cd "$d"
    git clone --depth 1 https://aur.archlinux.org/paru-bin.git
    cd paru-bin && makepkg -si --noconfirm'
fi

mapfile -t pkgs < <(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$ROOT/packs/aur-core.txt")
built=(); failed=()
for pkg in "${pkgs[@]}"; do
  log "Building $pkg"
  if sudo -u builder paru -S --noconfirm --needed --skipreview \
       --mflags "--skippgpcheck --nocheck" "$pkg"; then
    built+=("$pkg")
  else
    warn "$pkg failed to build, skipping"
    failed+=("$pkg")
  fi
done

log "Collecting packages into $REPO"
rm -rf "$REPO"
mkdir -p "$REPO"
find /home/builder/.cache/paru/clone -name '*.pkg.tar.zst' ! -name '*-debug-*' \
  -exec cp {} "$REPO/" \;

shopt -s nullglob
files=("$REPO"/*.pkg.tar.zst)
if (( ${#files[@]} == 0 )); then
  warn "nothing built, no local repo created"
  exit 0
fi
repo-add -q "$REPO/exarch-local.db.tar.gz" "${files[@]}"

log "Built: ${built[*]:-none}"
(( ${#failed[@]} )) && warn "Failed: ${failed[*]}"
exit 0
