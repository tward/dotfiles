#!/usr/bin/env bash
#
# Install CLI tools on Ubuntu/Debian before running ./install
#
# Usage:
#   sudo bash install-linux.sh             Install everything
#   sudo bash install-linux.sh --uninstall Remove manually-installed binaries

set -e

# --- Uninstall mode ---
if [[ "${1:-}" == "--uninstall" ]]; then
  echo "==> Removing manually-installed binaries..."
  rm -f /usr/local/bin/lazygit
  rm -f /usr/local/bin/diff-so-fancy
  rm -f /usr/local/bin/fd
  rm -f /usr/local/bin/bat
  rm -f /usr/local/bin/kitty
  rm -f /usr/local/bin/kitten

  REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)

  rm -f "${REAL_HOME}/.local/share/applications/kitty.desktop"
  rm -f "${REAL_HOME}/.local/share/applications/kitty-open.desktop"
  rm -f "${REAL_HOME}/.local/bin/yt-dlp"
  rm -f "${REAL_HOME}/.local/bin/niri-float-sticky"
  rm -f "${REAL_HOME}/.local/bin/mutagen"
  rm -f "${REAL_HOME}/.local/bin/mutagen-agents.tar.gz"
  rm -rf "${REAL_HOME}/.local/state/dotfiles-bin"   # version stamps for non-apt binaries
  rm -f /etc/modules-load.d/i2c-dev.conf            # i2c-dev autoload for DDC/CI brightness (ddcutil)

  # Unmask the waybar service if we masked it (symlink to /dev/null).
  WAYBAR_MASK="${REAL_HOME}/.config/systemd/user/waybar.service"
  if [[ -L "$WAYBAR_MASK" ]] && [[ "$(readlink "$WAYBAR_MASK")" == /dev/null ]]; then
    rm -f "$WAYBAR_MASK"
    echo "==> Unmasked waybar.service"
  fi

  # Unmask the swaync service if we masked it (symlink to /dev/null).
  SWAYNC_MASK="${REAL_HOME}/.config/systemd/user/swaync.service"
  if [[ -L "$SWAYNC_MASK" ]] && [[ "$(readlink "$SWAYNC_MASK")" == /dev/null ]]; then
    rm -f "$SWAYNC_MASK"
    echo "==> Unmasked swaync.service"
  fi

  NERD_FONT_DIR="${REAL_HOME}/.local/share/fonts/NerdFonts"
  if [[ -d "$NERD_FONT_DIR" ]]; then
    echo "==> Removing Nerd Fonts..."
    rm -rf "${NERD_FONT_DIR}/Hack" "${NERD_FONT_DIR}/NerdFontsSymbolsOnly"
    rmdir "$NERD_FONT_DIR" 2>/dev/null || true
    sudo -u "${SUDO_USER:-$USER}" HOME="${REAL_HOME}" \
      fc-cache -f "${REAL_HOME}/.local/share/fonts" 2>/dev/null || true
  fi

  echo "Done. apt-installed packages are untouched — remove with apt if needed."
  echo "Kitty app remains at ~/.local/kitty.app — remove manually if desired."
  exit 0
fi

# --- Preflight ---
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with sudo: sudo bash install-linux.sh"
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Detect architecture for GitHub binary downloads
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  LAZYGIT_ARCH="x86_64" ;;
  aarch64) LAZYGIT_ARCH="arm64" ;;
  *)
    echo "WARNING: Unsupported architecture $ARCH for binary downloads."
    echo "lazygit and diff-so-fancy will need to be installed manually."
    LAZYGIT_ARCH=""
    ;;
esac

# --- Download verification helpers ---
# Only for the non-apt (GitHub/upstream) installs below; apt packages are already
# authenticated by the distro's signed repositories. gnupg is in APT_PACKAGES so
# it's present by the time these run.

