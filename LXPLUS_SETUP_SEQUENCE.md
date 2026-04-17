# LXPLUS End-to-End Setup

This guide includes all required steps, configuration snippets, and shell-function blocks to complete the local setup.

Following this guide alone sets up:
- Kerberos keytab-based ticket acquisition for CERN
- CERN OTP/TOTP second factor handling
- SSH ControlMaster multiplexing for faster reconnects
- `lxplus_auto` automated 2FA session flow
- `lxfiles` SSHFS mount helper
- mux socket maintenance (`mux-*`) and ticket cleanup helpers

---

## 0) Scope and assumptions

- Shell: `zsh`
- Local OS has OpenSSH and can run `expect`
- You have CERN account access to `lxplus.cern.ch`
- You will store secrets locally and protect permissions

This setup uses:
- Kerberos cache collection: `DIR:$HOME/.krb5cc_shared`
- Keytab location: `~/.keytabs/USERNAME_cern.keytab`
- TOTP secret file: `~/.ssh/cern-totp.secret`

Replace `USERNAME` below with your CERN username.

---

## 1) Install prerequisites

Install the required tools on your local machine:

- `ssh`, `nc`
- Kerberos tools: `kinit`, `klist`, `kdestroy`
- `expect`
- `oathtool`
- `sshfs` (optional but required for `lxfiles`)

Create required directories and permissions:

```bash
mkdir -p ~/.ssh ~/.keytabs ~/.krb5cc_shared
chmod 700 ~/.ssh ~/.keytabs ~/.krb5cc_shared
```

Directory roles:
- `~/.keytabs`: stores the Kerberos keytab
- `~/.krb5cc_shared`: shared cache collection used by SSH and shell helpers
- `~/.ssh`: stores SSH config and the TOTP secret file

---

## 2) Generate CERN keytab and verify Kerberos

### 2.1 Generate keytab on CERN side

```bash
ssh USERNAME@lxplus.cern.ch
cern-get-keytab --keytab ~/USERNAME_cern.keytab --user --login USERNAME
```

### 2.2 Copy keytab to local machine

```bash
scp USERNAME@lxplus.cern.ch:~/USERNAME_cern.keytab ~/
mv ~/USERNAME_cern.keytab ~/.keytabs/USERNAME_cern.keytab
chmod 600 ~/.keytabs/USERNAME_cern.keytab
```

### 2.3 Validate keytab locally

```bash
kdestroy
kinit -kt ~/.keytabs/USERNAME_cern.keytab USERNAME@CERN.CH
klist
```

Why this is required:
- Confirms the local keytab can obtain a CERN ticket without a password prompt.

---

## 3) Register CERN 2FA device and capture TOTP secret

### 3.1 Register device in CERN Users Portal

1. Open: `https://users-portal.web.cern.ch/`
2. Start new OTP device registration (for laptop use).
3. Portal shows a QR code (typically intended for mobile authenticator apps).

### 3.2 Convert QR to text and extract secret

- Scan QR and convert to text using any QR decoding tool.
- Result format is an `otpauth://...` URI, for example:

```text
otpauth://totp/CERN:USERNAME?secret=INTXIF3WNJSVESRSK4YUIR3FMRGAO4PW&digits=6&algorithm=SHA1&issuer=CERN&period=30
```

- Extract the value of `secret=...`.

### 3.3 Validate OTP with `oathtool`

```bash
oathtool --totp -b INTXIF3WNJSVESRSK4YUIR3FMRGAO4PW
```

- Use the generated code during portal registration when prompted.

### 3.4 Save secret for shell helper usage

Create `~/.ssh/cern-totp.secret` containing only the Base32 secret value:

```bash
printf '%s\n' 'INTXIF3WNJSVESRSK4YUIR3FMRGAO4PW' > ~/.ssh/cern-totp.secret
chmod 600 ~/.ssh/cern-totp.secret
```

Check file-based OTP generation:

```bash
oathtool --totp -b -- "$(tr -d '[:space:]' < ~/.ssh/cern-totp.secret)"
```

Why this is required:
- `lxplus_auto` and `lxplus` use this file to compute OTP codes on demand.

---

## 4) Add SSH config

Edit `~/.ssh/config` and add this block exactly (replace `USERNAME` in all relevant fields):

