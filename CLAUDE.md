# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Cross-platform development-environment dotfiles for **macOS** and **Linux (Wayland/niri)**. The same repo drives both: a macOS stack built around the yabai window manager and a Linux stack built around the niri compositor, sharing a common core of terminal (Kitty), multiplexer (Tmux), editor (Neovim), shell (ZSH), and CLI tooling.

The single most important thing to understand: **almost every concern in this repo is OS-split.** Before editing or adding anything, know which platform(s) it applies to and use the matching split mechanism (see below).

## Setup Commands

`./install` is the entry point. It detects the OS with `uname` and runs the matching dotbot config:

- **macOS** → `install-mac.conf.yaml`. Installs Homebrew + dotbot if missing, symlinks configs, then runs `brew bundle --file=homebrew/Brewfile` and installs tmux plugins (TPM) via dotbot's `shell` hook.
- **Linux** → `install-linux.conf.yaml`. Installs dotbot into a local `.venv`, then symlinks configs and installs tmux plugins.

`./install` **only creates symlinks and runs those hooks** — on Linux it does NOT install packages. The Linux package/tooling install is a separate, manual, root step that must run **first**:

```bash
sudo bash install-linux.sh    # apt packages, PPAs (niri, neovim), Nerd Fonts, kitty, lazygit, diff-so-fancy
./install                     # then symlink dotfiles

sudo bash install-linux.sh --uninstall   # reverse the manually-installed binaries/fonts (apt pkgs left alone)
```

`backup.sh` snapshots existing real config to `~/.dotfiles-backup/` — `./install` warns if no backup exists. `uninstall.sh` removes symlinks.

## OS-Split Mechanisms (the core pattern)

There is no single "if macOS" switch — the split happens at several layers. When working on a config, match the layer it already uses:

1. **Which files get symlinked** — the two dotbot configs (`install-mac.conf.yaml`, `install-linux.conf.yaml`) are the source of truth for what is linked on each OS. macOS links `yabai`, `skhd`, `sketchybar`, `~/.Brewfile`; Linux links `niri`, `waybar`, `swaync`, `swaylock`, and the helper `scripts/*` into `~/.local/bin`. **Creating a config file does not deploy it** — you must add a `link:` entry to the relevant dotbot config.
2. **Linux package set** — there is no Linux "Brewfile." Packages live in the `APT_PACKAGES` array and PPA/GitHub-binary sections of `install-linux.sh`. The macOS equivalent is `homebrew/Brewfile`.
3. **Runtime branching inside a shared file** — shell config branches on `[[ "$(uname)" == "Darwin" ]]` (see `zsh/config/exports.sh` for the per-OS PATH, `zsh/.zshrc` for the macOS-only `zsh-patina`).
4. **Per-OS include files** — `kitty/kitty.conf` does `include ${KITTY_OS}.conf`, pulling in `kitty/linux.conf` or `kitty/macos.conf`.

## Architecture

### ZSH (`zsh/`)
- `ZDOTDIR` is set to `~/.config/zsh` via `zshenv` (linked to `~/.zshenv`); everything else loads from there.
- `zsh/.zshrc` is the loader. It sources a small loader-function library (`zsh/user/packages.sh`) that defines `zsh_add_plugin`, `zsh_add_config`, `zsh_add_file`, then pulls in plugins and config modules.
- **Plugins are vendored** (committed under `zsh/plugins/`); `zsh_add_plugin` clones them on first run only if absent.
- Config is modular: `zsh/config/` (exports, aliases, fzf, vim-mode) and `zsh/user/` (prompt, completions, packages). Secrets come from an untracked `~/secrets.sh`; machine-local overrides from `~/.zshrc.local`.
- `_cached_eval` caches slow `eval`-based init (e.g. `fzf --zsh`) under `~/.cache/zsh/`; clear that dir to regenerate.

### Neovim (`neovim/`)
- `init.lua` loads `config.options` → `config.lazy` → `config.keymaps` → `config.autocmds`, and **defers** `config.lsp` + `config.health` until `UIEnter` for faster startup.
- Plugin manager is **Lazy.nvim**; every file in `lua/plugins/` is auto-imported as a plugin spec. `lazy-lock.json` pins versions.
- **LSP is native Neovim 0.11+ — there is no Mason.** Servers are enabled in `lua/config/lsp.lua` via `vim.lsp.enable({...})`; per-server settings live in top-level `neovim/lsp/<name>.lua` files (loaded via Neovim's built-in `lsp/` runtime path). To add a server: create `neovim/lsp/<name>.lua` and add its name to the `vim.lsp.enable` list.
- Ruby/Rails-focused: `ruby_lsp`, DAP debugging via `rdbg` (`lua/plugins/dap.lua`), and `neotest-rspec`. See README.md for the full DAP/neotest/vim-rails keybinding reference.

### Tmux (`tmux/`)
- TPM plugin manager; install plugins with `<prefix> + I` (prefix is `Ctrl+Space`). Config is split into `options.conf`, `keybindings.conf`, `theme.conf`. Many workflows are fzf-driven tmux popups — see the keybinding tables in README.md.

### Desktop stacks
- **macOS**: `yabai` (WM, needs partial SIP disable — see README.md), `skhd` (hotkeys), `sketchybar` (status bar).
- **Linux**: `niri` (scrollable-tiling Wayland compositor, `niri/config.kdl`), `waybar` (bar), `swaync` (notifications), `swaylock`/`swayidle` (lock/idle). Helper scripts in `scripts/` are symlinked into `~/.local/bin`: `niri-raise-or-launch` (fuzzel `--launch-prefix` raise-or-launch via niri IPC), `niri-polkit-agent`, `brave-profile`, `flatpak-kill-menu`.

## Common Commands

```bash
stylua neovim/lua/          # format Lua (config: neovim/stylua.toml)
yamllint install-mac.conf.yaml install-linux.conf.yaml

editdots                    # alias: open the repo in nvim
zsh:reload                  # re-source ~/.config/zsh/.zshrc
brew:dump                   # macOS: regenerate homebrew/Brewfile from installed packages
brew:bundle                 # macOS: install from ~/.Brewfile

# macOS desktop service reloads (aliases)
yabai:reload   skhd:reload

# Neovim health check
nvim --headless -c "checkhealth" -c "q"
```

## devmode (macOS only)

`scripts/devmode.sh` (invoked via the `/devmode on|off|status` skill) toggles the macOS desktop chrome — yabai, skhd, sketchybar, and cosmetic `defaults` — capturing and restoring prior state. It is macOS-specific; there is no Linux equivalent.

## Conventions

- Linux installs prefer user-local paths (`~/.local/bin`, `~/.local/share`, `~/.local/<app>.app`); `/usr/local/bin` is used only for thin symlinks into those payloads.
- Comments in `install-linux.sh` and `scripts/niri-raise-or-launch` document *why* non-obvious choices were made (masked waybar service, PPA pins, PWA app_id matching) — read them before changing that behavior.