# verify_sig <pubkey_url> <pinned_fpr> <sig_file> <signed_file>
# GPG-verify a detached signature against a PINNED signer fingerprint, in a
# throwaway keyring (never touches root's or the user's GPG state). Returns
# non-zero on any download/import/fingerprint/signature failure so the caller
# fails closed and skips the install.
verify_sig() {
  local key_url="$1" fpr="$2" sig="$3" file="$4"
  local g="$TMPDIR/gnupg.$RANDOM"
  mkdir -p "$g"; chmod 700 "$g"
  curl -sfL "$key_url" | GNUPGHOME="$g" gpg --quiet --batch --import || return 1
  GNUPGHOME="$g" gpg --with-colons --fingerprint | grep -q "^fpr:::::::::${fpr}:" || return 1
  GNUPGHOME="$g" gpg --quiet --batch --verify "$sig" "$file"
}

# verify_sha256 <checksums_file> <filename> [dir]
# Check one file's SHA-256 against a checksums manifest via `sha256sum -c`.
# Integrity only (the manifest shares the download's origin) unless the manifest
# itself was authenticated with verify_sig first.
verify_sha256() {
  local sums="$1" name="$2" dir="${3:-.}"
  ( cd "$dir" && grep " ${name}$" "$sums" | sha256sum -c - )
}

# latest_gh_tag <owner/repo> -> latest release tag via the /releases/latest
# redirect (no API token, no rate limit). Empty on failure.
latest_gh_tag() {
  curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'
}

# Version stamps for the non-apt binaries so re-runs skip work that's already
# current and auto-(re)install when the target version changes. The stamp records
# what THIS script installed — these binaries don't all report a parseable version
# (diff-so-fancy and niri-float-sticky report none) — so a manually swapped binary
# won't be re-detected; fine for installs this script owns. Pair with `-x` so a
# deleted binary still triggers reinstall regardless of the stamp.
# bin_current <name> <target_version> <binary_path> -> true (skip) if up-to-date.
bin_current() {
  local dir="${REAL_HOME}/.local/state/dotfiles-bin"
  [[ -n "$2" && -x "$3" && "$(cat "$dir/$1" 2>/dev/null)" == "$2" ]]
}
# bin_stamp <name> <target_version> -> record after a successful install.
bin_stamp() {
  local dir="${REAL_HOME}/.local/state/dotfiles-bin"
  sudo -u "${SUDO_USER:-$USER}" mkdir -p "$dir" || return 0
  printf '%s\n' "$2" | sudo -u "${SUDO_USER:-$USER}" tee "$dir/$1" >/dev/null || return 0
}

# --- apt packages ---
APT_PACKAGES=(
  software-properties-common
  zsh
  git
  git-lfs
  fzf
  fd-find
  ripgrep
  tmux
  htop
  jq
  wget
  curl
  gnupg           # verify GPG-signed non-apt downloads (mutagen, yt-dlp) — see verify_sig below
  ncurses-term
  python3-pip
  python3-venv
  fontconfig
  xz-utils
  mpv             # media player; plays YouTube URLs via yt-dlp, floated by a niri window-rule
  mpv-mpris       # MPRIS plugin (auto-loads from /etc/mpv/scripts) so playerctld/waybar/media keys sense mpv
  wl-clipboard    # wl-paste/wl-copy; used by the Mod+Y "play clipboard URL in mpv" niri bind
  swaybg          # wallpaper for the niri session (see niri/config.kdl)

  # niri desktop — bar & now-playing. Configs live in the repo (waybar/,
  # niri/config.kdl), so the packages those configs drive belong here too,
  # mirroring the macOS yabai/sketchybar stack in homebrew/Brewfile. niri itself is
  # PPA-only and installed below; these two are in the Ubuntu archive.
  waybar          # status bar (waybar/config.jsonc); pulls in libplayerctl2
  playerctl       # niri media keys + waybar now-playing (provides playerctld)
  fuzzel          # app launcher (Mod+Space in niri/config.kdl); themed via fuzzel/

  # niri desktop — settings GUIs
  pavucontrol     # audio mixer (incl. Pro-Audio profile)
  blueman         # bluetooth manager
  # nwg-displays  # NO niri support until upstream 0.4.0; apt ships 0.3.x (25.10: 0.3.20, 26.04: 0.3.26)
                  # which exits "Neither sway nor Hyprland detected". Manage outputs in niri/config.kdl
                  # (niri msg outputs -> output blocks) instead. Revisit if apt reaches >= 0.4.0.
  nwg-look        # GTK theme / icons / cursor / fonts
  # nm-connection-editor  # NetworkManager GUI — ships with the Ubuntu desktop install; uncomment for a minimal base

  # niri desktop — session services (a full DE bundles these; we start them from
  # niri/config.kdl). All Wayland-native and distro-portable.
  ddcutil         # external-monitor brightness over DDC/CI (scripts/ddc-brightness); needs i2c-dev, enabled below
  libnotify-bin   # notify-send — OSD popups from scripts (ddc-brightness, flatpak-kill-menu)
  swaylock        # screen locker (Super+Alt+L, and swayidle on idle/sleep)
  swayidle        # idle daemon: auto-lock, DPMS off, lock-before-sleep
  sway-notification-center  # notification daemon + center panel (binary is "swaync"); Debian/Ubuntu package name
  mate-polkit     # graphical polkit agent for privileged-action auth dialogs
)