```sshconfig
# Primary lxplus entry; ProxyCommand preflights Kerberos cache+tickets before TCP connect.
Host lxplus lxplus.cern.ch lxplus_vscode
  HostName lxplus.cern.ch
  User USERNAME

  # Force Kerberos auth path and delegate creds to remote side.
  GSSAPIAuthentication yes
  GSSAPIDelegateCredentials yes
  PreferredAuthentications gssapi-with-mic,keyboard-interactive

  # SSH mux socket reuse for fast reconnect and fewer repeated auth handshakes.
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 300

  # Keep long-lived sessions healthy.
  ServerAliveInterval 120
  ServerAliveCountMax 5
  Compression yes

  ForwardX11 no
  ForwardX11Trusted no

  # Pre-connect hook:
  # 1) pin cache collection
  # 2) ensure cache dir exists
  # 3) if no TGT, kinit from keytab
  # 4) open TCP stream via netcat
  ProxyCommand /bin/bash -lc "export KRB5CCNAME=DIR:$HOME/.krb5cc_shared; mkdir -p $HOME/.krb5cc_shared; chmod 700 $HOME/.krb5cc_shared 2>/dev/null || true; klist -s || kinit -l 168h -r 30d -k -t $HOME/.keytabs/USERNAME_cern.keytab USERNAME@CERN.CH; exec nc %h %p"

# Optional numbered host targets (lxplusNNN.cern.ch) with same auth/mux policy.
Host lxplus??? lxplus???.cern.ch
  User USERNAME

  GSSAPIAuthentication yes
  GSSAPIDelegateCredentials yes
  PreferredAuthentications gssapi-with-mic,keyboard-interactive

  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 300

  ServerAliveInterval 120
  ServerAliveCountMax 5
  Compression yes

  ForwardX11 no
  ForwardX11Trusted no

  ProxyCommand /bin/bash -lc "export KRB5CCNAME=DIR:$HOME/.krb5cc_shared; mkdir -p $HOME/.krb5cc_shared; chmod 700 $HOME/.krb5cc_shared 2>/dev/null || true; klist -s || kinit -l 168h -r 30d -k -t $HOME/.keytabs/USERNAME_cern.keytab USERNAME@CERN.CH; exec nc %h %p"
```

What this config does:
- Enforces the GSSAPI authentication path
- Reuses multiplexed SSH connections
- Runs keytab-based Kerberos preflight before opening TCP

---

## 5) Add shell functions to your `.zshrc`

Add the following block directly to your `~/.zshrc` (replace `USERNAME` where applicable):

