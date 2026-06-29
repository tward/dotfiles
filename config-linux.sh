#!/usr/bin/env bash
#
# Distro-agnostic post-install CONFIGURATION for the Linux desktop.
#
# Pairs with the INSTALL step, which IS distro-specific and lives elsewhere:
#   - Fedora: framework-install's hands-off phase (packages + a few GitHub binaries)
#   - Ubuntu: install-linux.sh (apt packages, PPAs, GitHub binaries)
#
# Contains NO package installs, PPAs, or binary fetches — only the configuration
# that makes already-installed software behave. Assume every tool it calls is
# already on the system. It is the single "configure everything" entry point and
# ends by running dotbot.
#
# Runs AS ROOT against a target user:
#   config-linux.sh <user>     # called by the installer with an explicit user
#   sudo config-linux.sh       # human: target user is $SUDO_USER
#
# FAILURE MODEL: each config step is attempted independently. A failed step is
# logged loudly and flagged, but the rest still run (so one bad step never skips
# the others), and the script exits non-zero at the end so the caller records an
# honest failure. Idempotent and quiet on re-run.

set -uo pipefail   # deliberately NOT -e — per-step failure handling below

# --- preflight (HARD: can't proceed without a valid target user) ------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (sudo config-linux.sh [user])." >&2
  exit 1
fi

user="${1:-${SUDO_USER:-}}"
if [[ -z "$user" ]]; then
  echo "ERROR: no target user. Pass one (config-linux.sh <user>) or run via sudo." >&2
  exit 1
fi
if ! getent passwd "$user" >/dev/null; then
  echo "ERROR: user '$user' has no passwd entry." >&2
  exit 1
fi
user_home="$(getent passwd "$user" | cut -d: -f6)"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_dir"   # deterministic cwd for the runuser children below

