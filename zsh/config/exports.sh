################################################################################
# Exported Variables
################################################################################

# Build PATH once (last entry has highest priority)
path=(
  $HOME/.opencode/bin # opencode installer hardcodes this dir; not relocatable to .local
  $HOME/.cargo/bin    # rustup proxies; installed --no-modify-path, so PATH is owned here
  $HOME/.local/scripts
  $HOME/.local/bin
  $HOME/.bin
  /usr/local/bin
  $path
)

if [[ "$(uname)" == "Darwin" ]]; then
  path=(
    /opt/homebrew/opt/openssl@3.5/bin
    /opt/homebrew/opt/rustup/bin
    /opt/homebrew/bin
    /opt/homebrew/sbin
    /opt/homebrew/opt/python@3.13/bin
    /opt/homebrew/opt/yarn/bin
    /opt/homebrew/opt/postgresql@15/bin
    $path
  )

  export LIBRARY_PATH=$LIBRARY_PATH:/opt/homebrew/opt/zstd/lib/
  export CXX=/usr/bin/clang++
  export TERMINAL=kitty
  export HOMEBREW_NO_ENV_HINTS=1

  if [[ -z "$JAVA_HOME" ]] && [[ -x /usr/libexec/java_home ]]; then
    export JAVA_HOME=$(/usr/libexec/java_home 2>/dev/null)
  fi
fi

# You may need to manually set your language environment
export LANG=en_US.UTF-8

export EDITOR=nvim
export MANPAGER='nvim +Man!'

# Mobile app
# export NODE_ENV=development

# Increase the function nesting limit to 100 or higher
export FUNCNEST=100

export COLORTERM=truecolor

# Adopt the systemd user ssh-agent socket (Fedora ships all agent units disabled;
# enabled per-machine via framework-install). Guarded so platforms that provide
# their own agent — macOS launchd, Ubuntu's session unit, SSH agent forwarding —
# keep theirs, and machines without the unit enabled are untouched.
if [[ -z "$SSH_AUTH_SOCK" && -S "$XDG_RUNTIME_DIR/ssh-agent.socket" ]]; then
  export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"
fi