```zsh
# ---------- Identity ----------
# Single source of truth for user principal material.
KERBEROS_USER="USERNAME"
typeset -g LAST_KRB5CCNAME=""

# ---------- Cache helpers ----------
# Returns cache collection root; every ticket op pins to this namespace.
cc_root() {
  printf 'DIR:%s/.krb5cc_shared' "$HOME"
}

# Ensures cache collection directory exists with strict permissions.
ensure_ccroot() {
  local dir="$HOME/.krb5cc_shared"
  if [[ ! -d "$dir" ]]; then
    umask 077
    mkdir -p "$dir" || { echo "[✘] Failed to create $dir"; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
  fi
}

# Finds cache path currently bound to target principal from full cache listing.
ccache_for_principal() {
  local principal="$1"
  command klist -A 2>/dev/null | command awk -v P="$principal" '
    /^Ticket cache:/ {
      cache=$0; sub(/^Ticket cache: */,"",cache);
      dp="";
      next
    }
    /^Default principal:/ {
      dp=$0; sub(/^Default principal: */,"",dp);
      if (cache != "" && dp == P) { print cache; exit }
    }'
}

# Defensive permission check: keytab must not be group/world readable.
ensure_keytab_perms() {
  local keytab="$1"
  [[ -f "$keytab" ]] || return 0

  local mode
  mode=$(stat -c %a -- "$keytab" 2>/dev/null) || return 0

  if [[ "${mode[-2,-1]}" != "00" ]]; then
    echo "[⚠] Insecure permissions on $keytab (mode $mode). Fixing to 600."
    command chmod 600 -- "$keytab" 2>/dev/null || {
      echo "[✘] Could not chmod 600 $keytab"
      return 1
    }
  fi
}

# ---------- Ticket destroy / acquire ----------
# Deletes ticket cache for one principal; refuses unsafe cache-path patterns.
destroy_kerberos_ticket() {
  local principal="$1" verbose="$2" cache_path

  [[ "$verbose" == "--verbose" ]] && echo "=== [INFO] Destroying cache for: $principal ==="

  cache_path="$(ccache_for_principal "$principal")"
  if [[ -z "$cache_path" ]]; then
    echo "[ℹ] No ticket found for $principal."
    return 0
  fi

  if [[ "$cache_path" != DIR::* && "$cache_path" != FILE:* && "$cache_path" != KEYRING:* && "$cache_path" != KCM:* ]]; then
    echo "[⚠] Unrecognized cache type: $cache_path (refusing to touch)"
    return 1
  fi

  [[ "$verbose" == "--verbose" ]] && echo "[✔] Cache: $cache_path"

  if KRB5CCNAME="$cache_path" command kdestroy 2>/dev/null; then
    echo "[✔] Kerberos ticket for $principal destroyed."
  else
    echo "[⚠] kdestroy failed for $cache_path."
    if [[ "$cache_path" == DIR::* ]]; then
      local f="$cache_path"
      f="${f#DIR::}"
      f="${f#DIR:}"
      if [[ "$f" == "$HOME/.krb5cc_shared/"* ]]; then
        command rm -f -- "$f" && echo "[✔] Manually removed cache file $f."
      else
        echo "[⚠] Refusing to remove unexpected path: $f"
      fi
    fi
  fi

  if [[ -n "$(ccache_for_principal "$principal")" ]]; then
    echo "[⚠] Ticket for $principal still appears present."
  else
    echo "[✓] Ticket for $principal fully removed."
  fi

  [[ "$verbose" == "--verbose" ]] && echo "=== [END OF DEBUG] ==="
}

# Ticket state machine:
# - reuse if valid
# - renew if expired but renewable
# - else kinit from keytab
# - final fallback: interactive password kinit
get_kerberos_ticket() {
  local principal="$1" keytab="$2"
  local realm="${principal##*@}"
  local current_cache="" default_principal="" exp="" ren=""
  local found=0

  ensure_ccroot || return 1
  local collection; collection="$(cc_root)"
  if [[ -z "$collection" || "$collection" == "DIR:" ]]; then
    echo "[✘] Internal error: empty collection root."
    return 1
  fi

  current_cache="" exp="" ren="" default_principal="" found=0
  while IFS= read -r line; do
    if [[ "$line" == Ticket\ cache:* ]]; then
      current_cache="${line#Ticket cache: }"
      default_principal=""
      continue
    fi

    if [[ "$line" == Default\ principal:* ]]; then
      default_principal="${line#Default principal: }"
      continue
    fi

    if [[ "$default_principal" == "$principal" && "$line" == *"krbtgt/$realm"* ]]; then
      exp=$(command awk '{print $3 " " $4}' <<< "$line")
      found=1
      break
    fi
  done < <(command klist -A 2>/dev/null)

  if (( found == 1 )) && [[ -n "$current_cache" ]]; then
    ren=$(KRB5CCNAME="$current_cache" command klist -f 2>/dev/null | command awk '/renew until/ {print $3 " " $4; exit}')
    [[ -z "$ren" ]] && ren="(unknown)"

    local epoch_exp epoch_ren=0 epoch_now
    epoch_exp=$(command date -d "$exp" +%s 2>/dev/null || echo 0)
    if [[ "$ren" != "(unknown)" ]]; then
      epoch_ren=$(command date -d "$ren" +%s 2>/dev/null || echo 0)
    fi
    epoch_now=$(command date +%s)

    if (( epoch_exp > epoch_now )); then
      echo "[✔] $principal ticket valid (expires: $exp | renewable until: $ren)"
      LAST_KRB5CCNAME="$current_cache"
      return 0
    fi

    if (( epoch_ren > epoch_now )); then
      echo "[⟳] $principal ticket expired, attempting renewal..."
      if KRB5CCNAME="$current_cache" command kinit -R 2>/dev/null; then
        echo "[✔] Ticket successfully renewed."
        LAST_KRB5CCNAME="$current_cache"
        return 0
      else
        echo "[!!] Ticket renewal failed."
      fi
    else
      echo "[✘] Ticket expired and not renewable."
    fi
  else
    echo "[✘] No valid ticket found for $principal."
  fi

  echo "[→] Obtaining new ticket for $principal..."
  destroy_kerberos_ticket "$principal"

  if [[ -f "$keytab" ]]; then
    ensure_keytab_perms "$keytab" || return 1

    if KRB5CCNAME="$collection" command kinit -l 168h -r 30d -k -t "$keytab" "$principal"; then
      echo "[✔] Ticket obtained via keytab."
      LAST_KRB5CCNAME="$(ccache_for_principal "$principal")"
      [[ -n "$LAST_KRB5CCNAME" ]] || LAST_KRB5CCNAME="$collection"
      return 0
    else
      echo "[!!] Keytab authentication failed; falling back to password prompt."
    fi
  fi

  if KRB5CCNAME="$collection" command kinit -l 168h -r 30d "$principal"; then
    echo "[✔] Ticket obtained via password prompt."
    LAST_KRB5CCNAME="$(ccache_for_principal "$principal")"
    [[ -n "$LAST_KRB5CCNAME" ]] || LAST_KRB5CCNAME="$collection"
    return 0
  else
    echo "[!!] Password login failed for $principal."
    return 1
  fi
}

# ---------- SSH option / host helpers ----------
# Emits mux/no-mux ssh options; nomux hard-disables ControlPath attachment.
ssh_opts_for_mux() {
  local use_mux="${1:-1}"
  local -a opts
  if [[ "$use_mux" -eq 1 ]]; then
    opts=()
  else
    opts=(-o ControlMaster=no -o ControlPath=none -o ControlPersist=no)
  fi
  print -r -- "${opts[@]}"
}

# Normalizes host arg:
# "" -> lxplus.cern.ch, 953 -> lxplus953.cern.ch, lxplus953 -> lxplus953.cern.ch
lxplus_host_from_arg() {
  local arg="$1"
  if [[ -z "$arg" ]]; then
    print -r -- "lxplus.cern.ch"
    return 0
  fi

  arg="${arg%.cern.ch}"

  if [[ "$arg" == <-> ]]; then
    print -r -- "lxplus${arg}.cern.ch"
    return 0
  fi

  if [[ "$arg" == lxplus<-> ]]; then
    print -r -- "${arg}.cern.ch"
    return 0
  fi

  print -r -- "${arg}.cern.ch"
}

# Generic Kerberos-first interactive SSH wrapper used by lxplus().
remote_ssh_login() {
  local get_ticket_func="$1"
  local host="$2"
  local fallback_ok="${3:-0}"
  shift 3

  local -a extra_ssh_opts
  extra_ssh_opts=("$@")

  if ! $get_ticket_func; then
    if [[ "$fallback_ok" -eq 1 ]]; then
      echo "[⚠] Kerberos ticket not obtained; continuing with SSH fallback auth."
    else
      echo "[✘] SSH aborted: Kerberos authentication failed."
      return 1
    fi
  fi

  local cc="${LAST_KRB5CCNAME:-$(cc_root)}"

  echo "Connecting to $host ..."
  KRB5CCNAME="$cc" command ssh -XYACv \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    "${extra_ssh_opts[@]}" \
    "$KERBEROS_USER@$host"
}

# Generic Kerberos-first SSHFS mount wrapper used by lxfiles().
sshfs_mount() {
  local get_ticket_func="$1"
  local remote="$2"
  local mountpoint="${3:-$HOME/$(basename "$remote")}"
  local fallback_ok="${4:-0}"
  local remote_dir="${5:-/}"
  shift 5

  local -a extra_ssh_opts
  extra_ssh_opts=("$@")

  if ! $get_ticket_func; then
    if [[ "$fallback_ok" -eq 1 ]]; then
      echo "[⚠] Kerberos ticket not obtained; continuing with SSH fallback auth."
    else
      echo "[✘] Mount aborted: Kerberos authentication failed."
      return 1
    fi
  fi

  command mkdir -p -- "$mountpoint"

  if mount | command grep -q -- "$mountpoint"; then
    echo "[ℹ] Already mounted at $mountpoint"
    return 0
  fi

  local cc="${LAST_KRB5CCNAME:-$(cc_root)}"
  local -a ssh_cmd
  ssh_cmd=(ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "${extra_ssh_opts[@]}")
  local ssh_cmd_str
  ssh_cmd_str="${(j: :)${(q)ssh_cmd[@]}}"

  echo "[…] Mounting $remote_dir from $remote to $mountpoint"
  if KRB5CCNAME="$cc" command sshfs \
       -o reconnect,auto_cache,follow_symlinks \
       -o "ssh_command=$ssh_cmd_str" \
       "$KERBEROS_USER@$remote:$remote_dir" "$mountpoint"; then
    echo "[✔] Mounted successfully at $mountpoint"
    return 0
  else
    echo "[!!] SSHFS mount failed."
    return 1
  fi
}

# ---------- CERN-specific wrappers ----------
# Realm-specific adapters on top of generic ticket lifecycle helpers.
CERN_REALM="CERN.CH"
CERN_PRINCIPAL="$KERBEROS_USER@$CERN_REALM"
CERN_KEYTAB="$HOME/.keytabs/${KERBEROS_USER}_cern.keytab"

get_CERN_kerberos_ticket() {
  get_kerberos_ticket "$CERN_PRINCIPAL" "$CERN_KEYTAB"
}

destroy_cern_ticket() {
  destroy_kerberos_ticket "$CERN_PRINCIPAL"
}

# ---------- TOTP helper ----------
# Reads local secret file and returns current 6-digit CERN OTP.
cern_totp_code() {
  local secret_file="${1:-$HOME/.ssh/cern-totp.secret}"
  local raw secret

  [[ -r "$secret_file" ]] || {
    printf '[✘] TOTP secret file not readable: %s\n' "$secret_file" >&2
    return 1
  }

  command -v oathtool >/dev/null 2>&1 || {
    printf '[✘] oathtool not found.\n' >&2
    return 1
  }

  raw="$(tr -d '[:space:]' < "$secret_file")"

  if [[ "$raw" == otpauth://* ]]; then
    secret="$(printf '%s\n' "$raw" | sed -n 's/.*[?&]secret=\([^&]*\).*/\1/p')"
  else
    secret="$raw"
  fi

  [[ -n "$secret" ]] || {
    printf '[✘] Could not extract TOTP secret from %s\n' "$secret_file" >&2
    return 1
  }

  oathtool --totp -b -- "$secret"
}

# ---------- User commands ----------
# Manual login helper:
# - print OTP for visibility
# - ensure ticket
# - launch interactive ssh
lxplus() {
  local use_mux=1
  local node_arg=""

  if [[ "$1" == "nomux" ]]; then
    use_mux=0
    shift
  fi

  node_arg="${1:-}"
  local host; host="$(lxplus_host_from_arg "$node_arg")"
  local -a mux_opts
  mux_opts=($(ssh_opts_for_mux "$use_mux"))

  local otp; otp="$(cern_totp_code 2>/dev/null)" || return 1
  printf '[2FA] Code: %s (%ss left)\n' "$otp" "$((30 - ($(date +%s) % 30)))"

  remote_ssh_login get_CERN_kerberos_ticket "$host" 1 "${mux_opts[@]}"
}

# SSHFS helper:
# - print OTP for visibility
# - ensure ticket
# - mount remote path to /mnt/lxfiles
lxfiles() {
  local use_mux=1
  local remote_dir="/"

  if [[ "$1" == "nomux" ]]; then
    use_mux=0
    shift
  fi

  remote_dir="${1:-/}"
  local -a mux_opts
  mux_opts=($(ssh_opts_for_mux "$use_mux"))

  local otp; otp="$(cern_totp_code 2>/dev/null)" || return 1
  printf '[2FA] Code: %s (%ss left)\n' "$otp" "$((30 - ($(date +%s) % 30)))"

  sshfs_mount get_CERN_kerberos_ticket "lxplus.cern.ch" "/mnt/lxfiles" 1 "$remote_dir" "${mux_opts[@]}"
}

# Auto-login helper:
# - optional mux fast-path reuse
# - strict Kerberos/GSSAPI auth shape
# - Expect waits for CERN 2FA prompt and injects fresh OTP
lxplus_auto() {
  local use_mux=1
  local node_arg=""
  local host cc rc
  local -a mux_opts
  local ssh_cmd_q

  if [[ "$1" == "nomux" ]]; then
    use_mux=0
    shift
  fi

  local otp; otp="$(cern_totp_code 2>/dev/null)" || return 1
  printf '[2FA] Code: %s (%ss left)\n' "$otp" "$((30 - ($(date +%s) % 30)))"

  node_arg="${1:-}"
  host="$(lxplus_host_from_arg "$node_arg")" || return 1
  mux_opts=($(ssh_opts_for_mux "$use_mux"))

  if (( use_mux )) && command ssh -O check "$host" >/dev/null 2>&1; then
    echo '[✔] Existing lxplus master detected; reusing it'
    command ssh -tt "${mux_opts[@]}" "$host"
    return $?
  fi

  if ! get_CERN_kerberos_ticket; then
    echo '[✘] SSH aborted: Kerberos authentication failed.' >&2
    return 1
  fi

  cc="${LAST_KRB5CCNAME:-$(cc_root)}"
  [[ -n "$cc" ]] || {
    echo '[✘] Internal error: no Kerberos cache selected.' >&2
    return 1
  }

  ssh_cmd_q="$(printf '%q ' \
    ssh -tt \
    "${mux_opts[@]}" \
    -o GSSAPIAuthentication=yes \
    -o GSSAPIDelegateCredentials=yes \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=gssapi-with-mic,keyboard-interactive \
    "$host"
  )"

  SSH_EXPECT_CCACHE="$cc" \
  SSH_EXPECT_SSH_CMD_Q="$ssh_cmd_q" \
  SSH_EXPECT_ZDOTDIR="${ZDOTDIR:-$HOME}" \
  /usr/bin/expect <<'EOF_EXPECT'
set timeout 30
log_user 1
match_max 100000

set ccache    $env(SSH_EXPECT_CCACHE)
set ssh_cmd_q $env(SSH_EXPECT_SSH_CMD_Q)
set zdot      $env(SSH_EXPECT_ZDOTDIR)

proc child_exit {sid} {
    if {[catch {wait -i $sid} result]} { exit 1 }
    set rc [lindex $result 3]
    if {$rc eq ""} { set rc 0 }
    exit $rc
}

proc fresh_otp {zdot} {
    # Avoid OTP rollover edge: wait if token is about to expire.
    set remain [expr {30 - ([clock seconds] % 30)}]
    if {$remain <= 2} { after [expr {($remain + 1) * 1000}] }

    # Call shell helper at send-time so code is fresh.
    set raw [exec env ZDOTDIR=$zdot zsh -ic {cern_totp_code}]
    set otp [string trim $raw]

    if {![regexp {^[0-9]{6}$} $otp]} {
        puts stderr "lxplus_auto: invalid OTP from cern_totp_code: <$otp>"
        exit 97
    }

    return $otp
}

spawn env KRB5CCNAME=$ccache sh -lc "exec $ssh_cmd_q"
set ssh_spawn_id $spawn_id

if {![info exists tty_spawn_id]} {
    puts stderr "\nlxplus_auto: /dev/tty unavailable; cannot attach session to your terminal."
    child_exit $ssh_spawn_id
}

expect_before {
    -re {Enter passphrase for key .*:\s*$} {
        puts stderr "\nlxplus_auto: ssh asked for a key passphrase; unlock the key first."
        exit 96
    }
    -re {(?i)(^|\n).*password:\s*$} {
        puts stderr "\nlxplus_auto: ssh asked for a password; refusing to continue."
        exit 95
    }
}

expect {
    -re {Your 2nd factor \([^)]+\):\s*$} {
        # Minor settle delay improves prompt interaction stability in practice.
        after 250
        send -- "[fresh_otp $zdot]\r"

        set saved_tty [stty -g < /dev/tty]
        stty raw -echo < /dev/tty

        interact \
            -input  $tty_spawn_id -output $ssh_spawn_id \
            -input  $ssh_spawn_id -output $tty_spawn_id

        stty $saved_tty < /dev/tty
        child_exit $ssh_spawn_id
    }

    timeout {
        puts stderr "\nlxplus_auto: timed out before the 2FA prompt."
        child_exit $ssh_spawn_id
    }

    eof {
        child_exit $ssh_spawn_id
    }
}
EOF_EXPECT

  rc=$?
  if (( rc == 0 )); then
    echo '[✔] lxplus session ended normally'
  else
    echo "[✘] lxplus_auto exited with code $rc" >&2
  fi

  return "$rc"
}

# ---------- Mux helpers ----------
# Minimal socket inspector/controller for SSH ControlMaster state.
_mux_usage() {
  cat <<'USAGE'
usage: muxctl <cmd> [options] [socket ...]

cmd:
  ls|list     list live mux masters
  info        inspect mux sockets
  clean       close live masters; prune stale mux sockets
  close       close live masters only
  prune       prune stale mux sockets only
  help        show this help
USAGE
}

_mux_short() {
  case $1 in
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *)         printf '%s\n' "$1" ;;
  esac
}

# Executes control operations (check/exit/channels/...) on a socket path.
_mux_sshctl() {
  local sock=$1 op=$2 timeout_s=${3:-2}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" ssh -F /dev/null -o BatchMode=yes -o ControlMaster=no -o ControlPath="$sock" -o LogLevel=ERROR -O "$op" mux 2>&1
  else
    ssh -F /dev/null -o BatchMode=yes -o ControlMaster=no -o ControlPath="$sock" -o LogLevel=ERROR -O "$op" mux 2>&1
  fi
}

# Classifies socket state: live/stale/hung/nonmux/weird.
_mux_probe() {
  local sock=$1 timeout_s=${2:-2}
  local out rc pid

  [ -S "$sock" ] || { printf 'missing\t-\t-\n'; return 1; }
  [ -O "$sock" ] || { printf 'foreign\t-\t-\n'; return 1; }

  out=$(_mux_sshctl "$sock" check "$timeout_s")
  rc=$?

  case $out in
    *'Master running (pid='*')'*)
      pid=${out#*pid=}; pid=${pid%%)*}; [ -n "$pid" ] || pid='?'
      printf 'live\t%s\t-\n' "$pid"; return 0 ;;
    *'Connection refused'*|*'No such file or directory'*|*'Broken pipe'*|*'Connection reset by peer'*|*'master hello exchange failed'*|*'read from master failed'*)
      printf 'stale\t-\t-\n'; return 1 ;;
    *'mux_client_hello_exchange:'*|*'parse type: incomplete message'*)
      printf 'nonmux\t-\tagent/foreign-protocol\n'; return 1 ;;
  esac

  [ "$rc" = 124 ] 2>/dev/null && { printf 'hung\t-\ttimeout\n'; return 1; }
  printf 'weird\t-\tunknown\n'
  return 1
}

# Main operator command for list/info/close/prune/clean lifecycle.
muxctl() {
  local cmd=${1:-list}; shift || true
  local dir timeout_s dry_run force interactive sock short state pid note
  local -a inputs excludes closed_rows pruned_rows kept_rows live_rows stale_rows

  dir=$HOME/.ssh
  timeout_s=2
  dry_run=0
  force=0
  interactive=0
  excludes=( '/.ssh/agent/' )
  inputs=()

  case $cmd in
    ls|list|info|clean|close|prune|help) ;;
    -h|--help) _mux_usage; return 0 ;;
    *) printf 'muxctl: bad cmd: %s\n' "$cmd" >&2; _mux_usage >&2; return 64 ;;
  esac

  while [ $# -gt 0 ]; do
    case $1 in
      -d) dir=$2; shift 2 ;;
      -t) timeout_s=$2; shift 2 ;;
      -n) dry_run=1; shift ;;
      -f) force=1; shift ;;
      -i) interactive=1; shift ;;
      --) shift; while [ $# -gt 0 ]; do inputs+=("$1"); shift; done ;;
      *) inputs+=("$1"); shift ;;
    esac
  done

  if [ ${#inputs[@]} -eq 0 ]; then
    while IFS= read -r sock; do
      [ -n "$sock" ] || continue
      case "$sock" in *"${excludes[1]}"*) continue ;; esac
      inputs+=("$sock")
    done < <(find "$dir" -xdev -type s -user "$(id -un)" -print 2>/dev/null)
  fi

  for sock in "${inputs[@]}"; do
    short=$(_mux_short "$sock")
    IFS=$'\t' read -r state pid note <<EOF_MUX
$(_mux_probe "$sock" "$timeout_s")
EOF_MUX

    case $cmd in
      ls|list)
        [ "$state" = live ] && live_rows+=("$short") ;;
      info)
        case $state in
          live)  live_rows+=("$short") ;;
          stale) stale_rows+=("$short") ;;
        esac ;;
      close)
        [ "$state" = live ] || continue
        if [ "$dry_run" -eq 1 ]; then closed_rows+=("$short")
        elif _mux_sshctl "$sock" exit "$timeout_s" >/dev/null; then closed_rows+=("$short")
        else kept_rows+=("$short")
        fi ;;
      prune)
        case $state in
          stale|hung)
            if [ "$dry_run" -eq 1 ]; then pruned_rows+=("$short")
            elif [ "$interactive" -eq 1 ]; then rm -i -- "$sock" && pruned_rows+=("$short") || kept_rows+=("$short")
            else rm -f -- "$sock" && pruned_rows+=("$short") || kept_rows+=("$short")
            fi ;;
          weird)
            if [ "$force" -eq 1 ]; then
              rm -f -- "$sock" && pruned_rows+=("$short") || kept_rows+=("$short")
            fi ;;
        esac ;;
      clean)
        case $state in
          live)
            if [ "$dry_run" -eq 1 ]; then closed_rows+=("$short")
            elif _mux_sshctl "$sock" exit "$timeout_s" >/dev/null; then closed_rows+=("$short")
            else kept_rows+=("$short")
            fi ;;
          stale|hung)
            if [ "$dry_run" -eq 1 ]; then pruned_rows+=("$short")
            elif [ "$interactive" -eq 1 ]; then rm -i -- "$sock" && pruned_rows+=("$short") || kept_rows+=("$short")
            else rm -f -- "$sock" && pruned_rows+=("$short") || kept_rows+=("$short")
            fi ;;
          weird)
            [ "$force" -eq 1 ] && { rm -f -- "$sock" && pruned_rows+=("$short") || kept_rows+=("$short"); }
            ;;
        esac ;;
      help)
        _mux_usage; return 0 ;;
    esac
  done

  case $cmd in
    ls|list)
      [ ${#live_rows[@]} -gt 0 ] && { printf 'live %d\n' "${#live_rows[@]}"; printf '%s\n' "${live_rows[@]}"; }
      ;;
    info)
      [ ${#live_rows[@]} -gt 0 ] && { printf 'live %d\n' "${#live_rows[@]}"; printf '%s\n' "${live_rows[@]}"; }
      [ ${#stale_rows[@]} -gt 0 ] && { printf 'stale %d\n' "${#stale_rows[@]}"; printf '%s\n' "${stale_rows[@]}"; }
      ;;
    close|clean|prune)
      [ ${#closed_rows[@]} -gt 0 ] && { printf 'closed %d\n' "${#closed_rows[@]}"; printf '%s\n' "${closed_rows[@]}"; }
      [ ${#pruned_rows[@]} -gt 0 ] && { printf 'pruned %d\n' "${#pruned_rows[@]}"; printf '%s\n' "${pruned_rows[@]}"; }
      [ ${#kept_rows[@]} -gt 0 ] && { printf 'kept %d\n' "${#kept_rows[@]}"; printf '%s\n' "${kept_rows[@]}"; }
      ;;
  esac
}

mux-clean() { muxctl clean "$@"; }
mux-ls()    { muxctl ls    "$@"; }
mux-info()  { muxctl info  "$@"; }
mux-close() { muxctl close "$@"; }
mux-prune() { muxctl prune "$@"; }
```