# Run a command as the target user with their HOME/PATH so files land in their
# $HOME with correct ownership (runuser -u does NOT set these itself).
as_user() {
  runuser -u "$user" -- env \
    HOME="$user_home" \
    PATH="$user_home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

# --- small helpers ----------------------------------------------------------
# Append a line to a user-owned file (creating it + its parent as the user) only
# when that exact line isn't already present.
ensure_user_line() {
  local line="$1" file="$2"
  as_user mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
    return 0
  fi
  printf '%s\n' "$line" | as_user tee -a "$file" >/dev/null
}

# Set key=value under an INI group, replacing in place or appending — so re-runs
# don't clobber other state the file holds (Icon, Language, ...).
ensure_ini_key() {
  local file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

mask_user_service() {
  local svc="$1"
  if [[ -e "/usr/lib/systemd/user/$svc" || -e "/etc/systemd/user/$svc" ]]; then
    as_user mkdir -p "$user_home/.config/systemd/user"
    as_user ln -sf /dev/null "$user_home/.config/systemd/user/$svc"
    echo "  Masked $svc."
  else
    echo "  No packaged $svc found; nothing to mask."
  fi
}

# --- per-step failure handling (matches the framework's tiered model) --------
DEGRADED=0
# Run one config step (a function) under its own `set -e`. On failure: log loud,
# flag degraded, keep going. Every step is attempted; we exit non-zero at the end.
step() {
  local desc="$1" fn="$2"
  echo "==> ${desc}..."
  if ( set -e; "$fn" ); then
    return 0
  fi
  echo "  WARNING: ${desc} failed — continuing; config-linux.sh will exit non-zero." >&2
  DEGRADED=1
}

# --- config steps -----------------------------------------------------------
# Mask packaged waybar.service / swaync.service (user scope). Both packages ship a
# systemd *user* service enabled by default. niri spawns waybar and swaync itself,
# so the system instance double-runs — and they'd start uninvited under a vanilla
# GNOME session. For swaync the race also breaks popups (the system instance grabs
# the org.freedesktop.Notifications bus name before niri's layer-shell is ready, so
# notifications reach the panel but never draw/clear). Masking (symlink the user
# unit to /dev/null) is the fix; a user-scope *disable* doesn't stick because the
# package enables it in global scope.
cfg_masks() {
  mask_user_service waybar.service
  mask_user_service swaync.service
}

# i2c-dev module + udev rule for DDC/CI monitor brightness (root). ddcutil talks to
# external monitors over DDC/CI, which needs the in-tree i2c-dev module to expose
# /dev/i2c-*. Nothing auto-loads it, so persist it. ddcutil's packaged udev rule
# matches only PCI class 0x030000 (VGA); AMD GPUs can enumerate as 0x038000 and get
# EACCES — so add a local rule broadened to any 0x03* class (uaccess = per-seat ACL
# via logind). modprobe/udevadm are no-ops in an install chroot; the rule applies on
# next boot regardless.
cfg_i2c_ddcutil() {
  echo i2c-dev > /etc/modules-load.d/i2c-dev.conf
  modprobe i2c-dev 2>/dev/null || echo "  note: modprobe i2c-dev failed (e.g. install chroot); loads on next boot."
  printf '%s\n' \
    '# Broadens ddcutil'\''s packaged 60-ddcutil-i2c.rules (class 0x030000 only) to' \
    '# all PCI display classes — AMD GPUs can be 0x038000. See config-linux.sh.' \
    'SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x03*", TAG+="uaccess"' \
    > /etc/udev/rules.d/60-ddcutil-i2c-local.rules
  udevadm control --reload-rules 2>/dev/null || echo "  note: udevadm reload failed; rule applies on next boot."
  udevadm trigger --subsystem-match=i2c-dev 2>/dev/null || true
}

# kitty.desktop registration — BACKSTOP ONLY. If one already exists (user-local or
# system), do nothing — Fedora's packaged kitty ships one, so this is a no-op there.
# Only when kitty is a bare binary with no launcher do we write a minimal entry
# referencing kitty on PATH (no hardcoded ~/.local/kitty.app paths).
cfg_kitty() {
  if [[ -f "$user_home/.local/share/applications/kitty.desktop" || -f /usr/share/applications/kitty.desktop ]]; then
    echo "  kitty.desktop already present; nothing to register."
  elif command -v kitty >/dev/null 2>&1; then
    as_user mkdir -p "$user_home/.local/share/applications"
    as_user tee "$user_home/.local/share/applications/kitty.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=kitty
GenericName=Terminal emulator
Comment=Fast, feature-rich, GPU based terminal
TryExec=kitty
Exec=kitty
Icon=kitty
Categories=System;TerminalEmulator;
Keywords=terminal;
EOF
    echo "  Wrote backstop kitty.desktop."
  else
    echo "  kitty not on PATH; skipping desktop registration."
  fi
}

# Default login shell -> zsh (root).
cfg_shell() {
  local zsh_path current_shell
  zsh_path="$(command -v zsh || true)"
  current_shell="$(getent passwd "$user" | cut -d: -f7)"
  if [[ -z "$zsh_path" ]]; then
    echo "  note: zsh not on PATH; leaving shell as '$current_shell'."
  elif [[ "$current_shell" == *zsh* ]]; then
    echo "  Already zsh."
  else
    usermod -s "$zsh_path" "$user"
    echo "  Set $user's shell to $zsh_path."
  fi
}

# niri as the default GDM session (root). AccountsService records each user's last
# session; GDM reads it to preselect. Seeding it makes first boot land in niri while
# GNOME stays selectable from the login gear menu. Keys are ensured so a re-run
# never clobbers other AccountsService state the file may have accumulated.
cfg_session() {
  local accounts_file="/var/lib/AccountsService/users/$user"
  mkdir -p /var/lib/AccountsService/users
  if [[ ! -f "$accounts_file" ]]; then
    cat > "$accounts_file" <<'EOF'
[User]
Session=niri
XSession=niri
SystemAccount=false
EOF
  else
    grep -q '^\[User\]' "$accounts_file" || printf '[User]\n' >> "$accounts_file"
    ensure_ini_key "$accounts_file" Session niri
    ensure_ini_key "$accounts_file" XSession niri
    ensure_ini_key "$accounts_file" SystemAccount false
  fi
  echo "  Wrote $accounts_file (Session=niri)."
}

# GTK bookmark so /mnt/common shows in the Files sidebar (user scope).
cfg_bookmark() {
  ensure_user_line "file:///mnt/common Common" "$user_home/.config/gtk-3.0/bookmarks"
}

# Pull the desktop wallpaper from Common to where niri's swaybg expects it
# (~/Pictures/wallpaper.png). The image is deliberately untracked in the repo
# (2.2 MB binary); it's stashed at /mnt/common/backup/wallpapers/. No-op if Common
# isn't mounted or the source is missing.
cfg_wallpaper() {
  local src=/mnt/common/backup/wallpapers/wallpaper.png
  if [[ -f "$src" ]]; then
    as_user mkdir -p "$user_home/Pictures"
    as_user cp -f "$src" "$user_home/Pictures/wallpaper.png"
    echo "  Pulled wallpaper -> $user_home/Pictures/wallpaper.png"
  else
    echo "  note: $src not found (Common mounted?); skipping wallpaper."
  fi
}

# Dark mode default via a dconf SYSTEM default (NOT `gsettings set`, which needs a
# live D-Bus session that doesn't exist in an install chroot). dconf system defaults
# compile with `dconf update` (no session) and are read at each login. They are
# defaults, not locks — the user can flip the theme later and their choice (user-db)
# layers above this system-db value.
#
# gtk-theme is plain 'Adwaita', NOT 'Adwaita-dark'. The standalone Adwaita-dark theme
# dir ships only via gnome-themes-extra — installed by default on Ubuntu, but GONE from
# Fedora (the package was dropped; modern replacement is adw-gtk3-theme). So naming
# 'Adwaita-dark' is a dangling reference on Fedora and GTK3 silently falls back to LIGHT
# Adwaita. 'Adwaita' always resolves — it's compiled into libgtk-3 as a gresource
# (/org/gtk/libgtk/theme/Adwaita/{gtk,gtk-dark}.css), no theme package required. The
# dark variant then comes from prefer-dark, not from a separately-named theme.
cfg_dark_mode() {
  mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
  local profile=/etc/dconf/profile/user
  if [[ ! -f "$profile" ]]; then
    printf 'user-db:user\nsystem-db:local\n' > "$profile"
  elif ! grep -qxF 'system-db:local' "$profile"; then
    printf 'system-db:local\n' >> "$profile"
  fi
  cat > /etc/dconf/db/local.d/00-dark-mode <<'EOF'
# Default to dark; user choices (user-db) override these.
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita'
EOF
  dconf update 2>/dev/null || echo "  note: dconf update failed; dark mode applies once dconf can compile the db."

  # GTK3 keyfile fallback for sessions with NO settings daemon (niri). The dconf default
  # above is bridged into GtkSettings only by gnome-settings-daemon (a real GNOME login)
  # via XSETTINGS; a bare niri session runs no such daemon, so non-sandboxed GTK3 apps
  # never see prefer-dark and render light. settings.ini IS read directly by GTK3 in
  # every session, so it's the reliable place for the dark preference under niri. Note
  # gtk-application-prefer-dark-theme is a GtkSettings keyfile property, NOT a gsettings
  # key — it cannot live in dconf, which is the gap the dconf-only approach left open.
  # Written as a backstop (only when absent) so a user who flips to light isn't clobbered
  # on re-run — the keyfile analogue of the dconf "default, not lock" layering above.
  local gtk3_ini="$user_home/.config/gtk-3.0/settings.ini"
  if [[ -f "$gtk3_ini" ]]; then
    echo "  $gtk3_ini exists; leaving GTK3 theme prefs untouched."
  else
    as_user mkdir -p "$user_home/.config/gtk-3.0"
    as_user tee "$gtk3_ini" >/dev/null <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita
EOF
    echo "  Wrote $gtk3_ini (built-in Adwaita dark)."
  fi
}

# Run dotbot LAST (as the target user). Same setup as ./install's Linux path
# (venv + dotbot), minus the interactive prompts, so this stays the single
# configure-everything entry point.
cfg_dotbot() {
  local venv_dir="$repo_dir/.venv"
  if [[ ! -x "$venv_dir/bin/dotbot" ]]; then
    as_user python3 -m venv "$venv_dir"
    as_user "$venv_dir/bin/pip" install dotbot
  fi
  as_user "$venv_dir/bin/dotbot" -d "$repo_dir" -c "$repo_dir/install-linux.conf.yaml"
}

# --- run ---------------------------------------------------------------------
echo "==> Configuring for user '$user' (home: $user_home)"
step "Mask packaged waybar/swaync user services" cfg_masks
step "Enable i2c-dev + ddcutil udev access (DDC/CI brightness)" cfg_i2c_ddcutil
step "Register kitty.desktop (backstop)" cfg_kitty
step "Set default login shell to zsh" cfg_shell
step "Set niri as the default GDM session" cfg_session
step "Ensure GTK bookmark for /mnt/common" cfg_bookmark
step "Pull wallpaper from Common" cfg_wallpaper
step "Set dark mode as the GNOME/GTK default" cfg_dark_mode
step "Run dotbot (symlink dotfiles)" cfg_dotbot

if [[ "$DEGRADED" -ne 0 ]]; then
  echo "" >&2
  echo "Completed WITH degraded steps for '$user' — see the WARNING lines above. Exiting non-zero." >&2
  exit 1
fi
echo ""
echo "Done. Configuration complete for user '$user'."
