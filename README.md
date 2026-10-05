# dotfiles

Personal config shared across several environments. Not everything here applies
everywhere — each section below covers one environment and what's actually
environment-specific about it.

## VIM4 / Home Assistant OS (Advanced SSH & Web Terminal add-on)

The VIM4 runs Home Assistant OS. Dev access is through the "Advanced SSH & Web
Terminal" add-on (an Alpine Linux container), reachable as `hassio@homeassistant`
either over the LAN or via `tailscale ssh`. The add-on's container is wiped back
to its base image on rebuild (new packages, changed `authorized_keys`, etc.) —
everything under `/data` (this repo lives at `/data/development/dotfiles`)
survives that; everything else doesn't.

`setup-vim4.sh` recreates the stuff that doesn't survive a rebuild (symlinks,
`~/.zshrc`, Claude Code settings, …). It runs automatically on every container
start via the add-on's `init_commands` option:

```
["sh /data/development/dotfiles/setup-vim4.sh"]
```

It's intentionally idempotent — safe to run on every boot whether or not
anything changed. See the comments in the script itself for the per-step
details; the one worth calling out separately is IPv6.

### Why IPv6 is disabled on this network

The ISP here (AT&T → Lumen/CenturyLink residential fiber) doesn't provide
working IPv6 to residential customers — it's offered to business customers, not
this tier. The VIM4 runs Tailscale as the household's sole exit node, and
Tailscale unconditionally advertises an IPv6 default route (`::/0`) to
exit-node clients regardless of whether the node can actually route it. The
result without this fix: any client using the exit node (e.g. a laptop with
`tailscale up --exit-node=...`) gets a real-looking IPv6 route, attempts a
connection, and it hangs for several seconds before resetting mid-handshake —
instead of cleanly falling back to IPv4 the way it would with no IPv6 route at
all. This cost real debugging time before the cause was pinned down, so it's
worth writing down properly once.

### Why this needed two separate fixes, not one

The obvious fix — `sysctl -w net.ipv6.conf.all.forwarding=0` — is what
`setup-vim4.sh`'s `setup_disable_ipv6_forwarding` step tries first. It is
**permanently blocked** inside this (or any) Supervisor-managed add-on
container: Docker's default AppArmor profile denies `/proc/sys/net/**` writes
regardless of Linux capabilities, even with `NET_ADMIN`/`SYS_ADMIN` and
`--network host`. This isn't a missing-privilege config to fix — only full
`--privileged` mode bypasses it, which isn't something to grant a
network-facing add-on just for this.

So there are two layers:

1. **Container-side mitigation.** `setup_disable_ipv6_forwarding` also
   inserts an idempotent `ip6tables` REJECT rule
   (`-i tailscale0 -j REJECT --reject-with icmp6-adm-prohibited`) on the real
   host's netfilter tables. Netfilter rule changes only need `NET_ADMIN` — no
   AppArmor block applies to them, unlike `/proc/sys` writes. Since
   `ip6tables` isn't installed in this add-on's own image, the step shells out
   via `docker exec` into the Tailscale add-on's container (`ip6tables` is
   hard-coded there as `app_a0d7b954_tailscale`; bump that if the add-on's
   slug ever changes), which already ships it and shares the same host
   network namespace.

   Packet capture on `tailscale0` confirmed this rule works exactly as
   intended: the VIM4 responds to every exit-node SYN toward a real IPv6
   destination with an ICMPv6 "destination unreachable" within ~200ms — it's
   not silently dropping or flapping.

   What it does *not* fix: a macOS client doing `curl -6` (forcing IPv6, no
   fallback) still takes ~4 seconds to report failure, because macOS retries
   the SYN once/second regardless of the ICMPv6 rejection code received —
   tested both `icmp6-no-route` (code 0) and `icmp6-adm-prohibited` (code 1)
   with identical timing. The original theory (macOS treats code 0 as a soft
   error, code 1 as hard) turned out to be false for macOS — that distinction
   is Linux-specific. This is a client-side macOS TCP stack behavior, not
   something fixable from the exit-node side.

   In practice this doesn't matter for real usage: ordinary dual-stack
   requests (anything using Happy Eyeballs — browsers, Node.js, Claude Code's
   own HTTP client) race IPv4 and IPv6 in parallel, so IPv4 wins in well
   under a second regardless of the IPv6 side quietly failing in the
   background. Only tools that force IPv6-only (`curl -6`, `ping6`, etc.) see
   the ~4s delay. Verified: ordinary `curl` to a real endpoint stayed under
   100ms with the exit node active.

2. **Host-level fix (the actual fix).** Home Assistant OS has an officially
   supported mechanism for this: a `CONFIG` folder (FAT32 USB drive, volume
   label exactly `CONFIG`) containing a `network/` subdirectory with
   NetworkManager connection keyfiles, imported automatically at boot and
   persisted into HAOS's own overlay filesystem
   (`/mnt/overlay/etc/NetworkManager/system-connections/`) — surviving both
   reboots and OS updates, independent of any container. This operates below
   the container/AppArmor layer entirely.

   Keyfile (`CONFIG/network/eth0-no-ipv6` on the USB drive):

   ```ini
   [connection]
   id=eth0-no-ipv6
   uuid=03149e47-eb18-491d-b0a0-9444cb530066
   type=802-3-ethernet
   interface-name=eth0

   [ipv4]
   method=auto

   [ipv6]
   method=disabled
   ```

   Must use LF line endings only (not CRLF) — HAOS's importer is strict about
   this. `NetworkManager.conf` edits are explicitly *not* supported by this
   mechanism, only connection keyfiles.

   To reproduce from scratch: format a USB drive FAT32, label it `CONFIG`
   (`fatlabel /dev/sdX1 CONFIG` on Linux), create a `network/` folder on it
   containing the keyfile above (generate a fresh UUID4 if redoing this), plug
   it into the VIM4, and reboot the **host** (Settings → System → Hardware →
   ⋮ → Reboot Host — not just the add-on). The USB drive itself doesn't need
   to stay plugged in after HAOS has imported it into its persistent overlay.

   This file is **not** tracked in this repo — it has no role in the
   container rebuild cycle `setup-vim4.sh` covers, since it operates at the
   HAOS host level, independent of any add-on container. This section is the
   reproduction record for it instead.

## GitHub Codespaces

_TODO: not yet set up from this repo. Placeholder section — fill in once
there's an actual `devcontainer.json`/setup script here._

## Omarchy Linux

Arch + Hyprland (DHH's opinionated setup). `.config/hypr` is Omarchy/desktop-only
and deliberately excluded from the VIM4 symlink list in `setup-vim4.sh` (see
`CONFIG_DIRS` in that script) since it's meaningless on a headless box.

_TODO: fill in the actual bootstrap/symlink story for this environment — which
`.config` dirs apply, how this repo gets cloned/linked on a fresh Omarchy
install, etc._

## Shared across environments

- `starship.toml` — prompt config, used everywhere.
- `.config/nvim` — editor config, used everywhere (linked explicitly per-host
  via each environment's own setup step, e.g. `CONFIG_DIRS` in
  `setup-vim4.sh`).