What this block provides:
- Includes all required local shell logic in your startup file, with no dependency on external project files.

---

## 6) Enable functions in your shell

After adding the block above to `~/.zshrc`, reload your shell:

```bash
exec zsh
```

Sanity checks:

```bash
which lxplus_auto
which cern_totp_code
which mux-clean
```

Expected: each command resolves to a shell function.

Preflight checks (recommended before first real login):

```bash
# Confirm key files exist and are permission-restricted
ls -l ~/.keytabs/USERNAME_cern.keytab ~/.ssh/cern-totp.secret

# Confirm cache root exists
ls -ld ~/.krb5cc_shared

# Confirm SSH config resolves expected host parameters
ssh -G lxplus | rg -n "^(user|hostname|gssapiauthentication|gssapidelegatecredentials|controlmaster|controlpath|controlpersist) "
```

---

## 7) Operational usage

### 7.1 Normal interactive login

```bash
lxplus_auto
```

Sequence performed:
1. Generate OTP from `~/.ssh/cern-totp.secret`.
2. Determine host (`lxplus.cern.ch` by default).
3. Reuse mux master if already running.
4. Ensure Kerberos ticket via keytab/reuse/renew.
5. Start SSH and wait for CERN second-factor prompt.
6. Submit fresh OTP.
7. Attach terminal to SSH session.

