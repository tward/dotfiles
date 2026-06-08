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
echo "The following will be installed from external sources:"
echo "  kitty (official installer)"
echo "  Hack Nerd Font + Symbols-Only Nerd Font (~/.local/share/fonts)"
echo "  lazygit (GitHub release)"
echo "  diff-so-fancy (GitHub release)"
echo "  yt-dlp (GitHub release → ~/.local/bin)"
echo "  niri-float-sticky (built from Go source → ~/.local/bin)"
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
    for family in Hack NerdFontsSymbolsOnly; do
      marker="$family/.installed"
      if [[ -f "$marker" ]]; then
        echo "  ${family} already present."
        continue
      fi
      echo "  Downloading ${family}.tar.xz..."
      url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${family}.tar.xz"
      mkdir -p "$family"
      if curl -fL "$url" | tar -xJ -C "$family"; then
        touch "$marker"
        echo "  Installed ${family}"
      else
        echo "WARNING: Failed to download/extract ${family}. Cleaning up."
        rm -rf "$family"
      fi
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
  LAZYGIT_VERSION=$(curl -sf "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*') || true
  if [[ -z "$LAZYGIT_VERSION" ]]; then
    echo "WARNING: Could not determine lazygit version. Skipping."
  else
    if curl -fLo "$TMPDIR/lazygit.tar.gz" "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_${LAZYGIT_ARCH}.tar.gz"; then
      tar xf "$TMPDIR/lazygit.tar.gz" -C "$TMPDIR" lazygit
      install "$TMPDIR/lazygit" /usr/local/bin
      echo "  Installed lazygit $LAZYGIT_VERSION"
    else
      echo "WARNING: Failed to download lazygit. Skipping."
    fi
  fi

  # --- diff-so-fancy from GitHub ---
  echo ""
  echo "==> Installing diff-so-fancy..."
  if curl -fLo "$TMPDIR/diff-so-fancy" "https://github.com/so-fancy/diff-so-fancy/releases/latest/download/diff-so-fancy"; then
    chmod +x "$TMPDIR/diff-so-fancy"
    mv "$TMPDIR/diff-so-fancy" /usr/local/bin/
    echo "  Installed diff-so-fancy"
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
if curl -fLo "$TMPDIR/yt-dlp" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"; then
  sudo -u "${SUDO_USER:-$USER}" mkdir -p "${REAL_HOME}/.local/bin"
  cp "$TMPDIR/yt-dlp" "${REAL_HOME}/.local/bin/yt-dlp"
  chmod 0755 "${REAL_HOME}/.local/bin/yt-dlp"
  chown "${SUDO_USER:-$USER}:" "${REAL_HOME}/.local/bin/yt-dlp"
  echo "  Installed yt-dlp to ~/.local/bin (run 'yt-dlp -U' to update)"
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
# the system. Guarded on the binary already existing — delete it to rebuild/upgrade.
NFS_VERSION="v0.0.8"
GO_VERSION="1.23.7"
NFS_BIN="${REAL_HOME}/.local/bin/niri-float-sticky"
echo ""
echo "==> Installing niri-float-sticky ${NFS_VERSION}..."
if [[ -x "$NFS_BIN" ]]; then
  echo "  Already installed at ~/.local/bin/niri-float-sticky (rm it to rebuild)."
else
  case "$ARCH" in
    x86_64)  GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    *)       GO_ARCH="" ;;
  esac
  if [[ -z "$GO_ARCH" ]]; then
    echo "WARNING: Unsupported architecture $ARCH for the Go toolchain. Skipping niri-float-sticky."
  elif curl -fLo "$TMPDIR/go.tar.gz" "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"; then
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
      echo "  Installed niri-float-sticky to ~/.local/bin"
    else
      echo "WARNING: Failed to build niri-float-sticky. Skipping."
    fi
  else
    echo "WARNING: Failed to download the Go toolchain. Skipping niri-float-sticky."
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
