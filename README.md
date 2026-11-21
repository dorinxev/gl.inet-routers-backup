# glbackup

Configuration **backup and restore for GL.iNet routers** (Flint 3, Flint 2, Beryl, Brume, …) and other
OpenWrt devices — a single shell script that runs **on the router**.

GL.iNet's admin panel has no backup button, and LuCI (where the backup lives) can't be opened through
GoodCloud. `glbackup.sh` fills the gap: one file, no packages to install, works over plain SSH.

```text
  ╭──────────────────────────────────────────────────────────╮
  │  GLBACKUP                                                │
  │  Configuration backup for GL.iNet / OpenWrt   v1.0.0     │
  ╰──────────────────────────────────────────────────────────╯

  ✔  Router  GL.iNet BE9300 · flint3 · firmware 4.9.0
  ✔  Reading the backup file list  165 files
  ✔  Creating the archive  <size>
  ✔  Verifying  165 files · gzip OK · key files present
  ✔  Writing checksum  sha256 <first 16 hex digits>…
```

## Install

From your computer (nothing is installed on the router, the script is just copied):

```sh
scp glbackup.sh root@192.168.8.1:/root/
ssh root@192.168.8.1
```

## Use

```sh
sh glbackup.sh backup                  # save a backup (default command)
sh glbackup.sh ls                      # list saved backups
sh glbackup.sh show    <archive>       # what is inside
sh glbackup.sh verify  <archive>       # gzip, checksum, safe paths, key files
sh glbackup.sh diff    <archive>       # what a restore WOULD change — touches nothing
sh glbackup.sh restore <archive>       # put it back (asks first)
sh glbackup.sh files                   # what a backup would include right now
```

Useful options: `-o DIR` (backup folder, default `/root/backups`), `-l LABEL`,
`--only etc/config/firewall` (restore just one file/folder, repeatable),
`--root /tmp/preview` (restore into a scratch folder instead of `/`), `--reboot`, `--yes`.

### What gets backed up

Exactly what LuCI's **System → Backup / Flash Firmware → Generate archive** backs up: the script calls the
firmware's own `sysupgrade -l` / `sysupgrade -b`, so it follows the keep-lists of the firmware you run —
including GL.iNet's (`/lib/upgrade/keep.d/gl-*`): `/etc/config/*`, SSH keys, password hashes, Tailscale,
WireGuard/OpenVPN profiles, AdGuard Home config and more. The archive is a normal `.tar.gz`; LuCI can read
it too.

### What restore does

1. Refuses archives with unsafe paths (`..`, absolute paths, devices) or files outside `etc/`, `root/`, `lib/wifi/`.
2. Checks the SHA-256 sidecar and that the model/firmware match (otherwise needs `--force`).
3. Shows a plan — identical / replaced / created — and **flags files that control logins, startup and
   network access** (`rc.local`, `shadow`, `authorized_keys`, `init.d`, `network`, `firewall`, …).
4. Asks you to type `RESTORE`.
5. Takes a **pre-restore snapshot** of the current state (so you can undo).
6. Writes the files to their original locations, then verifies every file against the archive.
7. Tells you to reboot (or does it with `--reboot`).

Restore only overwrites and adds files; it never deletes anything that isn't in the archive.

## Things to know

- **Backups contain secrets** (password hashes, SSH/Wi-Fi keys). They're saved with mode 600. Keep them private.
- **Copy backups off the router.** `/root/backups` is on internal flash and a factory reset wipes it. Use
  `scp`, or a USB stick: `sh glbackup.sh backup -o /mnt/sda1/glbackup`.
- **Same model and firmware version.** GL.iNet supports restores only that way; `glbackup` enforces it unless `--force`.
- **A compromised router?** A restore can bring the attacker's changes back. Run `diff`, read the flagged files.
- This is not an upgrade tool. For firmware upgrades, GL.iNet's own "keep settings" path is still the
  supported route.

## Tested

- Backup, verify, show, diff, partial and full restore, mismatch refusal and malicious-archive refusal:
  against a sandbox with a stubbed `sysupgrade` (POSIX `dash`).
- `files` command on a real Flint 3 (GL-BE9300, firmware 4.9.0, busybox `ash`), read-only.
- **Not yet tested:** a real backup + restore cycle on hardware. Try restore with `--root /tmp/preview` first.

Licensed under the [MIT License](LICENSE).

Passes `sh -n` / `dash -n`. Plain ASCII output: `--ascii`.