### 7.2 Target a specific lxplus node

```bash
lxplus_auto 953
lxplus_auto lxplus953
lxplus_auto lxplus953.cern.ch
```

### 7.3 Disable mux for one call

```bash
lxplus_auto nomux
lxplus nomux
lxfiles nomux /
```

### 7.4 Manual login helper

```bash
lxplus
```

### 7.5 Mount lxplus filesystem via SSHFS

```bash
lxfiles /
lxfiles /eos/user/Y/USERNAME
```

### 7.6 Direct utility function usage

Use these commands when you need to validate one stage of the flow independently.

```bash
# Print current OTP from default secret file
cern_totp_code

# Print OTP from an explicit secret file path
cern_totp_code ~/.ssh/cern-totp.secret

# Acquire/refresh CERN ticket explicitly
get_CERN_kerberos_ticket

# Destroy CERN ticket cache entry
destroy_cern_ticket

# Destroy any principal ticket cache with debug output
destroy_kerberos_ticket USERNAME@CERN.CH --verbose
```

### 7.7 Command parameters

- `lxplus [nomux] [node]`
  - `nomux` disables ControlMaster attach for that invocation.
  - `node` accepts empty/default, numeric suffix (`953`), full short name (`lxplus953`), or FQDN (`lxplus953.cern.ch`).
