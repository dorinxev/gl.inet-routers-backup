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

## After a factory reset: restore your configuration

You pressed Reset (or used the admin panel's reset) and you have a backup **saved off the router**.
This route needs someone at the router (the Reset button, and a cable to it). For a **remote** router,
use "Reset and reinstall" below instead.

1. **Boot and get in.** Connect by cable, open the admin panel (`192.168.8.1` on most GL.iNet routers) and
   set the temporary admin password the wizard asks for. On GL.iNet firmware 4 that password is also the
   SSH `root` password.
2. **Copy the script and the backup onto the router** — keep the three backup files together and don't
   rename them (the `.info` and `.sha256` next to the archive are what enable the checks):
   ```sh
   for f in glbackup.sh glbackup_*; do ssh root@192.168.8.1 "cat > /root/$f" < "$f"; done
   ```
   (`cat` over SSH works even when the router has no SFTP server; `scp -O` also works.)
3. **Check it and preview.** On the router:
   ```sh
   sh glbackup.sh verify  glbackup_<...>.tar.gz
   sh glbackup.sh diff    glbackup_<...>.tar.gz     # almost everything will be "replaced" after a reset
   ```
   Read the flagged files (`rc.local`, `shadow`, `authorized_keys`, `init.d`, `network`, `firewall`, …).
4. **Restore.** `sh glbackup.sh restore glbackup_<...>.tar.gz`, type `RESTORE`.
   A reset doesn't change the firmware version, so the model/firmware check passes if you haven't upgraded
   since the backup. If you have, see the next section.
5. **Before you reboot, know what changes.** The restore brings back your **real admin password, SSH keys,
   LAN IP address and Wi-Fi settings**. After the reboot, log in with the *old* password and look for the router
   at the *old* address, not the temporary one from step 1. The restored settings also include the
   **GoodCloud binding**; to keep the router off the cloud, run this before rebooting:
   `uci set gl-cloud.@cloud[0].enable='0'; uci commit gl-cloud`
6. **Reboot once, and only after** the script prints `Verifying — every restored file matches the archive`.
   Use `reboot` (or `restore … --reboot`). Don't reboot, or cut power, during the restore itself — it takes
   seconds. Many GL.iNet services only read their settings at boot, so a reboot is needed and restarting a
   few services is not enough. Wait a couple of minutes, then reconnect at the restored address.

If you can't reach it afterwards, press Reset again and restore in pieces, leaving the network settings
for last: `restore <archive> --only etc/config/system --only etc/config/dhcp`, then `--only etc/config/network`.

## "Reset and reinstall" — upgrading the firmware with your configuration

Sometimes the vendor tells everyone to **factory reset and install new firmware** (GL.iNet's security notice
of 2026-11-20 does).

> **Remote router?** Use this section, not the one above. The Reset button needs someone standing next to the
> router; this route does not. **Every command below runs on the router, over SSH (or Tailscale)** — the router
> downloads the firmware itself, so nothing has to be copied to it and nobody has to be on site.

Do it in one step with the firmware's own `sysupgrade -f`:

> `sysupgrade -f <backup.tar.gz> <firmware.bin>` flashes the image **and installs your backup as the new
> system's configuration** instead of the old live files.

From reading the firmware scripts (GL.iNet 4.10): the old settings area is rebuilt from the backup rather than
carried over, so this behaves like *reset + restore* with a single reboot. The backup is also unpacked by
the firmware's own first-boot path, which then runs its migration scripts — something a by-hand restore after
booting skips.

1. **Back up and copy it off the router.** `sh glbackup.sh backup -l before-upgrade`, then copy the three files
   to your computer. The copy on the router is wiped if the flash goes wrong.
2. **Review it.** `sh glbackup.sh show <archive>` and `diff`. **For a remote router, make sure the archive
   contains what brings the router back online:** `etc/dropbear/authorized_keys` (SSH), `etc/config/network`,
   and your VPN state (e.g. `etc/tailscale/`). If the router may be compromised, read the flagged files
   carefully: anything in them comes back after the flash. If something looks wrong, don't use that archive.
3. **Get the firmware onto the router and check it.** The `.bin` comes from GL.iNet's download servers
   (`fw.gl-inet.com`). Your router can fetch it directly; the download page
   (`https://dl.gl-inet.com/router/<model>`) is a JavaScript app that reads from a public API, and the commands
   below use the same API. It is **undocumented**, so if it stops working, copy the file link and SHA-256 from the
   download page instead.
   ```sh
   MODEL=$(cat /proc/gl-hw-info/model)                  # e.g. be9300
   curl -fsS "https://firmware-api.gl-inet.com/cloud-api/model/info?model=$MODEL" -o /tmp/fw.json

   # which stable versions exist (newest first)?
   jsonfilter -i /tmp/fw.json -e '@.info[@.stage="RELEASE"].version'

   # take the newest stable one (use [0] only if that is the version you want)
   URL=$(jsonfilter -i /tmp/fw.json -e '@.info[@.stage="RELEASE"].download[0].link'   | head -n1)
   SHA=$(jsonfilter -i /tmp/fw.json -e '@.info[@.stage="RELEASE"].download[0].sha256' | head -n1)
   echo "$URL"

   curl -fL "$URL" -o /tmp/firmware.bin
   echo "$SHA  /tmp/firmware.bin" | sha256sum -c -      # must print: /tmp/firmware.bin: OK
   ```
   The command-line `sysupgrade` does *not* verify GL.iNet's signature (the web UI's upgrade does). The hash
   from the API comes from the same server as the file, so it only catches a damaged download. To also guard
   against a tampered server, compare the SHA-256 with a second source (the download page in your browser,
   or GL.iNet's release announcement). Make sure the version is the one you intend to install.
4. **Dry run** — checks the image and model, flashes nothing:
   ```sh
   sysupgrade -T -f /root/backups/glbackup_<...>.tar.gz /tmp/firmware.bin
   ```
5. **Flash.** Don't add `-n` (that discards the configuration).
   ```sh
   sysupgrade -f /root/backups/glbackup_<...>.tar.gz /tmp/firmware.bin
   ```
   Your SSH session closes, the router flashes and **reboots by itself**. Give it a few minutes and don't
   power it off.
6. **Reconnect** at the restored address and check it. Optional: disable GoodCloud as in the step above.

Things to weigh first:

- **Wait for the fixed firmware.** Don't reinstall the same vulnerable version "to be safe".
- **There may be no second firmware slot.** The Flint 3 checked here has a single `rootfs` partition. A power cut or
  bad image mid-flash can leave it needing a physical U-Boot recovery. Think twice for sites nobody can visit.
- **The image is loaded into RAM** (`/tmp`). If `free` shows less than the image size, reboot first.
- **A different firmware version than the backup's** is outside what GL.iNet supports. This route is the same
  one a normal "keep settings" upgrade takes, but try it on a router you can reach first.
- Prefer the web UI? Reset → set up → upgrade in the UI → `glbackup restore --force` (the firmware versions
  differ). That route skips the first-boot migrations, so check the admin panel afterwards.

## Things to know

- **Backups contain secrets** (password hashes, SSH/Wi-Fi keys). They're saved with mode 600. Keep them private.
- **Copy backups off the router.** `/root/backups` is on internal flash and a factory reset wipes it. Use
  `scp`, or a USB stick: `sh glbackup.sh backup -o /mnt/sda1/glbackup`.
- **Same model and firmware version.** GL.iNet supports restores only that way; `glbackup` enforces it unless `--force`.
- **A compromised router?** A restore can bring the attacker's changes back. Run `diff`, read the flagged files.
- `glbackup` doesn't flash firmware. For upgrades, see "Reset and reinstall" above, or use GL.iNet's own
  "keep settings" path.

## Tested

- Backup, verify, show, diff, partial and full restore, mismatch refusal and malicious-archive refusal:
  against a sandbox with a stubbed `sysupgrade` (POSIX `dash`).
- `files` command on a real Flint 3 (GL-BE9300, firmware 4.9.0, busybox `ash`), read-only.
- The firmware lookup commands (`curl` + `jsonfilter` against the download API, SHA-256 shown) on that Flint 3,
  read-only — the download and `sysupgrade` steps themselves were not run.
- **Not yet tested:** a real backup + restore cycle on hardware, and the two procedures above end to end.
  They are written from the firmware's own scripts (`sysupgrade`, `platform.sh`, GL.iNet 4.10). Try restore with
  `--root /tmp/preview` first.

Licensed under the [MIT License](LICENSE).

Passes `sh -n` / `dash -n`. Plain ASCII output: `--ascii`.
