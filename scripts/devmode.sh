#!/usr/bin/env bash
#
# Toggle "developer mode" — yabai + skhd + sketchybar + macOS cosmetic changes.
#
# Usage:
#   devmode.sh on      Start services and apply cosmetic defaults
#   devmode.sh off     Stop services and restore macOS defaults
#   devmode.sh status  Show whether services are running
#
# NOTE: On macOS Tahoe (26.x), yabai/skhd/sketchybar may not appear in
# System Settings > Accessibility due to a known macOS bug with path-based
# TCC entries. See: https://github.com/koekeishiya/yabai/issues/2688

set -e

if [[ "$(uname)" != "Darwin" ]]; then
  echo "devmode is macOS only."
  exit 1
fi

STATE_DIR="$HOME/.dotfiles-state"
STATE_FILE="$STATE_DIR/state.json"

ensure_state_file() {
  mkdir -p "$STATE_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{}' > "$STATE_FILE"
  fi
}

read_state() {
  ensure_state_file
  jq -r "$1 // empty" "$STATE_FILE"
}

write_state() {
  ensure_state_file
  local tmp
  tmp=$(jq "$1" "$STATE_FILE")
  echo "$tmp" > "$STATE_FILE"
}

# Read a defaults value, returning a fallback if unset
read_default() {
  defaults read "$1" "$2" 2>/dev/null || echo "$3"
}

is_running() {
  pgrep -x "$1" &>/dev/null
}

status() {
  for svc in yabai skhd sketchybar; do
    if is_running "$svc"; then
      echo "  $svc: running"
    else
      echo "  $svc: stopped"
    fi
  done

  local active
  active=$(read_state '.devmode.active')
  if [[ "$active" == "true" ]]; then
    echo "  devmode: on"
  else
    echo "  devmode: off"
  fi
}

capture_current_state() {
  write_state "
    .devmode.active = true
    | .devmode.previous.dock_autohide = $(read_default com.apple.dock autohide 0)
    | .devmode.previous.dock_autohide_delay = $(read_default com.apple.dock autohide-delay -1)
    | .devmode.previous.dock_autohide_time_modifier = $(read_default com.apple.dock autohide-time-modifier -1)
    | .devmode.previous.dock_mru_spaces = $(read_default com.apple.dock mru-spaces 1)
    | .devmode.previous.key_repeat = $(read_default NSGlobalDomain KeyRepeat -1)
    | .devmode.previous.initial_key_repeat = $(read_default NSGlobalDomain InitialKeyRepeat -1)
    | .devmode.previous.press_and_hold = $(read_default NSGlobalDomain ApplePressAndHoldEnabled 1)
    | .devmode.previous.show_all_files = $(read_default com.apple.finder AppleShowAllFiles 0)
    | .devmode.previous.show_path_bar = $(read_default com.apple.finder ShowPathbar 0)
    | .devmode.previous.show_status_bar = $(read_default com.apple.finder ShowStatusBar 0)
    | .devmode.previous.show_all_extensions = $(read_default NSGlobalDomain AppleShowAllExtensions 0)
    | .devmode.previous.auto_spelling_correction = $(read_default NSGlobalDomain NSAutomaticSpellingCorrectionEnabled 1)
    | .devmode.previous.window_animations = $(read_default NSGlobalDomain NSAutomaticWindowAnimationsEnabled 1)
  "
}

restore_default() {
  local domain="$1" key="$2" type="$3" state_key="$4"
  local val
  val=$(read_state ".devmode.previous.$state_key")

  if [[ -z "$val" || "$val" == "-1" ]]; then
    defaults delete "$domain" "$key" 2>/dev/null || true
  elif [[ "$type" == "bool" ]]; then
    # defaults write -bool expects true/false, not 1/0
    if [[ "$val" == "1" || "$val" == "true" ]]; then
      defaults write "$domain" "$key" -bool true
    else
      defaults write "$domain" "$key" -bool false
    fi
  else
    defaults write "$domain" "$key" "-$type" "$val"
  fi
}

start() {
  echo "==> Starting developer mode..."

  # Capture all current settings before changing anything
  capture_current_state

  yabai --start-service
  skhd --start-service
  brew services start sketchybar

  # Cosmetic: hide Dock, fast key repeat
  defaults write NSGlobalDomain KeyRepeat -int 2
  defaults write NSGlobalDomain InitialKeyRepeat -int 15
  defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
  defaults write com.apple.dock autohide -bool true
  defaults write com.apple.dock autohide-delay -float 0
  defaults write com.apple.dock autohide-time-modifier -float 0.4
  defaults write com.apple.dock mru-spaces -bool false
  defaults write com.apple.finder AppleShowAllFiles -bool true
  defaults write com.apple.finder ShowPathbar -bool true
  defaults write com.apple.finder ShowStatusBar -bool true
  defaults write NSGlobalDomain AppleShowAllExtensions -bool true
  defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
  defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
  killall Dock Finder &>/dev/null || true

  echo "Developer mode ON."
  echo ""
  echo "  Manual steps:"
  echo "    - Turn off Stage Manager in System Settings > Desktop & Dock"
  echo "    - Set menu bar to 'Always' in System Settings > Control Centre"
  status
}

stop() {
  echo "==> Stopping developer mode..."

  yabai --stop-service
  skhd --stop-service
  brew services stop sketchybar

  # Restore all previous settings
  echo "  Restoring previous settings..."
  restore_default NSGlobalDomain KeyRepeat int key_repeat
  restore_default NSGlobalDomain InitialKeyRepeat int initial_key_repeat
  restore_default NSGlobalDomain ApplePressAndHoldEnabled bool press_and_hold
  restore_default com.apple.dock autohide bool dock_autohide
  restore_default com.apple.dock autohide-delay float dock_autohide_delay
  restore_default com.apple.dock autohide-time-modifier float dock_autohide_time_modifier
  restore_default com.apple.dock mru-spaces bool dock_mru_spaces
  restore_default com.apple.finder AppleShowAllFiles bool show_all_files
  restore_default com.apple.finder ShowPathbar bool show_path_bar
  restore_default com.apple.finder ShowStatusBar bool show_status_bar
  restore_default NSGlobalDomain AppleShowAllExtensions bool show_all_extensions
  restore_default NSGlobalDomain NSAutomaticSpellingCorrectionEnabled bool auto_spelling_correction
  restore_default NSGlobalDomain NSAutomaticWindowAnimationsEnabled bool window_animations
  killall Dock Finder &>/dev/null || true

  write_state '.devmode.active = false'

  echo "Developer mode OFF."
  echo ""
  echo "  Manual steps:"
  echo "    - Turn on Stage Manager in System Settings > Desktop & Dock"
  echo "    - Set menu bar to preferred setting in System Settings > Control Centre"
  status
}

case "${1:-}" in
  on)     start ;;
  off)    stop ;;
  status) status ;;
  *)
    echo "Usage: devmode.sh {on|off|status}"
    exit 1
    ;;
esac
