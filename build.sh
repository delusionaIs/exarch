#!/usr/bin/env bash
# Build the Exarch live ISO. Must run as root on Arch (or in the archlinux
# Docker image: see scripts/build-in-docker.sh).
#
# How it works: copy Arch's official "releng" archiso profile, then layer our
# packages, repos, branding and files on top. We never fork releng, so every
# build picks up upstream fixes automatically.
#
# Package lists:
#   STRICT       config/packages.iso, packs/desktop.txt, packs/base.txt
#                (a missing name fails the build: these are the OS itself)
#   BEST-EFFORT  packs/core-tools.txt (missing names are dropped with a warning)
#   LOCAL REPO   packs/aur-core.txt, prebuilt by scripts/build-aur-repo.sh into
#                $LOCALREPO; whatever built successfully goes on the ISO
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/distro.env
source "$ROOT/config/distro.env"

WORK="${WORK:-$ROOT/work}"
OUT="${OUT:-$ROOT/out}"
LOCALREPO="${LOCALREPO:-$WORK/localrepo}"
PROFILE="$WORK/profile"
AIROOT="$PROFILE/airootfs"

log()  { printf '\e[1;35m[%s]\e[0m %s\n' "$DISTRO_NAME" "$*"; }
warn() { printf '\e[1;33m[%s]\e[0m %s\n' "$DISTRO_NAME" "$*" >&2; }
clean_list() { sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$@"; }

[[ $EUID -eq 0 ]] || { echo "build.sh must run as root" >&2; exit 1; }

log "Installing build tools"
pacman -Sy --noconfirm --needed archiso git >/dev/null

log "Trusting the BlackArch repo on the build host"
bash "$ROOT/scripts/setup-blackarch-keyring.sh"

log "Copying Arch releng profile"
rm -rf "$PROFILE"
mkdir -p "$PROFILE" "$OUT"
cp -a /usr/share/archiso/configs/releng/. "$PROFILE/"

log "Repos: multilib + BlackArch (+ local AUR repo if built)"
bash "$ROOT/scripts/enable-multilib.sh" "$PROFILE/pacman.conf"
cat "$ROOT/config/pacman.blackarch.conf" >> "$PROFILE/pacman.conf"
have_localrepo=0
if [[ -f "$LOCALREPO/exarch-local.db.tar.gz" ]]; then
  have_localrepo=1
  cat >> "$PROFILE/pacman.conf" <<EOF

[exarch-local]
SigLevel = Optional TrustAll
Server = file://$LOCALREPO
EOF
else
  warn "No local AUR repo at $LOCALREPO (run scripts/build-aur-repo.sh). Noctalia + AUR tools skipped; niri uses the fallback bar."
fi
pacman --config "$PROFILE/pacman.conf" -Sy >/dev/null

available() {
  pacman --config "$PROFILE/pacman.conf" -Si "$1" &>/dev/null ||
    pacman --config "$PROFILE/pacman.conf" -Sg "$1" &>/dev/null
}

log "Merging package lists"
{
  cat "$PROFILE/packages.x86_64"
  clean_list "$ROOT/config/packages.iso" "$ROOT/packs/desktop.txt" "$ROOT/packs/base.txt"

  while read -r pkg; do
    if available "$pkg"; then echo "$pkg"; else warn "core-tools: '$pkg' not in any repo, skipped"; fi
  done < <(clean_list "$ROOT/packs/core-tools.txt")

  if (( have_localrepo )); then
    while read -r pkg; do
      if pacman --config "$PROFILE/pacman.conf" -Si "exarch-local/$pkg" &>/dev/null; then
        echo "$pkg"
      else
        warn "aur-core: '$pkg' wasn't built, skipped"
      fi
    done < <(clean_list "$ROOT/packs/aur-core.txt")
  fi
} | clean_list /dev/stdin | sort -u > "$PROFILE/packages.tmp"
mv "$PROFILE/packages.tmp" "$PROFILE/packages.x86_64"
log "$(wc -l < "$PROFILE/packages.x86_64") packages on the ISO"

log "Swapping releng networking for NetworkManager"
find "$AIROOT/etc/systemd/system" \( -name 'systemd-networkd*' -o -name 'iwd.service' \) -delete
mkdir -p "$AIROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/NetworkManager.service \
  "$AIROOT/etc/systemd/system/multi-user.target.wants/NetworkManager.service"

log "Applying Exarch overlay"
cp -a "$ROOT/airootfs/." "$AIROOT/"
mkdir -p "$AIROOT/usr/share/$DISTRO_ID"
cp -a "$ROOT/branding" "$ROOT/packs" "$ROOT/airootfs" "$ROOT/scripts" "$ROOT/config" "$ROOT/rust" "$ROOT/wallpapers" \
  "$AIROOT/usr/share/$DISTRO_ID/"
rm -rf "$AIROOT/usr/share/$DISTRO_ID/branding/explorations" "$AIROOT/usr/share/$DISTRO_ID/rust/exarch-splash/target"

log "Building exarch-splash (Rust): 3D logo for terminals + live wallpaper"
have_splash=0
if pacman -S --needed --noconfirm rust >/dev/null &&
   cargo build --release --locked --manifest-path "$ROOT/rust/exarch-splash/Cargo.toml" --target-dir "$WORK/cargo"; then
  install -Dm755 "$WORK/cargo/release/exarch-splash" "$AIROOT/usr/local/bin/exarch-splash"
  have_splash=1
else
  warn "exarch-splash didn't build: the ISO uses the Python splash and a static wallpaper"
fi

log "Services: greetd, GPU detection, live user, graphical boot"
wants="$AIROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/greetd.service "$AIROOT/etc/systemd/system/display-manager.service"
ln -sf /etc/systemd/system/exarch-live-user.service "$wants/exarch-live-user.service"
ln -sf /etc/systemd/system/exarch-gpu-detect.service "$wants/exarch-gpu-detect.service"
ln -sf /usr/lib/systemd/system/graphical.target "$AIROOT/etc/systemd/system/default.target"
ln -sf /usr/lib/systemd/system/systemd-oomd.service "$wants/systemd-oomd.service"

log "Branding the profile"
iso_label="${DISTRO_ID^^}_$(date +%Y%m)"
sed -i \
  -e "s|^iso_name=.*|iso_name=\"$DISTRO_ID\"|" \
  -e "s|^iso_label=.*|iso_label=\"$iso_label\"|" \
  -e "s|^iso_publisher=.*|iso_publisher=\"$DISTRO_PUBLISHER\"|" \
  -e "s|^iso_application=.*|iso_application=\"$DISTRO_NAME Live\"|" \
  "$PROFILE/profiledef.sh"
{
  echo 'file_permissions+=('
  for f in "$ROOT"/airootfs/usr/local/bin/*; do
    echo "  [\"/usr/local/bin/$(basename "$f")\"]=\"0:0:755\""
  done
  (( have_splash )) && echo '  ["/usr/local/bin/exarch-splash"]="0:0:755"'
  echo ')'
} >> "$PROFILE/profiledef.sh"

log "Boot menu: default, safe graphics, rescue"
SAFE_ARGS="exarch.safe module_blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm"
RESCUE_ARGS="nomodeset exarch.safe systemd.unit=multi-user.target"

# UEFI via systemd-boot: clone the main entry
entries="$PROFILE/efiboot/loader/entries"
if [[ -d "$entries" ]]; then
  main="$(find "$entries" -name '*.conf' ! -name '*speech*' ! -name '*memtest*' | sort | head -n1)"
  if [[ -n "$main" ]]; then
    sed -e "s/^title .*/title    $DISTRO_NAME (safe graphics)/" -e "s/^sort-key .*/sort-key 90/" \
        -e "/^options/ s/\$/ $SAFE_ARGS/" "$main" > "$entries/90-exarch-safe.conf"
    sed -e "s/^title .*/title    $DISTRO_NAME (rescue, text mode)/" -e "s/^sort-key .*/sort-key 91/" \
        -e "/^options/ s/\$/ $RESCUE_ARGS/" "$main" > "$entries/91-exarch-rescue.conf"
  fi
fi

# UEFI/BIOS via GRUB: duplicate the first menuentry block
for cfg in "$PROFILE/grub/grub.cfg" "$PROFILE/grub/loopback.cfg"; do
  [[ -f "$cfg" ]] || continue
  awk -v t1="$DISTRO_NAME (safe graphics)" -v p1="$SAFE_ARGS" \
      -v t2="$DISTRO_NAME (rescue, text mode)" -v p2="$RESCUE_ARGS" '
    { print }
    !done && /^menuentry / { inblk = 1 }
    inblk { blk = blk $0 "\n" }
    inblk && /^}/ { inblk = 0; done = 1 }
    END {
      if (blk == "") exit
      n = split(blk, L, "\n")
      for (k = 1; k <= 2; k++) {
        t = (k == 1) ? t1 : t2; p = (k == 1) ? p1 : p2
        print ""
        for (i = 1; i < n; i++) {
          line = L[i]
          if (line ~ /^menuentry /) {
            sub(/"[^"]*"/, "\"" t "\"", line)
            gsub(/--id '\''[^'\'']*'\''/, "--id '\''exarch-" k "'\''", line)
          }
          if (line ~ /^[ \t]*linux[ \t]/) line = line " " p
          print line
        }
      }
    }' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
done

grep -rlZ 'Arch Linux' "$PROFILE"/grub "$PROFILE"/efiboot "$PROFILE"/syslinux 2>/dev/null \
  | xargs -0 -r sed -i "s/Arch Linux/$DISTRO_NAME/g"

log "Building ISO (this takes a while)"
rm -rf "$WORK/build"
mkarchiso -v -w "$WORK/build" -o "$OUT" "$PROFILE"

log "Writing checksums + package list (SBOM-lite)"
cp "$WORK/build/iso/arch/pkglist.x86_64.txt" "$OUT/pkglist.txt" 2>/dev/null || true
( cd "$OUT" && sha256sum ./*.iso > SHA256SUMS )

log "Done:"
ls -lh "$OUT"
