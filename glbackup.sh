#!/bin/sh
# glbackup — configuration backup & restore for GL.iNet / OpenWrt routers
#
# Runs ON the router (busybox sh, stock firmware, no extra packages).
# GL.iNet's admin panel has no backup button; this fills the gap.
#
#   backup   save the same file set LuCI's "Generate archive" saves
#   restore  put an archive back, to the correct locations, with a safety net
#   diff     show what a restore would change, without touching anything
#
# It uses the firmware's own `sysupgrade -l` / `sysupgrade -b`, so it always
# follows the keep-lists of the firmware you're running (GL.iNet's included).
#
# Quick start (SSH into the router, then):
#     sh glbackup.sh backup
#     sh glbackup.sh ls
#     sh glbackup.sh diff    /root/backups/<archive>.tar.gz
#     sh glbackup.sh restore /root/backups/<archive>.tar.gz
#
# Run `sh glbackup.sh help` for everything.

VERSION="1.0.0"

BACKUP_DIR="${GLB_DIR:-/root/backups}"
ROOT="${GLB_ROOT:-/}"            # where restore writes; use --root /tmp/preview to inspect first
CMD=""; FILE=""; LABEL=""; ONLY=""
ASSUME_YES=0; FORCE=0; DO_REBOOT=0; NO_SNAP=0; ASCII="${GLB_ASCII:-0}"

# ───────────────────────── look & feel ─────────────────────────
setup_ui() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    E=$(printf '\033')
    RS="${E}[0m"; B="${E}[1m"; D="${E}[2m"
    RED="${E}[38;5;203m"; GRN="${E}[38;5;114m"; YEL="${E}[38;5;221m"
    BLU="${E}[38;5;75m";  CYN="${E}[38;5;80m";  MAG="${E}[38;5;176m"
  else
    RS=""; B=""; D=""; RED=""; GRN=""; YEL=""; BLU=""; CYN=""; MAG=""
  fi
  if [ "$ASCII" = 1 ]; then
    OK="+"; BAD="x"; WARN="!"; DOT="*"; BAR="#"; BARE="."; TL="+"; TR="+"; BL="+"; BR="+"; H="-"; V="|"
  else
    OK="✔"; BAD="✖"; WARN="▲"; DOT="●"; BAR="█"; BARE="░"; TL="╭"; TR="╮"; BL="╰"; BR="╯"; H="─"; V="│"
  fi
}

repeat() { local i=0 s=""; while [ "$i" -lt "$2" ]; do s="$s$1"; i=$((i + 1)); done; printf '%s' "$s"; }