- `lxplus_auto [nomux] [node]`
  - Same argument semantics as `lxplus`.
  - If mux master exists, attaches immediately; otherwise runs full Kerberos + Expect 2FA flow.
- `lxfiles [nomux] [remote_dir]`
  - `remote_dir` default is `/`.
  - Mount target is `/mnt/lxfiles` in this configuration.

### 7.8 Example commands by scenario

```bash
# Default auto-login to lxplus.cern.ch
lxplus_auto

# Force a new direct session without attaching to an existing mux master
lxplus_auto nomux

# Attach/login to a specific node
lxplus_auto 953

# Manual ssh flow (still ticket-aware)
lxplus
lxplus 953

# SSHFS mount root and user area
lxfiles /
lxfiles /eos/user/Y/USERNAME

# SSHFS mount without mux
lxfiles nomux /eos/user/Y/USERNAME
```

### 7.9 Full command reference

The commands below are intended for direct use in this setup:

```bash
# OTP helper
cern_totp_code [secret_file]

# Ticket helpers
get_CERN_kerberos_ticket
destroy_cern_ticket
destroy_kerberos_ticket PRINCIPAL [--verbose]

# Login helpers
lxplus [nomux] [node]
lxplus_auto [nomux] [node]

# SSHFS helper
lxfiles [nomux] [remote_dir]

# Mux wrappers
mux-ls [muxctl-options-or-socket-paths...]
mux-info [muxctl-options-or-socket-paths...]
mux-clean [muxctl-options-or-socket-paths...]
mux-close [muxctl-options-or-socket-paths...]
mux-prune [muxctl-options-or-socket-paths...]

# Mux core
muxctl {ls|list|info|clean|close|prune|help} [options] [socket...]
```