echo "The following apt packages will be installed:"
printf '  %s\n' "${APT_PACKAGES[@]}"
echo ""
echo "The following PPAs will be added:"
echo "  ppa:avengemedia/danklinux (niri + xwayland-satellite)"
echo "  ppa:neovim-ppa/unstable (neovim 0.11+)"
echo ""
echo "The following will be installed from external sources (signatures/checksums verified where published):"
echo "  kitty (official installer)"
echo "  Hack Nerd Font + Symbols-Only Nerd Font (~/.local/share/fonts; SHA-256 verified)"
echo "  lazygit (GitHub release; SHA-256 verified)"
echo "  diff-so-fancy (GitHub release; no upstream checksums published)"
echo "  yt-dlp (GitHub release → ~/.local/bin; GPG-signed checksums verified)"
echo "  niri-float-sticky (built from Go source → ~/.local/bin; Go module checksums)"
echo "  mutagen (signed GitHub release → ~/.local/bin; GPG-signed checksums verified)"
echo ""
read -p "Proceed? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

echo ""
echo "==> Installing apt packages..."
apt update
apt install -y "${APT_PACKAGES[@]}"

# fd-find installs as fdfind on Debian/Ubuntu
if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
  ln -s "$(which fdfind)" /usr/local/bin/fd
fi

# bat: try apt first, handle batcat rename
if ! command -v bat &>/dev/null; then
  if apt install -y bat 2>/dev/null; then
    : # installed as bat
  elif command -v batcat &>/dev/null; then
    ln -s "$(which batcat)" /usr/local/bin/bat
  fi
fi

# eza: try apt, fall back to cargo
if ! command -v eza &>/dev/null; then
  if ! apt install -y eza 2>/dev/null; then
    echo "eza not in apt repos. Install manually: cargo install eza"
  fi
fi

# --- Kitty terminal ---
echo ""
echo "==> Installing Kitty..."
REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
if ! command -v kitty &>/dev/null; then
  sudo -u "${SUDO_USER:-$USER}" HOME="${REAL_HOME}" sh -c "curl -fL https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin launch=n"
  ln -sf "${REAL_HOME}/.local/kitty.app/bin/kitty" /usr/local/bin/kitty
  ln -sf "${REAL_HOME}/.local/kitty.app/bin/kitten" /usr/local/bin/kitten
else
  echo "  Kitty already installed."
fi

# Desktop integration: register kitty.desktop / kitty-open.desktop with absolute
# paths into the user-local kitty.app, and mark it as the xdg-terminal. Steps
# verbatim from https://sw.kovidgoyal.net/kitty/binary/#desktop-integration-on-linux
if [[ ! -f "${REAL_HOME}/.local/share/applications/kitty.desktop" ]]; then
  echo "  Registering Kitty desktop entries..."
  sudo -u "${SUDO_USER:-$USER}" HOME="${REAL_HOME}" bash -c '
    set -e
    mkdir -p "$HOME/.local/share/applications" "$HOME/.config"
    cp "$HOME/.local/kitty.app/share/applications/kitty.desktop" "$HOME/.local/share/applications/"
    cp "$HOME/.local/kitty.app/share/applications/kitty-open.desktop" "$HOME/.local/share/applications/"
    sed -i "s|Icon=kitty|Icon=$HOME/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g" "$HOME/.local/share/applications/"kitty*.desktop
    sed -i "s|Exec=kitty|Exec=$HOME/.local/kitty.app/bin/kitty|g" "$HOME/.local/share/applications/"kitty*.desktop
    echo "kitty.desktop" > "$HOME/.config/xdg-terminals.list"
  '
