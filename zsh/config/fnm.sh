################################################################################
# fnm — Fast Node Manager
################################################################################
# User-local Node version manager. The fnm BINARY is installed by the
# framework-install bootstrap (phase 60) into ~/.local/bin (already on PATH via
# config/exports.sh); this file activates it for interactive shells.
#
# NOT cacheable via _cached_eval: `fnm env` mints a unique per-shell
# FNM_MULTISHELL_PATH on each invocation, so every shell gets its own Node
# selection. Caching would freeze all shells to one shared path and break that
# isolation — so this runs fresh each shell, unlike the fzf eval.
#
# --use-on-cd auto-switches Node when you cd into a dir with .nvmrc / .node-version.
# On Linux, FNM_DIR is pinned to fnm's default to match phase 60's install location;
# on macOS fnm keeps its own default (e.g. a Homebrew install), so we don't override.
if command -v fnm >/dev/null 2>&1; then
  [[ "$(uname)" == "Linux" ]] && export FNM_DIR="$HOME/.local/share/fnm"
  eval "$(fnm env --use-on-cd --shell zsh)"
fi
