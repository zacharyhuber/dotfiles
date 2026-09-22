#!/bin/sh
# VIM4 Alpine add-on bootstrap.
#
# Runs on every container start via the add-on's `init_commands` option:
#   ["sh /data/development/dotfiles/setup-vim4.sh"]
#
# Everything outside /data is reset to the base image whenever the add-on
# container rebuilds (e.g. after changing authorized_keys or packages), so
# this recreates the symlinks/files that live in $HOME. Idempotent: safe to
# run on every boot, whether or not anything actually changed.
#
# Each step below is an independent function, called via `step || warn ...`.
# Under `set -e`, a failing command inside a function that's the left side
# of `||` does NOT abort the script (verified against busybox ash, this
# add-on's actual /bin/sh) — so one missing prerequisite (e.g. a repo that
# hasn't been recloned yet after wiping /data/development) only skips its
# own step instead of silently skipping everything after it.
set -eu

DOTFILES=/data/development/dotfiles
DEV=/data/development
HOME_DIR=$HOME

# Directories under dotfiles/.config to link into ~/.config. Extend this list
# as new tools get configs added to the repo (e.g. hypr is intentionally
# excluded here — it's desktop-only and not needed on the VIM4).
CONFIG_DIRS="nvim"

warn() {
  echo "setup-vim4: WARNING: $*" >&2
}

# link_dir <source> <dest>: make dest a symlink to source. If dest already
# exists as something else (a real file/dir left by the base image, or a
# stale symlink), back it up once instead of silently clobbering it.
link_dir() {
  src=$1
  dst=$2
  if [ -L "$dst" ]; then
    [ "$(readlink "$dst")" = "$src" ] || ln -sfn "$src" "$dst"
  elif [ -e "$dst" ]; then
    mv "$dst" "$dst.bak.$(date +%s)"
    ln -sfn "$src" "$dst"
  else
    ln -sfn "$src" "$dst"
  fi
}

# git commit identity. Belt-and-suspenders: ~/.gitconfig is actually already
# symlinked to /data/.gitconfig by the add-on itself, so this already
# persists on its own — but setting it here means it's also correct on a
# first boot before that symlink exists, or on any other host.
setup_git_identity() {
  git config --global user.name "zacharyhuber"
  git config --global user.email "35816256+zacharyhuber@users.noreply.github.com"
}

# ~/development -> /data/development
setup_development_symlink() {
  if [ ! -d "$DEV" ]; then
    warn "$DEV missing, skipping ~/development symlink"
    return 1
  fi
  link_dir "$DEV" "$HOME_DIR/development"
}

# ~/.config/<name> -> dotfiles/.config/<name>
setup_config_dirs() {
  mkdir -p "$HOME_DIR/.config"
  for name in $CONFIG_DIRS; do
    if [ -d "$DOTFILES/.config/$name" ]; then
      link_dir "$DOTFILES/.config/$name" "$HOME_DIR/.config/$name"
    else
      warn "$DOTFILES/.config/$name missing, skipping ~/.config/$name symlink"
    fi
  done
}

# zsh-autocomplete: a real copy (not a symlink) in the plugins dir. This is
# a third-party clone (github.com/marlonrichert/zsh-autocomplete), not part
# of the dotfiles repo — easy to forget to reclone after a wipe.
setup_zsh_autocomplete() {
  src="$DEV/zsh-autocomplete"
  if [ ! -d "$src" ]; then
    warn "$src missing (reclone marlonrichert/zsh-autocomplete), skipping plugin copy"
    return 1
  fi
  plugin_dst="$HOME_DIR/.oh-my-zsh/custom/plugins/zsh-autocomplete"
  [ -L "$plugin_dst" ] && rm -f "$plugin_dst"
  mkdir -p "$HOME_DIR/.oh-my-zsh/custom/plugins"
  if command -v rsync >/dev/null 2>&1; then
    mkdir -p "$plugin_dst"
    rsync -a --delete "$src/" "$plugin_dst/"
  else
    rm -rf "$plugin_dst"
    cp -r "$src" "$plugin_dst"
  fi
}

# ~/.zshrc <- dotfiles/VIM4.zshrc (copy, never mv — the source must stay in
# the repo). Back up whatever's currently at ~/.zshrc only if it differs, so
# repeated boots don't pile up backups once they match.
setup_zshrc() {
  src_zshrc="$DOTFILES/VIM4.zshrc"
  dst_zshrc="$HOME_DIR/.zshrc"
  if [ ! -f "$src_zshrc" ]; then
    warn "$src_zshrc missing, skipping ~/.zshrc"
    return 1
  fi
  if [ -e "$dst_zshrc" ] && ! cmp -s "$src_zshrc" "$dst_zshrc"; then
    cp -p "$dst_zshrc" "$dst_zshrc.bak.$(date +%s)"
  fi
  cp "$src_zshrc" "$dst_zshrc"
}

# Claude Code CLI install (requires bash, curl, libgcc, libstdc++, ripgrep
# in the add-on's "packages" option). Separate from settings below so a
# network hiccup during install doesn't also block the settings copy.
setup_claude_install() {
  command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash
}

# The bundled ripgrep binary is glibc-only and fails on musl, so we point
# Claude Code at the apk-installed system ripgrep instead via settings.json
# — kept in the repo since ~/.claude doesn't survive a rebuild either. Auth
# itself (`claude` login) stays a manual, interactive step after each
# rebuild, same as `gh auth login` for the gh CLI (~/.config/gh also does
# not persist).
setup_claude_settings() {
  mkdir -p "$HOME_DIR/.claude"
  src_settings="$DOTFILES/claude-settings.json"
  dst_settings="$HOME_DIR/.claude/settings.json"
  if [ ! -f "$src_settings" ]; then
    warn "$src_settings missing, skipping claude settings.json"
    return 1
  fi
  if [ -e "$dst_settings" ] && ! cmp -s "$src_settings" "$dst_settings"; then
    cp -p "$dst_settings" "$dst_settings.bak.$(date +%s)"
  fi
  cp "$src_settings" "$dst_settings"
}

setup_git_identity        || warn "git identity step failed"
setup_development_symlink || warn "~/development symlink step failed"
setup_config_dirs         || warn "~/.config symlinks step failed"
setup_zsh_autocomplete    || warn "zsh-autocomplete step failed"
setup_zshrc               || warn "~/.zshrc step failed"
setup_claude_install      || warn "claude code install step failed"
setup_claude_settings     || warn "claude code settings step failed"