else
  echo "  Kitty desktop entry already registered."
fi

# --- Nerd Fonts (Hack + Symbols-Only) ---
echo ""
echo "==> Installing Nerd Fonts (Hack, Symbols-Only)..."

NERD_FONT_DIR="${REAL_HOME}/.local/share/fonts/NerdFonts"

if [[ -f "${NERD_FONT_DIR}/Hack/.installed" ]] \
   && [[ -f "${NERD_FONT_DIR}/NerdFontsSymbolsOnly/.installed" ]]; then
  echo "  Nerd Fonts already installed."
else
  sudo -u "${SUDO_USER:-$USER}" HOME="${REAL_HOME}" bash -c '
    set -e
    mkdir -p "$HOME/.local/share/fonts/NerdFonts"
    cd "$HOME/.local/share/fonts/NerdFonts"
    # Fetch the release SHA-256 manifest once; integrity-check each font tarball
    # against it before extracting (no upstream signature is published).
    sums="$(mktemp)"
    if ! curl -fsL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/SHA-256.txt" -o "$sums"; then
      echo "WARNING: Could not fetch Nerd Fonts SHA-256.txt; skipping fonts (cannot verify)."
      exit 0
    fi
    for family in Hack NerdFontsSymbolsOnly; do
      marker="$family/.installed"
      if [[ -f "$marker" ]]; then
        echo "  ${family} already present."
        continue
      fi
      echo "  Downloading ${family}.tar.xz..."
      url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${family}.tar.xz"
      tmpf="$(mktemp)"
      if ! curl -fL "$url" -o "$tmpf"; then
        echo "WARNING: Failed to download ${family}. Skipping."
        rm -f "$tmpf"; continue
      fi
      exp="$(grep " ${family}.tar.xz$" "$sums" | cut -d" " -f1)"
      act="$(sha256sum "$tmpf" | cut -d" " -f1)"
      if [[ -z "$exp" || "$exp" != "$act" ]]; then
        echo "WARNING: ${family} checksum mismatch. Skipping."
        rm -f "$tmpf"; continue
      fi
      mkdir -p "$family"
      if tar -xJ -C "$family" -f "$tmpf"; then
        touch "$marker"
        echo "  Installed & verified ${family}"
      else
        echo "WARNING: Failed to extract ${family}. Cleaning up."
        rm -rf "$family"
      fi
      rm -f "$tmpf"
    done
    fc-cache -f "$HOME/.local/share/fonts"
  '
fi

# --- niri compositor via danklinux PPA ---
# niri is the Wayland compositor the whole desktop is built around (niri/config.kdl).
# Not in the Ubuntu archive; the danklinux PPA packages it. niri Depends on
# xwayland-satellite, so the X11/XWayland bridge (for Bitwig, Discord, etc.) comes in
# automatically. waybar/playerctl/swaync are installed above from the archive.
echo ""
echo "==> Installing niri via danklinux PPA..."
add-apt-repository -y ppa:avengemedia/danklinux
apt update
apt install -y niri

# --- Neovim via PPA ---
echo ""
echo "==> Installing Neovim via PPA..."
add-apt-repository -y ppa:neovim-ppa/unstable
apt update
apt install -y neovim