Additional argument examples:

```bash
# Show OTP from alternate file
cern_totp_code ~/secrets/cern.secret

# Verbose principal cleanup (generic helper)
destroy_kerberos_ticket USERNAME@CERN.CH --verbose

# Direct node targeting with and without mux
lxplus lxplus953
lxplus nomux lxplus953
lxplus_auto lxplus953.cern.ch
lxplus_auto nomux 953
```

---

## 8) Maintenance procedures

### 8.1 Mux sockets

```bash
mux-ls
mux-info
mux-clean
mux-close
mux-prune
```

Use `mux-clean` when master sockets are stale or reuse behaves incorrectly.

Equivalent explicit `muxctl` forms:

```bash
muxctl list
muxctl info
muxctl clean
muxctl close
muxctl prune
```

Supported options in this embedded implementation:

```bash
# Dry-run cleanup (no modifications)
muxctl clean -n

# Interactive prune prompts per socket
muxctl prune -i

# Force prune sockets classified as weird
muxctl prune -f

# Increase control timeout to 5s
muxctl info -t 5

# Scan an alternate directory for socket files
muxctl info -d ~/.ssh

# Operate on specific socket path(s) only
muxctl info ~/.ssh/cm-abc123
muxctl clean ~/.ssh/cm-abc123 ~/.ssh/cm-def456
```

