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
bash "$ROOT/scripts/enable-multilib.sh" /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel git sudo >/dev/null

if ! id builder &>/dev/null; then
  useradd -m builder
  echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
  chmod 440 /etc/sudoers.d/builder
fi

# paru-bin is prebuilt and quick, but breaks whenever pacman bumps libalpm
# before paru-bin is rebuilt. Then fall back to compiling paru from source.
# Checked as the build user: paru refuses some things as root.
paru_ok() {
  command -v paru &>/dev/null || return 1
  local out
  out="$(sudo -u builder paru --version 2>&1)" && return 0
  warn "paru --version: $out"
  return 1
}
if ! paru_ok; then
  for helper in paru-bin paru; do
    log "Bootstrapping $helper"
    # remove a broken helper first (only the ones actually installed)
    mapfile -t old < <(pacman -Qq paru paru-bin paru-bin-debug paru-debug 2>/dev/null || true)
    (( ${#old[@]} )) && pacman -Rdd --noconfirm "${old[@]}" >/dev/null
    sudo -u builder bash -c "
      set -e
      d=\$(mktemp -d); cd \"\$d\"
      git clone --depth 1 https://aur.archlinux.org/$helper.git
      cd $helper && makepkg -si --noconfirm" || true
    paru_ok && break
    warn "$helper doesn't run with this pacman, trying the next option"
  done
  paru_ok || { warn "no working paru: building the ISO without AUR packages"; exit 0; }
fi
log "Using $(sudo -u builder paru --version | head -n1)"

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
if [[ -d /home/builder/.cache/paru/clone ]]; then
  find /home/builder/.cache/paru/clone -name '*.pkg.tar.zst' ! -name '*-debug-*' \
    -exec cp {} "$REPO/" \;
fi

shopt -s nullglob

# Smoke test: a package whose programs can't find their shared libraries
# (like paru-bin after pacman's libalpm .so.15 -> .so.16 bump) must not go
# on the ISO. paru installed everything it built, so check the real files.
broken=()
for f in "$REPO"/*.pkg.tar.zst; do
  name="$(pacman -Qp "$f" 2>/dev/null | awk '{print $1}')" || true
  if [[ -z "$name" ]] || ! pacman -Q "$name" &>/dev/null; then continue; fi
  missing="$(pacman -Qlq "$name" | while read -r bin; do
      [[ -f "$bin" && -x "$bin" ]] || continue
      file -b "$bin" | grep -q '^ELF' || continue
      # static binaries (Go tools) make ldd exit 1: that's fine, not broken
      { ldd "$bin" 2>/dev/null || true; } | awk -v b="$bin" '/not found/ { print b ": " $1 }'
    done | head -n 3)" || true
  if [[ -n "$missing" ]]; then
    warn "$name: missing libraries, left off the ISO: $(tr '\n' ' ' <<<"$missing")"
    broken+=("$name")
    rm -f "$f"
  fi
done
if (( ${#broken[@]} )); then failed+=("${broken[@]}"); fi

files=("$REPO"/*.pkg.tar.zst)
if (( ${#files[@]} == 0 )); then
  warn "nothing built, no local repo created"
  exit 0
fi
repo-add -q "$REPO/exarch-local.db.tar.gz" "${files[@]}"

log "Built: ${built[*]:-none}"
(( ${#failed[@]} )) && warn "Failed: ${failed[*]}"
exit 0