# --- lazygit from GitHub ---
echo ""
if [[ -n "$LAZYGIT_ARCH" ]]; then
  echo "==> Installing lazygit..."
  LAZYGIT_TAG="$(latest_gh_tag jesseduffield/lazygit)"   # e.g. v0.62.2
  LAZYGIT_VERSION="${LAZYGIT_TAG#v}"                      # 0.62.2 (asset/tarball naming)
  if [[ -z "$LAZYGIT_VERSION" ]]; then
    echo "WARNING: Could not determine lazygit version. Skipping."
  elif bin_current lazygit "$LAZYGIT_VERSION" /usr/local/bin/lazygit; then
    echo "  lazygit $LAZYGIT_VERSION already installed."
  else
    # Asset names are lowercase: lazygit_<ver>_linux_<arch>.tar.gz. Pull the
    # release's checksums.txt and verify before installing. No upstream signature
    # is published, so this is an integrity (not authenticity) check.
    LAZYGIT_TARBALL="lazygit_${LAZYGIT_VERSION}_linux_${LAZYGIT_ARCH}.tar.gz"
    LAZYGIT_BASE="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}"
    if curl -fLo "$TMPDIR/$LAZYGIT_TARBALL" "$LAZYGIT_BASE/$LAZYGIT_TARBALL" \
       && curl -fLo "$TMPDIR/lazygit-checksums.txt" "$LAZYGIT_BASE/checksums.txt"; then
      if verify_sha256 "$TMPDIR/lazygit-checksums.txt" "$LAZYGIT_TARBALL" "$TMPDIR"; then
        tar xf "$TMPDIR/$LAZYGIT_TARBALL" -C "$TMPDIR" lazygit
        install "$TMPDIR/lazygit" /usr/local/bin
        bin_stamp lazygit "$LAZYGIT_VERSION"
        echo "  Installed & verified lazygit $LAZYGIT_VERSION"
      else
        echo "WARNING: lazygit checksum mismatch. Skipping."
      fi
    else
      echo "WARNING: Failed to download lazygit. Skipping."
    fi
  fi

  # --- diff-so-fancy from GitHub ---
  # NOTE: upstream ships only the bare script — no checksums or signatures — so
  # there is nothing to verify against beyond the TLS transfer. It also reports no
  # version, so skip/upgrade is decided from the release tag via a version stamp.
  echo ""
  echo "==> Installing diff-so-fancy..."
  DSF_TAG="$(latest_gh_tag so-fancy/diff-so-fancy)"   # e.g. v1.4.10
  if [[ -z "$DSF_TAG" ]]; then
    echo "WARNING: Could not determine diff-so-fancy version. Skipping."
  elif bin_current diff-so-fancy "$DSF_TAG" /usr/local/bin/diff-so-fancy; then
    echo "  diff-so-fancy $DSF_TAG already installed."
  elif curl -fLo "$TMPDIR/diff-so-fancy" "https://github.com/so-fancy/diff-so-fancy/releases/download/${DSF_TAG}/diff-so-fancy"; then
    chmod +x "$TMPDIR/diff-so-fancy"
    mv "$TMPDIR/diff-so-fancy" /usr/local/bin/
    bin_stamp diff-so-fancy "$DSF_TAG"
    echo "  Installed diff-so-fancy $DSF_TAG"
  else
    echo "WARNING: Failed to download diff-so-fancy. Skipping."
  fi
fi

# --- yt-dlp to ~/.local/bin ---
# User-local (not /usr/local/bin like lazygit) so `yt-dlp -U` can self-update the
# binary in place without sudo. YouTube changes break stale yt-dlp often, so
# in-place self-update matters. Arch-independent: the released `yt-dlp` is a
# python zipapp (python3 is in APT_PACKAGES), so no LAZYGIT_ARCH gate is needed.
# REAL_HOME is set above in the Kitty section.
echo ""
echo "==> Installing yt-dlp..."
# Releases ship GPG-signed checksums (SHA2-256SUMS + .sig); verify the signature
# (key from the repo's public.key, fingerprint pinned) and the checksum first.
YTDLP_GPG_FPR="AC0CBBE6848D6A873464AF4E57CF65933B5A7581"   # yt-dlp signing key (public.key)
YTDLP_VERSION="$(latest_gh_tag yt-dlp/yt-dlp)"             # date tag, e.g. 2026.03.17
YTDLP_BASE="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}"
if [[ -z "$YTDLP_VERSION" ]]; then
  echo "WARNING: Could not determine yt-dlp version. Skipping."
elif bin_current yt-dlp "$YTDLP_VERSION" "${REAL_HOME}/.local/bin/yt-dlp"; then
  echo "  yt-dlp $YTDLP_VERSION already installed ('yt-dlp -U' self-updates between runs)."