Wrapper forwarding examples (wrappers pass args directly to `muxctl`):

```bash
mux-clean -n
mux-clean -d ~/.ssh -t 4
mux-prune -i -d ~/.ssh
mux-info -t 5 ~/.ssh/cm-abc123
```

### 8.2 Ticket cleanup

```bash
destroy_cern_ticket
```

This removes Kerberos ticket caches for the CERN principal. It does not delete the keytab file.

---

## 9) Failure map

- `oathtool not found`: install `oathtool`.
- `expect` timeout before 2FA prompt: verify network path and CERN auth prompt behavior.
- password prompt in `lxplus_auto`: by design it aborts; fix keytab/GSSAPI path.
- SSH key passphrase prompt in `lxplus_auto`: unlock key beforehand or adjust SSH auth method.
- keytab auth failure: verify keytab path, principal, file permissions (`600`).
- cache errors: verify `~/.krb5cc_shared` exists and has `700` permissions.
- stale mux behavior: run `mux-clean` and reconnect.
- `lxfiles` mount says already mounted: unmount first (`fusermount -u /mnt/lxfiles` on Linux) or choose a different mountpoint by editing `lxfiles`.
- ticket destroy appears ineffective: run `destroy_kerberos_ticket USERNAME@CERN.CH --verbose` to inspect actual cache path selection.

### 9.1 Important flow behaviors

- `lxplus_auto` prints an OTP early for visibility, but at 2FA prompt time it generates a fresh OTP again inside `expect`; this is intentional to avoid rollover timing errors.
- `lxplus_auto` rejects plain password fallback by design; if SSH asks password, treat it as a Kerberos/GSSAPI path failure, not an interactive fallback path.
- `ProxyCommand` may acquire a ticket even if shell helper already did; this duplication is expected and generally harmless.
- `mux` reuse can bypass some prompts by attaching to an existing master; use `nomux` when isolating session behavior.
- `destroy_cern_ticket` removes tickets from cache; it does not alter the keytab file under `~/.keytabs`.

---

## 10) Quick checklist

1. Install required tools.
2. Create secure directories (`~/.ssh`, `~/.keytabs`, `~/.krb5cc_shared`).
3. Generate and copy CERN keytab; set `600`.
4. Register device in CERN Users Portal and extract Base32 secret.
5. Save secret in `~/.ssh/cern-totp.secret`; set `600`.
6. Add SSH config host blocks.
7. Add the shell-function block from this document into `~/.zshrc`.
8. Run `lxplus_auto`.
9. Use `mux-clean` / `destroy_cern_ticket` for maintenance.
