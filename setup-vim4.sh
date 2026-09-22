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
set -eu

DOTFILES=/data/development/dotfiles
DEV=/data/development
HOME_DIR=$HOME

# Directories under dotfiles/.config to link into ~/.config. Extend this list
# as new tools get configs added to the repo (e.g. hypr is intentionally
# excluded here — it's desktop-only and not needed on the VIM4).
CONFIG_DIRS="nvim"

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

# git commit identity (~/.gitconfig doesn't survive a rebuild either).
# Uses the GitHub-provided noreply address, not a real email, since this
# repo is public — see https://github.com/zacharyhuber/dotfiles/issues/1
git config --global user.name "zacharyhuber"
git config --global user.email "35816256+zacharyhuber@users.noreply.github.com"

# ~/development -> /data/development
link_dir "$DEV" "$HOME_DIR/development"

# ~/.config/<name> -> dotfiles/.config/<name>
mkdir -p "$HOME_DIR/.config"
for name in $CONFIG_DIRS; do
  link_dir "$DOTFILES/.config/$name" "$HOME_DIR/.config/$name"
done

# zsh-autocomplete: a real copy (not a symlink) in the plugins dir.
plugin_dst="$HOME_DIR/.oh-my-zsh/custom/plugins/zsh-autocomplete"
[ -L "$plugin_dst" ] && rm -f "$plugin_dst"
mkdir -p "$HOME_DIR/.oh-my-zsh/custom/plugins"
if command -v rsync >/dev/null 2>&1; then
  mkdir -p "$plugin_dst"
  rsync -a --delete "$DEV/zsh-autocomplete/" "$plugin_dst/"
else
  rm -rf "$plugin_dst"
  cp -r "$DEV/zsh-autocomplete" "$plugin_dst"
fi

# ~/.zshrc <- dotfiles/VIM4.zshrc (copy, never mv — the source must stay in
# the repo). Back up whatever's currently at ~/.zshrc only if it differs, so
# repeated boots don't pile up backups once they match.
src_zshrc="$DOTFILES/VIM4.zshrc"
dst_zshrc="$HOME_DIR/.zshrc"
if [ -f "$src_zshrc" ]; then
  if [ -e "$dst_zshrc" ] && ! cmp -s "$src_zshrc" "$dst_zshrc"; then
    cp -p "$dst_zshrc" "$dst_zshrc.bak.$(date +%s)"
  fi
  cp "$src_zshrc" "$dst_zshrc"
fi

# Claude Code CLI: install if missing (requires bash, curl, libgcc,
# libstdc++, ripgrep in the add-on's "packages" option). The bundled
# ripgrep binary is glibc-only and fails on musl, so we point Claude Code
# at the apk-installed system ripgrep instead via settings.json — kept in
# the repo since ~/.claude doesn't survive a rebuild either. Auth itself
# (`claude` login) stays a manual, interactive step after each rebuild.
command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash

mkdir -p "$HOME_DIR/.claude"
src_settings="$DOTFILES/claude-settings.json"
dst_settings="$HOME_DIR/.claude/settings.json"
if [ -f "$src_settings" ]; then
  if [ -e "$dst_settings" ] && ! cmp -s "$src_settings" "$dst_settings"; then
    cp -p "$dst_settings" "$dst_settings.bak.$(date +%s)"
  fi
  cp "$src_settings" "$dst_settings"
fi