elif curl -fLo "$TMPDIR/yt-dlp" "$YTDLP_BASE/yt-dlp" \
     && curl -fLo "$TMPDIR/yt-dlp-SHA2-256SUMS" "$YTDLP_BASE/SHA2-256SUMS" \
     && curl -fLo "$TMPDIR/yt-dlp-SHA2-256SUMS.sig" "$YTDLP_BASE/SHA2-256SUMS.sig"; then
  if verify_sig "https://github.com/yt-dlp/yt-dlp/raw/master/public.key" "$YTDLP_GPG_FPR" \
       "$TMPDIR/yt-dlp-SHA2-256SUMS.sig" "$TMPDIR/yt-dlp-SHA2-256SUMS" \
     && verify_sha256 "$TMPDIR/yt-dlp-SHA2-256SUMS" "yt-dlp" "$TMPDIR"; then
    sudo -u "${SUDO_USER:-$USER}" mkdir -p "${REAL_HOME}/.local/bin"
    cp "$TMPDIR/yt-dlp" "${REAL_HOME}/.local/bin/yt-dlp"
    chmod 0755 "${REAL_HOME}/.local/bin/yt-dlp"
    chown "${SUDO_USER:-$USER}:" "${REAL_HOME}/.local/bin/yt-dlp"
    bin_stamp yt-dlp "$YTDLP_VERSION"
    echo "  Installed & verified yt-dlp $YTDLP_VERSION to ~/.local/bin (run 'yt-dlp -U' to update)"
  else
    echo "WARNING: yt-dlp signature/checksum verification failed. Skipping."
  fi
else
  echo "WARNING: Failed to download yt-dlp. Skipping."
fi

# --- niri-float-sticky (built from Go source) ---
# Sticky / "show on all workspaces" floating windows for niri, which has no native
# support (tracked upstream in niri#932). Used to pin the mpv float as a follow-me
# PiP — see the spawn-sh-at-startup line and Mod+P toggle in niri/config.kdl.
#
# No prebuilt binaries exist and Go is NOT a system dependency, so build with a
# THROWAWAY toolchain: download Go into $TMPDIR (auto-removed by the EXIT trap),
# build the pinned tag straight into the user's ~/.local/bin, and leave no Go on
# the system. Version-stamped: skips when current, rebuilds when NFS_VERSION changes.
NFS_VERSION="v0.0.8"
GO_VERSION="1.23.7"
NFS_BIN="${REAL_HOME}/.local/bin/niri-float-sticky"
echo ""
echo "==> Installing niri-float-sticky ${NFS_VERSION}..."
if bin_current niri-float-sticky "$NFS_VERSION" "$NFS_BIN"; then
  echo "  niri-float-sticky ${NFS_VERSION} already installed."
else
  case "$ARCH" in
    x86_64)  GO_ARCH="amd64"; GO_SHA256="4741525e69841f2e22f9992af25df0c1112b07501f61f741c12c6389fcb119f3" ;;
    aarch64) GO_ARCH="arm64"; GO_SHA256="597acbd0505250d4d98c4c83adf201562a8c812cbcd7b341689a07087a87a541" ;;
    *)       GO_ARCH=""; GO_SHA256="" ;;
  esac
  if [[ -z "$GO_ARCH" ]]; then
    echo "WARNING: Unsupported architecture $ARCH for the Go toolchain. Skipping niri-float-sticky."
  # Verify the toolchain against its PINNED SHA-256 (from go.dev's official downloads
  # JSON: https://go.dev/dl/?mode=json&include=all). Pinned in-repo, not fetched, so
  # it catches a compromised go.dev/CDN — not just transit corruption. Bump both
  # hashes when GO_VERSION changes (go.dev/dl lists them per release).
  elif curl -fLo "$TMPDIR/go.tar.gz" "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" \
       && echo "${GO_SHA256}  $TMPDIR/go.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
    tar -C "$TMPDIR" -xzf "$TMPDIR/go.tar.gz"   # extracts to $TMPDIR/go (throwaway GOROOT)
    chmod 755 "$TMPDIR"                          # let the build user traverse in to reach GOROOT
    install -d -o "${SUDO_USER:-$USER}" "$TMPDIR/gopath" "$TMPDIR/gocache"
    sudo -u "${SUDO_USER:-$USER}" mkdir -p "${REAL_HOME}/.local/bin"
    # Build as the invoking user so the binary + module cache are user-owned. GOPATH
    # and GOCACHE live in $TMPDIR and vanish with it; GOBIN drops the binary in place.
    if sudo -u "${SUDO_USER:-$USER}" env \
         HOME="${REAL_HOME}" \
         GOROOT="$TMPDIR/go" \
         GOPATH="$TMPDIR/gopath" \
         GOCACHE="$TMPDIR/gocache" \
         GOBIN="${REAL_HOME}/.local/bin" \
         "$TMPDIR/go/bin/go" install "github.com/probeldev/niri-float-sticky@${NFS_VERSION}"; then
      bin_stamp niri-float-sticky "$NFS_VERSION"
      echo "  Installed niri-float-sticky ${NFS_VERSION} to ~/.local/bin"
    else
      echo "WARNING: Failed to build niri-float-sticky. Skipping."
    fi
  else
    echo "WARNING: Failed to download or verify the Go toolchain. Skipping niri-float-sticky."
  fi
