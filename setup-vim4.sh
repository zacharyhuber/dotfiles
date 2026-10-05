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

# This host has no genuine upstream IPv6 (ISP's 6RD is broken/absent), so
# leaving forwarding enabled just gets Tailscale exit-node clients to
# attempt (and fail) real IPv6 instead of falling back to IPv4 cleanly.
#
# The sysctl write below is confirmed permanently blocked in this
# container: even with NET_ADMIN+SYS_ADMIN and host networking, Docker's
# default AppArmor profile denies /proc/sys/net/** writes regardless of
# capabilities. Kept only as a documented no-op in case that profile ever
# loosens. The durable fix lives outside any container entirely: a
# NetworkManager keyfile disabling IPv6 on eth0, imported via HAOS's
# CONFIG-USB mechanism at boot (see README). Until/separately from that,
# this also inserts an ip6tables REJECT rule — unlike the sysctl write,
# netfilter rule changes only need NET_ADMIN, no AppArmor block applies.
# ip6tables itself isn't installed in THIS container's image though, so
# this shells out via `docker exec` into the Tailscale add-on's own
# container, which already ships it and shares the same host network
# namespace (host-network mode), so the rule lands in the real host's
# netfilter tables either way. If that container's name/slug ever changes
# (add-on reinstall), this warns instead of failing the whole script.
# Idempotent: -C checks before inserting, so repeat boots don't stack
# duplicate rules.
setup_disable_ipv6_forwarding() {
	echo "net.ipv6.conf.all.forwarding=0" >/etc/sysctl.d/99-disable-ipv6-forwarding.conf
	sysctl -w net.ipv6.conf.all.forwarding=0 2>&1 || warn "sysctl write blocked (expected under AppArmor confinement, see comment above)"

	ts_container=app_a0d7b954_tailscale
	if ! sudo docker ps -q -f "name=^${ts_container}\$" | grep -q .; then
		warn "$ts_container not running, skipping ip6tables mitigation"
		return 1
	fi
	if ! sudo docker exec "$ts_container" ip6tables -C FORWARD -i tailscale0 -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null; then
		sudo docker exec "$ts_container" ip6tables -I FORWARD 1 -i tailscale0 -j REJECT --reject-with icmp6-adm-prohibited
	fi
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

# Claude Code session state. ~/.claude is wiped on rebuild, so the history
# worth keeping (transcripts, resume index, file-history for /rewind, plans,
# todos) lives in /data/claude-state and is symlinked back into ~/.claude.
# Deliberately NOT persisted: .credentials.json (login stays a manual step,
# so no token sits on /data), caches/plugins/downloads (re-fetchable), and
# sessions/ + shell-snapshots/ + session-env/ (per-process, stale after a
# restart). Config (settings.json) comes from the repo, see above.
# First boot after this step is added: anything already in ~/.claude is moved
# into /data/claude-state rather than discarded.
CLAUDE_STATE=/data/claude-state
CLAUDE_PERSIST="projects file-history plans todos history.jsonl"
setup_claude_state() {
	mkdir -p "$CLAUDE_STATE" "$HOME_DIR/.claude"
	chmod 700 "$CLAUDE_STATE"
	for name in $CLAUDE_PERSIST; do
		live="$HOME_DIR/.claude/$name"
		kept="$CLAUDE_STATE/$name"
		[ -L "$live" ] && [ "$(readlink "$live")" = "$kept" ] && continue
		if [ -e "$live" ] && [ ! -L "$live" ]; then
			if [ -e "$kept" ]; then
				mv "$live" "$live.bak.$(date +%s)" # both exist: keep /data's, don't merge blindly
			else
				mv "$live" "$kept"
			fi
		fi
		case "$name" in
		*.jsonl) [ -e "$kept" ] || : >"$kept" ;;
		*) mkdir -p "$kept" ;;
		esac
		ln -sfn "$kept" "$live"
	done
}

# User-mode tailscaled (separate tailnet device from the HA Tailscale add-on,
# which owns the real tailscale0 interface — hence userspace-networking, so
# the two don't fight over tun/routes). The binary comes from the add-on's
# "packages" option (apk tailscale); only the identity/state lives in /data
# so it survives rebuilds. State is a credential: if /data/tailscale already
# holds an authenticated session, tailscaled comes up Running by itself. On a
# first run (or after state is wiped) it needs one login: export TS_AUTHKEY
# for the add-on, or run `tailscale up --ssh --hostname=$TS_HOSTNAME` by hand
# and open the printed URL. --ssh enables Tailscale SSH in userspace mode.
TS_STATE=/data/tailscale
TS_HOSTNAME=vim4-dev
setup_tailscaled() {
	if ! command -v tailscaled >/dev/null 2>&1; then
		warn "tailscaled not installed (add 'tailscale' to add-on packages), skipping"
		return 1
	fi
	mkdir -p "$TS_STATE" /run/tailscale
	if ! pgrep -x tailscaled >/dev/null 2>&1; then
		nohup tailscaled --statedir="$TS_STATE" --tun=userspace-networking \
			>/var/log/tailscaled.log 2>&1 &
	fi
	# wait for the daemon socket (up to ~15s) without blocking boot longer
	i=0
	until tailscale status >/dev/null 2>&1 || [ "$(tailscale status 2>&1 | grep -c 'Logged out\|Log in')" -gt 0 ]; do
		i=$((i + 1))
		[ "$i" -ge 15 ] && {
			warn "tailscaled socket not ready, see /var/log/tailscaled.log"
			return 1
		}
		sleep 1
	done
	if tailscale status >/dev/null 2>&1; then
		return 0 # already authenticated and running
	fi
	# not logged in: use an auth key if provided, else print a login URL to the log
	tailscale up --reset --ssh --hostname="$TS_HOSTNAME" --advertise-tags=tag:devcontainer --timeout=10s \
		${TS_AUTHKEY:+--authkey="$TS_AUTHKEY"} >>/var/log/tailscaled.log 2>&1 ||
		warn "tailscale not logged in: run 'tailscale up --ssh --hostname=$TS_HOSTNAME' and open the URL"
}

setup_git_identity || warn "git identity step failed"
setup_development_symlink || warn "~/development symlink step failed"
setup_config_dirs || warn "~/.config symlinks step failed"
setup_zsh_autocomplete || warn "zsh-autocomplete step failed"
setup_zshrc || warn "~/.zshrc step failed"
setup_disable_ipv6_forwarding || warn "ipv6 forwarding mitigation step failed unexpectedly (ip6tables missing/blocked?)"
setup_claude_install || warn "claude code install step failed"
setup_claude_settings || warn "claude code settings step failed"
setup_claude_state || warn "claude code session persistence step failed"
setup_tailscaled || warn "tailscaled step failed"