boxline() { # boxline "ascii text" [style]
  local t="$1" st="${2:-}" w=58 n
  n=${#t}
  printf '  %s%s%s  %s%s%s%s%s%s\n' "$CYN" "$V" "$RS" "$st" "$t" "$RS" "$(repeat ' ' $((w - 2 - n)))" "$CYN" "$V$RS"
}
box() {
  printf '\n  %s%s%s%s\n' "$CYN" "$TL" "$(repeat "$H" 58)" "$TR$RS"
  boxline "$1" "$B"
  boxline "$2" "$D"
  printf '  %s%s%s%s\n\n' "$CYN" "$BL" "$(repeat "$H" 58)" "$BR$RS"
}

ok()   { printf '  %s%s%s  %s  %s%s%s\n' "$GRN" "$OK" "$RS" "$1" "$D" "${2:-}" "$RS"; }
warn() { printf '  %s%s%s  %s  %s%s%s\n' "$YEL" "$WARN" "$RS" "$1" "$YEL" "${2:-}" "$RS"; }
bad()  { printf '  %s%s%s  %s  %s%s%s\n' "$RED" "$BAD" "$RS" "$1" "$RED" "${2:-}" "$RS"; }
note() { printf '     %s%s%s\n' "$D" "$1" "$RS"; }
head2() { printf '\n  %s%s%s\n' "$B" "$1" "$RS"; }
die()  { printf '\n  %s%s %s%s\n\n' "$RED" "$BAD" "$*" "$RS" >&2; exit 1; }

hsize() { awk -v b="$1" 'BEGIN{split("B KiB MiB GiB",u," ");i=1;while(b>=1024&&i<4){b/=1024;i++};f=(i==1)?"%d %s":"%.1f %s";printf f,b,u[i]}'; }
safe()  { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

usage() {
  cat <<EOF
${B}glbackup${RS} v$VERSION — config backup & restore for GL.iNet / OpenWrt routers

${B}Usage${RS}
  sh glbackup.sh <command> [file] [options]

${B}Commands${RS}
  backup              Save the router's configuration to a .tar.gz  (default)
  restore <file>      Restore an archive to the correct locations
  diff    <file>      Show what a restore would change (changes nothing)
  verify  <file>      Check an archive: gzip, checksum, safe paths, key files
  show    <file>      Show what is inside an archive
  ls                  List the backups in the backup folder
  files               Show which files a backup would include right now
  help                This help

${B}Options${RS}
  -o, --out DIR       Backup folder             (default: $BACKUP_DIR)
  -l, --label TEXT    Add a label to the file name (e.g. before-upgrade)
      --only PATH     Restore only this file or folder (repeatable),
                      e.g. --only etc/config/firewall
      --root DIR      Restore into DIR instead of / — a safe way to preview
  -y, --yes           Don't ask for confirmation
      --force         Allow restoring a different model/firmware's archive
      --no-snapshot   Skip the automatic pre-restore backup (not recommended)
      --reboot        Reboot after a successful restore
      --ascii         Plain ASCII output (also: GLB_ASCII=1)

${B}Good to know${RS}
  • A backup holds password hashes and SSH/Wi-Fi keys. Keep it private.
  • By default backups go to the router's internal flash, which is wiped by a
    factory reset. Copy them off the router, or use a USB stick: -o /mnt/sda1/glbackup
  • GL.iNet supports restores only between the same model and firmware version.
  • If a router may be compromised, a restore can bring the attacker's changes
    back. Run 'diff' and review the flagged files first.
EOF
}

# ───────────────────────── plumbing ─────────────────────────
WORK=""
cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT
trap 'cleanup; printf "\n"; exit 130' INT TERM

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done; }

get_info() {
  R_HOST="$(uci -q get system.@system[0].hostname 2>/dev/null)"
  [ -n "$R_HOST" ] || R_HOST="$(cat /proc/sys/kernel/hostname 2>/dev/null)"
  [ -n "$R_HOST" ] || R_HOST="router"
  R_MODEL="$(cat /proc/gl-hw-info/model 2>/dev/null)"
  [ -n "$R_MODEL" ] || R_MODEL="$(cat /tmp/sysinfo/board_name 2>/dev/null | tr ',' '-')"
  [ -n "$R_MODEL" ] || R_MODEL="unknown"
  R_NAME="$(cat /tmp/sysinfo/model 2>/dev/null)"; [ -n "$R_NAME" ] || R_NAME="$R_MODEL"
  R_FW="$(cat /etc/glversion 2>/dev/null)"
  [ -n "$R_FW" ] || R_FW="$( . /etc/openwrt_release 2>/dev/null; printf '%s' "$DISTRIB_RELEASE")"
  [ -n "$R_FW" ] || R_FW="unknown"
}

# Which group does a path belong to? (for the summary)
group_awk='
function grp(p) {
  if (p ~ /^etc\/config\//) return "Settings (etc/config)"
  if (p ~ /^etc\/dropbear\//) return "SSH keys (dropbear)"
  if (p ~ /^etc\/tailscale\//) return "Tailscale"
  if (p ~ /^etc\/wireguard\//) return "WireGuard"
  if (p ~ /^etc\/AdGuardHome\//) return "AdGuard Home"
  if (p ~ /^etc\/(vpn_profiles\.d|openvpn|vpnpolicy_domain)\//) return "VPN profiles"
  if (p ~ /^etc\/(passwd|shadow|group|rc\.local|hosts|profile|shells|inittab|shinit|sysctl\.conf)$/) return "System basics (passwd, shadow, rc.local...)"
  return "Other"
}'

summary_bars() { # reads file names on stdin
  awk -v bar="$BAR" -v bare="$BARE" -v m="$MAG" -v r="$RS" "$group_awk"'
    { c[grp($0)]++ } END {
      for (g in c) { if (c[g] > mx) mx = c[g]; print c[g] "\t" g }
    }' | sort -rn | awk -F'\t' -v bar="$BAR" -v bare="$BARE" -v m="$MAG" -v r="$RS" '
    NR == 1 { mx = $1 }
    { w = int($1 * 18 / mx); if (w < 1) w = 1; s = ""
      for (i = 0; i < 18; i++) s = s (i < w ? bar : bare)
      printf "    %s%s%s %4d  %s\n", m, s, r, $1, $2 }'
}

# ───────────────────────── archive handling ─────────────────────────
# Validates an archive and prepares $WORK/files (regular files + symlinks only).
validate_archive() {
  local f="$1" n1 n2 oddpath oddtype outside
  [ -n "$f" ] || die "this command needs an archive file"
  [ -f "$f" ] || die "no such file: $f"
  gzip -t "$f" 2>/dev/null || die "not a valid gzip archive: $f"
  tar -tzf  "$f" 2>/dev/null | sed 's#^\./##' > "$WORK/names" || die "tar cannot read: $f"
  tar -tzvf "$f" 2>/dev/null | cut -c1 > "$WORK/types"
  n1=$(wc -l < "$WORK/names"); n2=$(wc -l < "$WORK/types")
  [ "$n1" -gt 0 ] || die "the archive is empty"
  [ "$n1" -eq "$n2" ] || die "could not read the archive listing reliably"

  # refuse anything that could write outside the intended place
  oddpath=$(grep -cE '(^/|(^|/)\.\.(/|$)|[^A-Za-z0-9._/@+=,:-])' "$WORK/names" || true)
  [ "${oddpath:-0}" -eq 0 ] || die "the archive has unsafe or unusual file names ($oddpath) — refusing"
  oddtype=$(grep -cvE '^[-ld]$' "$WORK/types" || true)
  [ "${oddtype:-0}" -eq 0 ] || die "the archive contains special files (devices, pipes, hard links) — refusing"

  awk 'NR==FNR { t[FNR] = $0; next } (t[FNR] == "-" || t[FNR] == "l") && $0 !~ /\/$/ { print }' \
    "$WORK/types" "$WORK/names" | sort -u > "$WORK/files"
  [ -s "$WORK/files" ] || die "the archive contains no files"

  outside=$(grep -cvE '^(etc|root|lib/wifi)/' "$WORK/files" || true)
  if [ "${outside:-0}" -gt 0 ] && [ "$FORCE" -ne 1 ]; then
    grep -vE '^(etc|root|lib/wifi)/' "$WORK/files" | head -5 | sed 's#^#     #' >&2
    die "the archive has $outside file(s) outside etc/, root/ and lib/wifi/ — refusing (use --force to override)"
  fi
}

# Reads the .info sidecar (or the file name) into A_HOST/A_MODEL/A_FW/A_DATE.
read_origin() {
  local f="$1" info b
  A_HOST=""; A_MODEL=""; A_FW=""; A_DATE=""
  info="${f%.tar.gz}.info"
  if [ -f "$info" ]; then
    A_HOST=$(sed -n 's/^host=//p'    "$info" | head -n1)
    A_MODEL=$(sed -n 's/^model=//p'  "$info" | head -n1)
    A_FW=$(sed -n 's/^fw=//p'        "$info" | head -n1)
    A_DATE=$(sed -n 's/^created=//p' "$info" | head -n1)
  else
    b=$(basename "$f")
    case "$b" in
      glbackup_*_*_fw*_*)
        A_HOST=$(printf '%s' "$b"  | sed -n 's/^glbackup_\([^_]*\)_.*/\1/p')
        A_MODEL=$(printf '%s' "$b" | sed -n 's/^glbackup_[^_]*_\([^_]*\)_fw.*/\1/p')
        A_FW=$(printf '%s' "$b"    | sed -n 's/.*_fw\([^_]*\)_.*/\1/p') ;;
    esac
  fi
}

# Extract to RAM and compare with what is on the router now.
# Needs $WORK/sel (the files to consider). Fills same/changed/new/links in $WORK.
compare_archive() {
  local f="$1" need_kb free_kb x="$WORK/x" a b rf
  if [ ! -d "$x" ]; then
    need_kb=$(( $(gzip -dc "$f" | wc -c) / 1024 + 1 ))
    free_kb=$(df -k "$WORK" | awk 'NR==2 {print $4}')
    [ "$need_kb" -lt $(( ${free_kb:-0} / 2 )) ] || die "not enough free RAM in /tmp to inspect the archive"
    mkdir -p "$x"
    tar -xzf "$f" -C "$x" 2>/dev/null || die "could not unpack the archive for comparison"
  fi
  : > "$WORK/same"; : > "$WORK/changed"; : > "$WORK/new"; : > "$WORK/links"
  ROOT="${ROOT%/}"
  while IFS= read -r rf; do
    if [ -L "$x/$rf" ]; then echo "$rf" >> "$WORK/links"; continue; fi
    [ -f "$x/$rf" ] || continue
    if [ -f "$ROOT/$rf" ]; then
      a=$(sha256sum "$x/$rf" 2>/dev/null | cut -d' ' -f1); b=$(sha256sum "$ROOT/$rf" 2>/dev/null | cut -d' ' -f1)
      if [ -n "$b" ] && [ "$a" = "$b" ]; then echo "$rf" >> "$WORK/same"; else echo "$rf" >> "$WORK/changed"; fi
    else
      echo "$rf" >> "$WORK/new"
    fi
  done < "$WORK/sel"
}

select_files() {
  if [ -n "$ONLY" ]; then
    printf '%s\n' "$ONLY" | sed '/^$/d; s#^/*##; s#/*$##' > "$WORK/only"
    awk 'NR==FNR { p[++n] = $0; next }
         { for (i = 1; i <= n; i++) if ($0 == p[i] || index($0, p[i] "/") == 1) { print; next } }' \
      "$WORK/only" "$WORK/files" > "$WORK/sel"
    [ -s "$WORK/sel" ] || die "--only matched nothing in this archive"
  else
    cp "$WORK/files" "$WORK/sel"
  fi
}

SENSITIVE='^etc/(rc\.local|rc\.d/|init\.d/|hotplug\.d/|crontabs/|uci-defaults/|firewall\.user|passwd$|shadow$|group$|sudoers|dropbear/|config/(dropbear|network|firewall|tailscale)$|tailscale/)'

print_plan() { # needs compare_archive to have run
  local ns nc nn nl
  ns=$(wc -l < "$WORK/same"); nc=$(wc -l < "$WORK/changed"); nn=$(wc -l < "$WORK/new"); nl=$(wc -l < "$WORK/links")
  head2 "What a restore would do"
  printf '    %s=%s %4d  already identical\n' "$D" "$RS" "$ns"
  printf '    %s~%s %4d  would be %sreplaced%s\n' "$YEL" "$RS" "$nc" "$YEL" "$RS"
  printf '    %s+%s %4d  would be %screated%s\n'  "$GRN" "$RS" "$nn" "$GRN" "$RS"
  [ "$nl" -gt 0 ] && printf '    %s·%s %4d  symlinks (not compared)\n' "$D" "$RS" "$nl"
  if [ "$nc" -gt 0 ]; then
    printf '\n  %sReplaced%s\n' "$B" "$RS"
    head -n 40 "$WORK/changed" | sed "s#^#    ${YEL}~${RS} #"
    [ "$nc" -gt 40 ] && note "... and $((nc - 40)) more"
  fi
  if [ "$nn" -gt 0 ]; then
    printf '\n  %sCreated%s\n' "$B" "$RS"
    head -n 40 "$WORK/new" | sed "s#^#    ${GRN}+${RS} #"
    [ "$nn" -gt 40 ] && note "... and $((nn - 40)) more"
  fi
  cat "$WORK/changed" "$WORK/new" | grep -E "$SENSITIVE" > "$WORK/flagged" || true
  if [ -s "$WORK/flagged" ]; then
    printf '\n  %s%s Review before restoring — these control logins, startup or network access:%s\n' "$YEL" "$WARN" "$RS"
    sed "s#^#    ${YEL}!${RS} #" "$WORK/flagged"
    note "If this router may be compromised, a restore can bring back an attacker's changes."
  fi
  printf '\n'
}

# ───────────────────────── backup ─────────────────────────
# make_backup <label> -> sets OUT, OUT_FILES
make_backup() {
  local label="$1" stamp base list="$WORK/listed" nlisted size sum
  mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  umask 077
  stamp="$(date +%Y-%m-%d_%H%M%S)"
  base="glbackup_$(safe "$R_HOST")_$(safe "$R_MODEL")_fw$(safe "$R_FW")_${stamp}"
  [ -n "$label" ] && base="${base}_$(safe "$label")"
  OUT="$BACKUP_DIR/$base.tar.gz"

  sysupgrade -l 2>/dev/null | sed 's#^/##' | sort -u > "$list"
  nlisted=$(wc -l < "$list")
  [ "$nlisted" -gt 0 ] || { bad "Reading the backup file list" "sysupgrade returned nothing"; return 1; }
  ok "Reading the backup file list" "$nlisted files"

  if ! sysupgrade -b "$OUT" >/dev/null 2>"$WORK/bk.err"; then
    rm -f "$OUT"; bad "Creating the archive" "sysupgrade failed"; head -n2 "$WORK/bk.err" | sed 's#^#     #'; return 1
  fi
  [ -s "$OUT" ] || { rm -f "$OUT"; bad "Creating the archive" "empty result"; return 1; }
  chmod 600 "$OUT"
  size=$(wc -c < "$OUT")
  ok "Creating the archive" "$(hsize "$size")"

  gzip -t "$OUT" 2>/dev/null || { bad "Verifying" "archive is not valid gzip"; return 1; }
  tar -tzf "$OUT" 2>/dev/null | sed 's#^\./##; s#^/##; /\/$/d' | sort -u > "$WORK/inarchive"
  OUT_FILES=$(wc -l < "$WORK/inarchive")
  grep -vxF -f "$WORK/inarchive" "$list" > "$WORK/missing" || true
  local miss lacking="" why=""; miss=$(wc -l < "$WORK/missing")
  for must in etc/config/network etc/config/firewall etc/config/dhcp etc/dropbear/authorized_keys etc/shadow; do
    grep -qx "$must" "$WORK/inarchive" || lacking="$lacking $must"
  done
  if [ "$miss" -gt 0 ] || [ -n "$lacking" ]; then
    [ "$miss" -gt 0 ] && why="$miss listed file(s) missing; "
    [ -n "$lacking" ] && why="${why}not in archive:$lacking"
    warn "Verifying" "$OUT_FILES files; $why"
  else
    ok "Verifying" "$OUT_FILES files · gzip OK · key files present"
  fi

  ( cd "$BACKUP_DIR" && sha256sum "$base.tar.gz" > "$base.tar.gz.sha256" )
  sum=$(cut -d' ' -f1 "$BACKUP_DIR/$base.tar.gz.sha256")
  {
    echo "host=$R_HOST"; echo "model=$R_MODEL"; echo "name=$R_NAME"; echo "fw=$R_FW"
    echo "created=$(date '+%Y-%m-%d %H:%M:%S')"; echo "files=$OUT_FILES"; echo "sha256=$sum"; echo "tool=glbackup $VERSION"
  } > "$BACKUP_DIR/$base.info"
  chmod 600 "$BACKUP_DIR/$base.tar.gz.sha256" "$BACKUP_DIR/$base.info"
  ok "Writing checksum" "sha256 $(printf '%s' "$sum" | cut -c1-16)…"
  return 0
}

cmd_backup() {
  need sysupgrade tar gzip sha256sum awk sed
  box "GLBACKUP" "Configuration backup for GL.iNet / OpenWrt   v$VERSION"
  ok "Router" "$R_NAME · $R_HOST · firmware $R_FW"
  make_backup "$LABEL" || exit 1

  head2 "What is inside"
  cat "$WORK/inarchive" | summary_bars
  head2 "Saved"
  printf '    %-9s %s\n' "archive" "$OUT"
  printf '    %-9s %s\n' "size"    "$(hsize "$(wc -c < "$OUT")")  ·  $OUT_FILES files"
  printf '    %-9s %s\n' "restore" "sh $0 restore $OUT"

  usb=$(mount 2>/dev/null | awk '$3 ~ /^\/mnt\// {print $3; exit}')
  case "$BACKUP_DIR" in /mnt/*) ;; *)
    printf '\n  %s%s This copy lives on the router'"'"'s internal flash — a factory reset wipes it.%s\n' "$YEL" "$WARN" "$RS"
    if [ -n "$usb" ]; then note "USB storage found at $usb — next time: sh $0 backup -o $usb/glbackup"
    else note "Copy it off the router, e.g. from your computer:  scp root@$R_HOST:$OUT ."; fi ;;
  esac
  printf '  %s%s Contains password hashes and SSH/Wi-Fi keys. Keep it private.%s\n\n' "$YEL" "$WARN" "$RS"
}

cmd_files() {
  need sysupgrade awk sed
  box "GLBACKUP" "Files a backup would include right now"
  sysupgrade -l 2>/dev/null | sed 's#^/##' | sort -u > "$WORK/listed"
  head2 "Summary ($(wc -l < "$WORK/listed") files)"
  summary_bars < "$WORK/listed"
  head2 "Files"
  sed 's#^#    #' "$WORK/listed"
  printf '\n'
}

cmd_ls() {
  box "GLBACKUP" "Saved backups"
  note "folder: $BACKUP_DIR"
  if ! ls "$BACKUP_DIR"/glbackup_*.tar.gz >/dev/null 2>&1; then note "none yet — run:  sh $0 backup"; printf '\n'; return 0; fi
  printf '    %s%-9s %-19s %-10s %-9s %s%s\n' "$D" "SIZE" "CREATED" "FIRMWARE" "FILES" "NAME" "$RS"
  for f in "$BACKUP_DIR"/glbackup_*.tar.gz; do
    info="${f%.tar.gz}.info"; made="?"; fw="?"; nf="?"
    if [ -f "$info" ]; then
      made=$(sed -n 's/^created=//p' "$info" | head -n1); fw=$(sed -n 's/^fw=//p' "$info" | head -n1); nf=$(sed -n 's/^files=//p' "$info" | head -n1)
    fi
    printf '    %-9s %-19s %-10s %-9s %s\n' "$(hsize "$(wc -c < "$f")")" "$made" "$fw" "$nf" "$(basename "$f")"
  done
  printf '\n'
}

# ───────────────────────── inspect ─────────────────────────
cmd_show() {
  box "GLBACKUP" "Contents of an archive"
  validate_archive "$FILE"
  ok "Archive" "$(basename "$FILE") · $(wc -l < "$WORK/files") files"
  read_origin "$FILE"
  [ -n "$A_FW$A_MODEL$A_HOST" ] && ok "Made on" "${A_HOST:-?} · ${A_MODEL:-?} · firmware ${A_FW:-?} ${A_DATE:+· $A_DATE}"
  head2 "What is inside"; summary_bars < "$WORK/files"
  head2 "Files"; sed 's#^#    #' "$WORK/files"; printf '\n'
}

cmd_verify() {
  local failed=0 must lacking=""
  box "GLBACKUP" "Verify an archive"
  validate_archive "$FILE"
  ok "gzip and file names" "$(wc -l < "$WORK/files") files, all paths safe"
  if [ -f "$FILE.sha256" ]; then
    if ( cd "$(dirname "$FILE")" && sha256sum -c "$(basename "$FILE").sha256" >/dev/null 2>&1 ); then ok "Checksum" "matches $(basename "$FILE").sha256"
    else bad "Checksum" "does NOT match — the file changed since it was saved"; failed=1; fi
  else warn "Checksum" "no .sha256 file next to the archive"; fi
  for must in etc/config/network etc/config/firewall etc/config/dhcp etc/dropbear/authorized_keys etc/shadow; do
    grep -qx "$must" "$WORK/files" || lacking="$lacking $must"
  done
  if [ -n "$lacking" ]; then warn "Key files" "missing:$lacking"; else ok "Key files" "present"; fi
  read_origin "$FILE"
  get_info
  if [ -n "$A_MODEL" ]; then
    if [ "$A_MODEL" = "$R_MODEL" ] && [ "$A_FW" = "$R_FW" ]; then ok "Matches this router" "$R_MODEL · firmware $R_FW"
    else warn "Differs from this router" "archive: ${A_MODEL} fw ${A_FW:-?}  ·  router: ${R_MODEL} fw ${R_FW}"; fi
  else warn "Origin" "unknown (no .info file) — made by something other than glbackup?"; fi
  printf '\n'; [ "$failed" -eq 0 ] || exit 1
}

cmd_diff() {
  need tar gzip sha256sum awk sed
  box "GLBACKUP" "What would a restore change?"
  ok "Router" "$R_NAME · $R_HOST · firmware $R_FW"
  validate_archive "$FILE"
  read_origin "$FILE"
  ok "Archive" "$(basename "$FILE") · $(wc -l < "$WORK/files") files"
  select_files
  compare_archive "$FILE"
  print_plan
  printf '  %sNothing was changed.%s\n\n' "$D" "$RS"
}

# ───────────────────────── restore ─────────────────────────
cmd_restore() {
  need tar gzip sha256sum awk sed
  [ "$(id -u)" = 0 ] || die "restore must run as root"
  box "GLBACKUP" "Restore configuration to the router   v$VERSION"
  ok "Router" "$R_NAME · $R_HOST · firmware $R_FW"
  validate_archive "$FILE"
  read_origin "$FILE"
  ok "Archive" "$(basename "$FILE") · $(wc -l < "$WORK/files") files"

  # integrity
  if [ -f "$FILE.sha256" ]; then
    ( cd "$(dirname "$FILE")" && sha256sum -c "$(basename "$FILE").sha256" >/dev/null 2>&1 ) \
      && ok "Checksum" "matches" || die "checksum mismatch — the archive was modified after it was saved"
  else warn "Checksum" "no .sha256 file — can't confirm the archive is unmodified"; fi

  # compatibility
  mismatch=0
  if [ -n "$A_MODEL" ]; then
    if [ "$A_MODEL" != "$R_MODEL" ]; then bad "Model" "archive is for '$A_MODEL', this router is '$R_MODEL'"; mismatch=1
    elif [ "$A_FW" != "$R_FW" ]; then warn "Firmware" "archive is from $A_FW, router runs $R_FW — GL.iNet supports same-version restores only"; mismatch=1
    else ok "Compatible" "$R_MODEL · firmware $R_FW"; fi
    [ -n "$A_HOST" ] && [ "$A_HOST" != "$R_HOST" ] && warn "Hostname" "archive came from '$A_HOST' (this is '$R_HOST') — network settings such as IPs will be copied too"
  else warn "Origin" "unknown (no .info file) — can't check model or firmware"; fi
  if [ "$mismatch" -eq 1 ] && [ "$FORCE" -ne 1 ]; then die "refusing: model/firmware differ. Re-run with --force if you really mean it."; fi

  select_files
  compare_archive "$FILE"
  print_plan
  total=$(( $(wc -l < "$WORK/changed") + $(wc -l < "$WORK/new") ))
  if [ "$total" -eq 0 ]; then ok "Nothing to do" "the router already matches this archive"; printf '\n'; return 0; fi

  # confirmation
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "no terminal to ask for confirmation — re-run with --yes"
    printf '  Type %sRESTORE%s to put %d file(s) onto %s%s%s: ' "$B" "$RS" "$total" "$B" "${ROOT:-/}" "$RS"
    read -r answer
    [ "$answer" = "RESTORE" ] || die "cancelled — nothing was changed"
    printf '\n'
  fi

  # safety net
  SNAP=""
  if [ "$NO_SNAP" -ne 1 ] && { [ -z "$ROOT" ] || [ "$ROOT" = "/" ]; }; then
    head2 "Safety snapshot of the current state"
    ( LABEL=""; make_backup "pre-restore" ) || die "could not take the pre-restore snapshot — nothing was changed"
    SNAP=$(ls -t "$BACKUP_DIR"/glbackup_*_pre-restore.tar.gz 2>/dev/null | head -n1)
    printf '\n'
  fi

  head2 "Restoring"
  mkdir -p "${ROOT:-/}"
  if [ -n "$ONLY" ]; then
    set -- $(cat "$WORK/sel")
    tar -xzf "$FILE" -C "${ROOT:-/}" "$@" 2>"$WORK/rs.err"
  else
    tar -xzf "$FILE" -C "${ROOT:-/}" 2>"$WORK/rs.err"
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then bad "Writing files" "tar failed"; head -n3 "$WORK/rs.err" | sed 's#^#     #'
    [ -n "$SNAP" ] && note "Your previous state is saved: sh $0 restore $SNAP"; exit 1; fi
  sync
  ok "Writing files" "$total file(s) written"

  compare_archive "$FILE"
  left=$(( $(wc -l < "$WORK/changed") + $(wc -l < "$WORK/new") ))
  if [ "$left" -eq 0 ]; then ok "Verifying" "every restored file matches the archive"
  else warn "Verifying" "$left file(s) differ from the archive after writing"; head -n 10 "$WORK/changed" "$WORK/new" | sed 's#^#     #'; fi

  head2 "Next"
  if [ "${ROOT:-/}" != "/" ]; then note "Restored into ${ROOT} for inspection only. The running router was not touched."
  else
    note "Reboot so every service picks up the restored settings:  reboot"
    [ -n "$SNAP" ] && note "To undo this restore:  sh $0 restore $SNAP"
  fi
  printf '\n'
  if [ "$DO_REBOOT" -eq 1 ] && [ "${ROOT:-/}" = "/" ]; then
    printf '  %sRebooting in 5 seconds (Ctrl-C to cancel)…%s\n' "$YEL" "$RS"; sleep 5; reboot
  fi
}

# ───────────────────────── main ─────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)    [ -n "${2:-}" ] || die "$1 needs a value"; BACKUP_DIR="$2"; shift 2 ;;
    -l|--label)  [ -n "${2:-}" ] || die "$1 needs a value"; LABEL="$2"; shift 2 ;;
    --only)      [ -n "${2:-}" ] || die "$1 needs a value"; ONLY="${ONLY}${2}
"; shift 2 ;;
    --root)      [ -n "${2:-}" ] || die "$1 needs a value"; ROOT="$2"; shift 2 ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    --force)     FORCE=1; shift ;;
    --reboot)    DO_REBOOT=1; shift ;;
    --no-snapshot) NO_SNAP=1; shift ;;
    --ascii)     ASCII=1; shift ;;
    -h|--help)   CMD="help"; shift ;;
    -*)          setup_ui; usage >&2; die "unknown option: $1" ;;
    *)           if [ -z "$CMD" ]; then CMD="$1"; elif [ -z "$FILE" ]; then FILE="$1"; else setup_ui; die "unexpected argument: $1"; fi; shift ;;
  esac
done
[ -n "$CMD" ] || CMD="backup"
setup_ui

WORK="$(mktemp -d /tmp/glbackup.XXXXXX)" || die "cannot create a temp folder in /tmp"

case "$CMD" in
  help)     usage ;;
  backup)   get_info; [ "$(id -u)" = 0 ] || die "backup must run as root"; cmd_backup ;;
  files)    cmd_files ;;
  ls|list)  cmd_ls ;;
  show)     cmd_show ;;
  verify)   cmd_verify ;;
  diff)     get_info; cmd_diff ;;
  restore)  get_info; cmd_restore ;;
  *)        usage >&2; die "unknown command: $CMD" ;;
esac