fi

# --- Mutagen (signed GitHub release → ~/.local/bin) ---
# Two-way SSH file sync for the Linux<->macOS dev workflow (see the
# "Undock / Redock" runbook). No apt/PPA exists, and `go install` yields an
# incomplete binary (no agent bundle -> remote sync fails), so the signed release
# tarball is the only viable source. Verified the distro way: GPG-check SHA256SUMS
# against mutagenbot's pinned key, then checksum the tarball. Only this (daemon)
# host needs the full install; the mac gets an agent auto-deployed over SSH from
# mutagen-agents.tar.gz, so both files must land together on PATH. User-local so
# the per-user daemon and its ~/.mutagen state stay user-owned. Run
# `mutagen daemon register` once, as your user, to autostart it.
MUTAGEN_VERSION="0.18.1"
MUTAGEN_GPG_FPR="34E4B7729CFC6FB4E776CB3B781D56DB8AFBBFEA"   # Mutagen Bot <bot@mutagen.io>
case "$ARCH" in
  x86_64)  MUTAGEN_ARCH="amd64" ;;
  aarch64) MUTAGEN_ARCH="arm64" ;;
  *)       MUTAGEN_ARCH="" ;;
esac
echo ""
echo "==> Installing Mutagen ${MUTAGEN_VERSION}..."
MUTAGEN_BIN="${REAL_HOME}/.local/bin/mutagen"
if bin_current mutagen "$MUTAGEN_VERSION" "$MUTAGEN_BIN"; then
  echo "  mutagen ${MUTAGEN_VERSION} already installed."
elif [[ -z "$MUTAGEN_ARCH" ]]; then
  echo "WARNING: Unsupported architecture $ARCH for Mutagen. Skipping."
else
  MUTAGEN_TARBALL="mutagen_linux_${MUTAGEN_ARCH}_v${MUTAGEN_VERSION}.tar.gz"
  MUTAGEN_BASE="https://github.com/mutagen-io/mutagen/releases/download/v${MUTAGEN_VERSION}"
  mdir="$TMPDIR/mutagen"; mkdir -p "$mdir"
  if curl -fLo "$mdir/$MUTAGEN_TARBALL" "$MUTAGEN_BASE/$MUTAGEN_TARBALL" \
     && curl -fLo "$mdir/SHA256SUMS" "$MUTAGEN_BASE/SHA256SUMS" \
     && curl -fLo "$mdir/SHA256SUMS.gpg" "$MUTAGEN_BASE/SHA256SUMS.gpg"; then
    if verify_sig "https://github.com/mutagenbot.gpg" "$MUTAGEN_GPG_FPR" \
         "$mdir/SHA256SUMS.gpg" "$mdir/SHA256SUMS" \
       && verify_sha256 "$mdir/SHA256SUMS" "$MUTAGEN_TARBALL" "$mdir"; then
      sudo -u "${SUDO_USER:-$USER}" mkdir -p "${REAL_HOME}/.local/bin"
      tar -xzf "$mdir/$MUTAGEN_TARBALL" -C "${REAL_HOME}/.local/bin" mutagen mutagen-agents.tar.gz
      chown "${SUDO_USER:-$USER}:" "${REAL_HOME}/.local/bin/mutagen" "${REAL_HOME}/.local/bin/mutagen-agents.tar.gz"
      chmod 0755 "${REAL_HOME}/.local/bin/mutagen"
      bin_stamp mutagen "$MUTAGEN_VERSION"
      echo "  Installed & verified mutagen to ~/.local/bin"
    else
      echo "WARNING: Mutagen signature/checksum verification failed. Skipping."
    fi
  else
    echo "WARNING: Failed to download Mutagen release assets. Skipping."
  fi
