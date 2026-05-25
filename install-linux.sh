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
)

echo "The following apt packages will be installed:"
printf '  %s\n' "${APT_PACKAGES[@]}"
echo ""
echo "The following PPAs will be added:"
echo "  ppa:neovim-ppa/unstable (neovim 0.11+)"
echo ""
echo "The following will be installed from external sources:"
echo "  kitty (official installer)"
echo "  Hack Nerd Font + Symbols-Only Nerd Font (~/.local/share/fonts)"
echo "  lazygit (GitHub release)"
echo "  diff-so-fancy (GitHub release)"
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