fi

# --- Mask packaged waybar service ---
# The waybar apt package ships a systemd user service enabled by default
# (WantedBy=graphical-session.target). It would start a second bar alongside
# niri's own spawn-at-startup, and would also launch waybar under GNOME. We
# start waybar only from niri's config, so mask the service. A user-scope
# disable does not stick because the package enables it in global scope.
echo ""
echo "==> Masking packaged waybar systemd service..."
if [[ -e /usr/lib/systemd/user/waybar.service ]] || [[ -e /etc/systemd/user/waybar.service ]]; then
  REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
  MASK_DIR="${REAL_HOME}/.config/systemd/user"
  sudo -u "${SUDO_USER:-$USER}" mkdir -p "$MASK_DIR"
  sudo -u "${SUDO_USER:-$USER}" ln -sf /dev/null "${MASK_DIR}/waybar.service"
  echo "  Masked waybar.service (waybar starts from niri config only)."
else
  echo "  No packaged waybar.service found; nothing to mask."
fi

# --- Mask packaged swaync service ---
# The sway-notification-center apt package ships a systemd user service enabled
# by default (WantedBy=graphical-session.target) with Restart=on-failure. It
# races niri's own spawn-at-startup: at login systemd starts swaync before the
# compositor's layer-shell is ready, the daemon exits 1, and Restart=on-failure
# respawns it in a tight loop. Whichever instance wins the
# org.freedesktop.Notifications bus name serves the whole session — when a
# half-initialised one wins, notifications still reach the control center (and
# apps still play their own sound) but no popups ever draw. It would also launch
# swaync under GNOME. We start swaync only from niri's config, so mask the
# service (this also stops D-Bus activation, which routes via SystemdService=).
# A user-scope disable does not stick because the package enables it in global
# scope.
echo ""
echo "==> Masking packaged swaync systemd service..."
if [[ -e /usr/lib/systemd/user/swaync.service ]] || [[ -e /etc/systemd/user/swaync.service ]]; then
  REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
  MASK_DIR="${REAL_HOME}/.config/systemd/user"
  sudo -u "${SUDO_USER:-$USER}" mkdir -p "$MASK_DIR"
  sudo -u "${SUDO_USER:-$USER}" ln -sf /dev/null "${MASK_DIR}/swaync.service"
  echo "  Masked swaync.service (swaync starts from niri config only)."
else
  echo "  No packaged swaync.service found; nothing to mask."
fi

# --- i2c-dev module for DDC/CI monitor brightness ---
# ddcutil (scripts/ddc-brightness, bound to the brightness keys in
# niri/config.kdl) talks to external monitors over DDC/CI, which needs the
# in-tree i2c-dev module to expose /dev/i2c-* to userspace. It is not
# auto-loaded by anything, so persist it. No group/udev setup is needed: the
# ddcutil package ships udev rules tagging display i2c devices uaccess, so
# the logged-in seat user gets access automatically.
echo ""
echo "==> Enabling i2c-dev module (DDC/CI monitor brightness)..."
echo i2c-dev > /etc/modules-load.d/i2c-dev.conf
modprobe i2c-dev || echo "  WARNING: modprobe i2c-dev failed; brightness keys won't work until it loads."

# --- Set default shell ---
echo ""
if command -v zsh &>/dev/null; then
  current_shell=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f7)
  if [[ "$current_shell" != *zsh* ]]; then
    read -p "Set zsh as default shell for ${SUDO_USER:-$USER}? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      chsh -s "$(which zsh)" "${SUDO_USER:-$USER}"
      echo "Shell changed. Log out and back in for it to take effect."
    fi
  else
    echo "zsh is already the default shell."
  fi
else
  echo "WARNING: zsh not found after install. Shell not changed."
fi

echo ""
echo "Done. Run ./install to set up dotfiles symlinks."
