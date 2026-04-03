
#######################################
# Functions
#######################################

agupgrade() {
  emulate -L zsh
  setopt local_options err_return pipe_fail no_unset

  local tarball extractor stage="" icon_tmp=""
  local app_dir="/opt/antigravity"
  local wrapper="/usr/local/bin/antigravity"
  local desktop="/usr/local/share/applications/antigravity.desktop"
  local icon="/usr/local/share/pixmaps/antigravity.png"
  local icon_url="https://antigravity.google/assets/image/brand/antigravity-icon__full-color.png"

  local -a entries
  local entry normalized top first_top=""
  local strip_components=0
  local shared_top=1
  local need_icon_download=0
  local ok=1

  if (( $# != 1 )); then
    print -u2 "usage: agupgrade /path/to/Antigravity.tar.gz"
    return 2
  fi

  tarball=${~1}
  tarball=${tarball:A}

  [[ -f "$tarball" ]] || {
    print -u2 "agupgrade: tarball not found: $tarball"
    return 1
  }

  [[ -x "$app_dir/antigravity" ]] || {
    print -u2 "agupgrade: no existing install found at $app_dir"
    print -u2 "agupgrade: this function is upgrade-only; do a fresh install first"
    return 1
  }

  command -v sudo >/dev/null || {
    print -u2 "agupgrade: sudo not found"
    return 1
  }

  sudo -v || {
    print -u2 "agupgrade: sudo authentication failed"
    return 1
  }

  if command -v bsdtar >/dev/null 2>&1; then
    extractor="bsdtar"
  elif command -v tar >/dev/null 2>&1; then
    extractor="tar"
  else
    print -u2 "agupgrade: neither bsdtar nor tar is available"
    return 1
  fi

  stage="$(mktemp -d "${TMPDIR:-/tmp}/agupgrade.XXXXXXXX")" || {
    print -u2 "agupgrade: failed to create staging directory"
    return 1
  }

  trap 'rm -rf -- "$stage" "$icon_tmp"' EXIT INT TERM HUP

  entries=("${(@f)$($extractor -tf "$tarball" 2>/dev/null)}")
  (( ${#entries[@]} > 0 )) || {
    print -u2 "agupgrade: could not read tarball contents"
    return 1
  }

  for entry in "${entries[@]}"; do
    normalized="${entry#./}"
    normalized="${normalized%/}"
    [[ -n "$normalized" ]] || continue

    if [[ "$normalized" != */* ]]; then
      shared_top=0
      break
    fi

    top="${normalized%%/*}"
    if [[ -z "$first_top" ]]; then
      first_top="$top"
    elif [[ "$top" != "$first_top" ]]; then
      shared_top=0
      break
    fi
  done

  (( shared_top )) && strip_components=1

  if (( strip_components )); then
    "$extractor" -xf "$tarball" -C "$stage" --strip-components=1 || {
      print -u2 "agupgrade: extraction failed"
      return 1
    }
  else
    "$extractor" -xf "$tarball" -C "$stage" || {
      print -u2 "agupgrade: extraction failed"
      return 1
    }
  fi

  [[ -x "$stage/antigravity" ]] || {
    print -u2 "agupgrade: extracted archive does not contain expected executable:"
    print -u2 "           $stage/antigravity"
    return 1
  }

  if [[ ! -f "$icon" ]]; then
    need_icon_download=1
    if command -v curl >/dev/null 2>&1; then
      icon_tmp="${stage}/antigravity-icon.png"
      curl -fsSL "$icon_url" -o "$icon_tmp" || {
        print -u2 "agupgrade: icon missing and official icon download failed"
        return 1
      }
    else
      print -u2 "agupgrade: icon missing and curl is not installed"
      return 1
    fi
  fi

  sudo rm -rf "${app_dir}.new" "${app_dir}.prev"
  sudo mkdir -p "${app_dir}.new"

  sudo cp -a "$stage/." "${app_dir}.new/" || {
    print -u2 "agupgrade: failed to copy staged files into ${app_dir}.new"
    sudo rm -rf "${app_dir}.new"
    return 1
  }

  sudo chown -R root:root "${app_dir}.new" || {
    print -u2 "agupgrade: failed to set ownership on ${app_dir}.new"
    sudo rm -rf "${app_dir}.new"
    return 1
  }

  sudo mv "$app_dir" "${app_dir}.prev" || {
    print -u2 "agupgrade: failed to move current install aside"
    sudo rm -rf "${app_dir}.new"
    return 1
  }

  if ! sudo mv "${app_dir}.new" "$app_dir"; then
    print -u2 "agupgrade: failed to activate new install; restoring previous version"
    sudo rm -rf "$app_dir"
    sudo mv "${app_dir}.prev" "$app_dir" 2>/dev/null || true
    sudo rm -rf "${app_dir}.new"
    return 1
  fi

  sudo install -d /usr/local/bin
  sudo tee "$wrapper" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /opt/antigravity/antigravity "$@"
EOF
  sudo chmod 0755 "$wrapper"
  sudo chown root:root "$wrapper"

  sudo install -d /usr/local/share/pixmaps
  if (( need_icon_download )); then
    sudo install -m 0644 "$icon_tmp" "$icon"
    sudo chown root:root "$icon"
  fi

  sudo install -d /usr/local/share/applications
  sudo tee "$desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Antigravity
Comment=Google Antigravity
Exec=antigravity %F
Icon=antigravity
Terminal=false
Categories=Development;IDE;
StartupWMClass=Antigravity
EOF
  sudo chmod 0644 "$desktop"
  sudo chown root:root "$desktop"

  if command -v update-desktop-database >/dev/null 2>&1; then
    sudo update-desktop-database /usr/local/share/applications >/dev/null 2>&1 || true
  fi

  if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
  elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    kbuildsycoca5 >/dev/null 2>&1 || true
  fi

  [[ -x "$app_dir/antigravity" ]] || {
    print -u2 "agupgrade: verification failed: main executable missing"
    ok=0
  }

  [[ -x "$wrapper" ]] || {
    print -u2 "agupgrade: verification failed: wrapper missing"
    ok=0
  }

  [[ -f "$desktop" ]] || {
    print -u2 "agupgrade: verification failed: desktop entry missing"
    ok=0
  }

  [[ -f "$icon" ]] || {
    print -u2 "agupgrade: verification failed: icon missing"
    ok=0
  }

  grep -q '^exec /opt/antigravity/antigravity "\$@"$' "$wrapper" || {
    print -u2 "agupgrade: verification failed: wrapper content incorrect"
    ok=0
  }

  grep -q '^Exec=antigravity %F$' "$desktop" || {
    print -u2 "agupgrade: verification failed: desktop Exec line incorrect"
    ok=0
  }

  grep -q '^Icon=antigravity$' "$desktop" || {
    print -u2 "agupgrade: verification failed: desktop Icon line incorrect"
    ok=0
  }

  if ! command -v antigravity >/dev/null 2>&1; then
    print -u2 "agupgrade: verification failed: antigravity not found in PATH"
    ok=0
  fi

  if (( ok )); then
    print "Antigravity upgrade complete."
    print "Resolved launcher: $(command -v antigravity)"
    antigravity --version 2>/dev/null || true
    sudo rm -rf "${app_dir}.prev"
    return 0
  else
    print -u2 "agupgrade: verification failed; previous install kept at ${app_dir}.prev"
    return 1
  fi
}

termstyle() {
  emulate -L zsh
  setopt local_options local_traps no_aliases pipe_fail extended_glob

  local cols=${COLUMNS:-100}
  local sep
  sep=$(printf '%*s' "$cols" '' | tr ' ' '-')

  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/termstyle.XXXXXX") || {
    print -u2 -- "termstyle: failed to create temp dir"
    return 1
  }
  trap 'rm -rf -- "$tmpdir"' EXIT HUP INT TERM

  local have_git=0
  (( $+commands[git] )) && have_git=1

  print_section() {
    print -P -- "%F{6}${sep}%f"
    print -P -- "%B%F{6}$1%f%b"
  }

  print_section "Terminal identity"
  print -r -- "TERM=$TERM"
  print -r -- "COLORTERM=${COLORTERM:-<unset>}"
  print -r -- "TERM_PROGRAM=${TERM_PROGRAM:-<unset>}"
  print -r -- "ZSH_VERSION=$ZSH_VERSION"
  print -r -- "LANG=${LANG:-<unset>}"
  print -r -- "LC_ALL=${LC_ALL:-<unset>}"
  print -r -- "LS_COLORS=${LS_COLORS:+<set>}${LS_COLORS:-<unset>}"
  print -r -- "GREP_COLORS=${GREP_COLORS:-<unset>}"
  print

  print_section "Default text and attributes"
  printf 'default foreground / default background\n'
  printf '\e[1mbold\e[0m  \e[2mdim\e[0m  \e[3mitalic\e[0m  \e[4munderline\e[0m  \e[7mreverse\e[0m  \e[9mstrike\e[0m\n'
  printf '\e[51mframed\e[0m  \e[53moverline\e[0m  \e[5mblink\e[0m\n'
  print

  print_section "Prompt definitions"
  print -P -- "%F{8}Raw PROMPT:%f"
  print -r -- "${PROMPT-<unset>}"
  if [[ -n ${RPROMPT-} ]]; then
    print -P -- "%F{8}Raw RPROMPT:%f"
    print -r -- "$RPROMPT"
  fi
  if [[ -n ${PS2-} ]]; then
    print -P -- "%F{8}Raw PS2:%f"
    print -r -- "$PS2"
  fi
  if [[ -n ${PS4-} ]]; then
    print -P -- "%F{8}Raw PS4:%f"
    print -r -- "$PS4"
  fi
  print -P -- "%F{8}Your actual live prompt will be visible again after this function returns.%f"
  print

  print_section "ANSI 16-color palette"
  printf 'foregrounds on default background\n'
  local i
  for i in {30..37} {90..97}; do
    printf "\e[%sm %3s \e[0m" "$i" "$i"
  done
  printf '\n'
  printf 'backgrounds\n'
  for i in {40..47} {100..107}; do
    printf "\e[%sm %3s \e[0m" "$i" "$i"
  done
  printf '\n'
  printf 'foregrounds on light background\n'
  for i in {30..37} {90..97}; do
    printf "\e[%s;47m %3s \e[0m" "$i" "$i"
  done
  printf '\n\n'

  print_section "256-color palette"
  printf 'system colors (0-15), color cube (16-231), grayscale (232-255)\n'
  for i in {0..255}; do
    printf "\e[48;5;%sm%3s\e[0m " "$i" "$i"
    (( (i + 1) % 16 == 0 )) && printf '\n'
  done
  print

  print_section "Truecolor gradients"
  printf 'smooth hue ramp\n'
  awk 'BEGIN {
    for (i = 0; i < 72; i++) {
      h = i / 72.0
      r = int(255 * (h < 1.0/6 ? 1 : h < 2.0/6 ? 2 - 6*h : h < 4.0/6 ? 0 : h < 5.0/6 ? 6*h - 4 : 1))
      g = int(255 * (h < 1.0/6 ? 6*h : h < 3.0/6 ? 1 : h < 4.0/6 ? 4 - 6*h : 0))
      b = int(255 * (h < 2.0/6 ? 0 : h < 3.0/6 ? 6*h - 2 : h < 5.0/6 ? 1 : 6 - 6*h))
      if (r < 0) r = 0; if (r > 255) r = 255
      if (g < 0) g = 0; if (g > 255) g = 255
      if (b < 0) b = 0; if (b > 255) b = 255
      printf "\033[48;2;%d;%d;%dm ", r, g, b
    }
    printf "\033[0m\n"
    for (i = 0; i < 72; i++) {
      v = int(i * 255 / 71)
      printf "\033[48;2;%d;%d;%dm ", v, v, v
    }
    printf "\033[0m\n"
  }'
  print -P -- "%F{8}You should see a smooth rainbow bar and a smooth grayscale bar.%f"
  print

  print_section "Hyperlink and glyph check"
  printf '\e]8;;https://example.com\aOSC-8 hyperlink sample\e]8;;\a\n'
  print -r -- 'Unicode: ─ │ ┌ ┐ └ ┘ █ ░ λ μ σ Δ Ω ✓ ✗ → ← ↑ ↓'
  print -r -- 'Nerd Font / powerline:       '
  print

  mkdir -p "$tmpdir/lsdemo/dir" "$tmpdir/lsdemo/public"
  print -r -- 'plain text' > "$tmpdir/lsdemo/file.txt"
  print -r -- '#!/usr/bin/env bash
echo hello' > "$tmpdir/lsdemo/script.sh"
  chmod +x "$tmpdir/lsdemo/script.sh"
  print -r -- 'fake archive' > "$tmpdir/lsdemo/archive.tar.gz"
  print -r -- 'fake image' > "$tmpdir/lsdemo/image.png"
  ln -s file.txt "$tmpdir/lsdemo/link.txt"
  ln -s nowhere "$tmpdir/lsdemo/broken-link"
  mkfifo "$tmpdir/lsdemo/demo.pipe" 2>/dev/null
  chmod 1777 "$tmpdir/lsdemo/public" 2>/dev/null

  print_section "Filesystem colors via ls --color"
  command ls --color=always -lAFh --group-directories-first "$tmpdir/lsdemo"
  print

  print -r -- 'ok: operation completed' > "$tmpdir/grep_demo.txt"
  print -r -- 'warn: cache is stale' >> "$tmpdir/grep_demo.txt"
  print -r -- 'error: failed to open file' >> "$tmpdir/grep_demo.txt"
  print -r -- 'TODO: replace mock path' >> "$tmpdir/grep_demo.txt"
  print -r -- 'FIXME: edge case remains' >> "$tmpdir/grep_demo.txt"

  print_section "grep highlight colors"
  command grep --color=always -nE 'ok|warn|error|TODO|FIXME' "$tmpdir/grep_demo.txt"
  print

  if (( have_git )); then
    print_section "Git native colors"
    mkdir -p "$tmpdir/repo"
    (
      cd "$tmpdir/repo" || exit 1
      command git init -q
      command git config user.name 'termstyle'
      command git config user.email 'termstyle@example.invalid'

      print -r -- $'alpha\nbeta\ngamma' > tracked.txt
      command git add tracked.txt
      command git commit -qm init

      print -r -- $'alpha\nBETA changed\ngamma\ndelta added' > tracked.txt
      print -r -- 'untracked file' > new.txt

      GIT_PAGER=cat PAGER=cat LESS=FRX \
        command git --no-pager \
        -c core.pager=cat \
        -c pager.diff=false \
        -c pager.show=false \
        -c pager.status=false \
        -c interactive.diffFilter=cat \
        status -sb --color=always

      printf '\n'

      GIT_PAGER=cat PAGER=cat LESS=FRX \
        command git --no-pager \
        -c core.pager=cat \
        -c pager.diff=false \
        -c interactive.diffFilter=cat \
        diff --color=always --no-ext-diff -- tracked.txt
    )
    print
  fi

  if (( $+commands[bat] )); then
    print_section "Syntax highlighting via bat"
    cat > "$tmpdir/demo.py" <<'EOF'
from math import sqrt

class Demo:
    def __init__(self, x: float):
        self.x = x

    def value(self) -> float:
        if self.x < 0:
            raise ValueError("x must be non-negative")
        return sqrt(self.x)

print(Demo(9).value())
EOF
    command bat --paging=never --style=plain --color=always "$tmpdir/demo.py"
    print
  fi

  print_section "Manual cursor and selection check"
  print -P -- "%F{8}Leave the cursor on the next line, then drag-select across both lines.%f"
  print -r -- 'The quick brown fox jumps over 13 lazy dogs | [] {} () <> == != <= >='
  print -r -- '0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ _-./:@'
  print

  print -P -- "%F{6}${sep}%f"
}

mux-clean() {
  local sock out
  find "$HOME/.ssh" -type s -print0 2>/dev/null |
  while IFS= read -r -d '' sock; do
    if out=$(ssh -S "$sock" -O exit _ 2>&1); then
      printf 'closed  %s\n' "$sock"
    else
      rm -f -- "$sock" && printf 'removed %s\n' "$sock"
    fi
  done
}

# ──────────────────────────────────────────────────────────────────────────────
#  PIPE LOGGER (Bash) — log the exact LHS command + its output, tee-style
#  Usage (unchanged):
#      [command] | logger /path/to/log.txt
#  To include stderr too, use either:
#      [command] 2>&1 | logger log.txt     # POSIX
#      [command] |& logger log.txt         # Bash shorthand
#  Notes:
#    • Shadows /usr/bin/logger (syslog). Rename LOGGER_FN_NAME or function if needed.
#    • DEBUG trap remembers the left side of the pipe; history fallback covers edge cases.
# ──────────────────────────────────────────────────────────────────────────────
alog() {
    local logfile="$1"
    if [[ -z "$logfile" ]]; then
        echo "Usage: command | logger logfile"
        return 1
    fi

    local my_stdin
    my_stdin=$(readlink /proc/$$/fd/0 2>/dev/null)
    if [[ ! $my_stdin =~ ^pipe: ]]; then
        echo "stdin is not a pipe"
        return 1
    fi

    local writer_pid=""
    for attempt in {1..10}; do
        for pdir in /proc/[0-9]*; do
            local pid=${pdir#/proc/}
            if [[ $pid == $$ ]]; then continue; fi
            local fd1=/proc/$pid/fd/1
            if [[ -e $fd1 ]]; then
                local link=$(readlink /proc/$pid/fd/1 2>/dev/null)
                if [[ $link == $my_stdin ]]; then
                    writer_pid=$pid
                    break 2
                fi
            fi
        done
        sleep 0.01
    done

    local cmd="Unknown command"
    if [[ -n "$writer_pid" && -d /proc/$writer_pid ]]; then
        mapfile -d '' args < /proc/"$writer_pid"/cmdline
        if [[ ${#args[@]} -ge 3 && ${args[0]} == */bash && ${args[1]} == -c ]]; then
            cmd="${args[2]}"
        else
            cmd=""
            for arg in "${args[@]}"; do
                cmd+="$arg "
            done
            cmd="${cmd% }"
        fi
    fi

    echo "Command: $cmd" >> "$logfile"
    tee -a "$logfile"
}

# Function to copy file content or command output to the clipboard
# Usage: xclipin filename or xclipin command [args...]
xclipin() {
    if ! command -v xclip &>/dev/null; then
        echo "Error: xclip not found in PATH"
        return 1
    fi

    if [[ $# -eq 0 ]]; then
        echo "Usage: xclipin <filename>  or  xclipin <command> [args...]"
        return 1
    elif [[ $# -eq 1 && -f $1 ]]; then
        if [[ ! -s $1 ]]; then
            echo "Warning: '$1' is empty — nothing copied"
            return 1
        fi
        xclip -selection clipboard < "$1"
    else
        local output
        output="$("$@" 2>/dev/null)"
        if [[ -z $output ]]; then
            echo "Warning: command output is empty — nothing copied"
            return 1
        fi
        printf "%s" "$output" | xclip -selection clipboard
    fi
}

xclipout() {
  if [[ $# -ne 1 ]]; then
    echo "Usage: xclipout <filename|->"
    return 1
  fi
  if [[ "$1" == "-" ]]; then
    xclip -selection clipboard -o
  else
    xclip -selection clipboard -o > "$1"
  fi
}


extract() {
    local tool="atool"
    local file=""
    
    # Help message
    if [[ "$1" == "-h" || "$1" == "--help" || "$#" -lt 1 ]]; then
        echo "Usage: extract <archive> [tool]"
        echo "Default tool: atool"
        echo "Supported tools: atool, dtrx"
        return 1
    fi

    file="$1"
    [[ -n "$2" ]] && tool="$2"

    if [[ ! -f "$file" ]]; then
        echo "Error: '$file' is not a file."
        return 1
    fi

    case "$tool" in
        atool)
            if command -v aunpack &>/dev/null; then
                aunpack "$file"
            else
                echo "Error: 'aunpack' (atool) is not installed."
                return 1
            fi
            ;;
        dtrx)
            if command -v dtrx &>/dev/null; then
                dtrx "$file"
            else
                echo "Error: 'dtrx' is not installed."
                return 1
            fi
            ;;
        *)
            echo "Error: Unsupported tool '$tool'. Use 'atool' or 'dtrx'."
            return 1
            ;;
    esac
}

# Move up in directory structure
up() {
    local d=""
    limit=$1
    for ((i=1; i <= limit; i++)); do
        d=$d/..
    done
    d=$(echo $d | sed 's/^\///')
    cd "$d" || exit
}

# SSH into Wisconsin HEP cluster with stability options
wisconsin() {
    ssh -XYACv -o ServerAliveInterval=15 -o ServerAliveCountMax=3 mwadud@login"${1:-".hep.wisc.edu"}"
}

# SSH into Wisconsin HEP cluster as rusack with stability options
wisconsinR() {
    ssh -XYACv -o ServerAliveInterval=15 -o ServerAliveCountMax=3 rusack@login"${1:-".hep.wisc.edu"}"
}

# Mount Wisconsin HEP files
wisconsinfiles() {
    mkdir -p ~/wisconsinfiles/

    sshfs -o reconnect,debug,sshfs_debug,loglevel=DEBUG3,auto_cache \
          -o ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks \
          wadud@login"${1:-".hep.wisc.edu"}":/ ~/wisconsinfiles/
}

## Linux Quirks: ACPI GPE6E Interrupt Status Checker
check_gpe6e_interrupt() {
    # Read interrupt status
    local interrupt_info=$(grep . /sys/firmware/acpi/interrupts/gpe6E 2>/dev/null)

    # Exit if file not found
    if [[ -z "$interrupt_info" ]]; then
        echo -e "\e[91m[ERROR]\e[0m ACPI GPE6E interrupt info not found!"
        return 1
    fi

    # Extract values
    local count=$(echo "$interrupt_info" | awk '{print $1}')
    local enabled=$(echo "$interrupt_info" | grep -q "enabled" && echo "YES" || echo "NO")
    local unmasked=$(echo "$interrupt_info" | grep -q "unmasked" && echo "YES" || echo "NO")

    # Color setup
    local green="\e[92m"
    local red="\e[4;31m"
    local cyan="\e[96m"
    local reset="\e[0m"

    # Display table
    echo -e "\n${cyan}┌───────────────────────────┐"
    echo -e "│  ${green}GPE6E INTERRUPT STATUS${cyan}   │"
    echo -e "└───────────────────────────┘${reset}"
    printf " %-12s │ %s\n" "Count" "$count"
    printf " %-12s │ %s\n" "Enabled" "$enabled"
    printf " %-12s │ %s\n" "Unmasked" "$unmasked"
    echo -e "${cyan}────────────────────────────${reset}"
}

# LXPLUS and LPC username
KERBEROS_USER="mwadud"
# export KRB5CCNAME="DIR:$HOME/.krb5cc_shared"

typeset -g LAST_KRB5CCNAME=""

cc_root() {
  # Always compute from HOME, never from a possibly-empty intermediate var
  printf 'DIR:%s/.krb5cc_shared' "$HOME"
}

ensure_ccroot() {
  # Create the real directory that backs the collection (no-op if it exists)
  local dir="$HOME/.krb5cc_shared"
  if [[ ! -d "$dir" ]]; then
    umask 077
    mkdir -p "$dir" || { echo "[✘] Failed to create $dir"; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
  fi
}

# Returns the cache PATH (e.g. "DIR::/home/.../tktXYZ") for a given principal
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

ensure_keytab_perms() {
  local keytab="$1"
  [[ -f "$keytab" ]] || return 0

  local mode
  mode=$(stat -c %a -- "$keytab" 2>/dev/null) || return 0

  # last two octal digits must be 00 (no group/other perms)
  if [[ "${mode[-2,-1]}" != "00" ]]; then
    echo "[⚠] Insecure permissions on $keytab (mode $mode). Fixing to 600."
    command chmod 600 -- "$keytab" 2>/dev/null || {
      echo "[✘] Could not chmod 600 $keytab"
      return 1
    }
  fi
}

destroy_kerberos_ticket() {
  local principal="$1" verbose="$2" cache_path

  [[ "$verbose" == "--verbose" ]] && echo "=== [INFO] Destroying cache for: $principal ==="

  cache_path="$(ccache_for_principal "$principal")"
  if [[ -z "$cache_path" ]]; then
    echo "[ℹ] No ticket found for $principal."
    return 0
  fi

  # Sanity-check cache type
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

get_kerberos_ticket() {
  local principal="$1" keytab="$2"
  local realm="${principal##*@}"
  local current_cache="" default_principal="" exp="" ren=""
  local found=0

  local RESET="\033[0m" BOLD="\033[1m" GREEN="\033[1;32m" RED="\033[1;31m" \
        YELLOW="\033[1;33m" CYAN="\033[1;36m" BLUE="\033[1;34m"

  ensure_ccroot || return 1
  local collection; collection="$(cc_root)"
  if [[ -z "$collection" || "$collection" == "DIR:" ]]; then
    echo -e "${RED}[✘]${RESET} Internal error: empty collection root."
    return 1
  fi

  # -------- Find the cache that corresponds to THIS principal --------
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

    # Only accept within the correct principal section
    if [[ "$default_principal" == "$principal" && "$line" == *"krbtgt/$realm"* ]]; then
      exp=$(command awk '{print $3 " " $4}' <<< "$line")
      found=1
      break
    fi
  done < <(command klist -A 2>/dev/null)

  if (( found == 1 )) && [[ -n "$current_cache" ]]; then
    # Best-effort renewable-until extraction; format varies across implementations.
    ren=$(KRB5CCNAME="$current_cache" command klist -f 2>/dev/null | command awk '/renew until/ {print $3 " " $4; exit}')
    [[ -z "$ren" ]] && ren="(unknown)"

    local epoch_exp epoch_ren=0 epoch_now
    epoch_exp=$(command date -d "$exp" +%s 2>/dev/null || echo 0)
    if [[ "$ren" != "(unknown)" ]]; then
      epoch_ren=$(command date -d "$ren" +%s 2>/dev/null || echo 0)
    fi
    epoch_now=$(command date +%s)

    if (( epoch_exp > epoch_now )); then
      echo -e "${GREEN}[✔]${RESET} ${BOLD}$principal${RESET} ticket valid — ${CYAN}expires:${RESET} ${BLUE}$exp${RESET} ${CYAN}| renewable until:${RESET} ${BLUE}$ren${RESET}"
      LAST_KRB5CCNAME="$current_cache"
      return 0
    fi

    # Expired: attempt renewal if renewable-until parse worked and indicates still renewable
    if (( epoch_ren > epoch_now )); then
      echo -e "${YELLOW}[⟳]${RESET} ${BOLD}$principal${RESET} ticket expired, attempting ${CYAN}renewal${RESET}..."
      if KRB5CCNAME="$current_cache" command kinit -R 2>/dev/null; then
        echo -e "${GREEN}[✔]${RESET} Ticket successfully ${CYAN}renewed${RESET}."
        LAST_KRB5CCNAME="$current_cache"
        return 0
      else
        echo -e "${RED}[!!]${RESET} Ticket renewal ${BOLD}failed${RESET}."
      fi
    else
      echo -e "${RED}[✘]${RESET} Ticket expired and ${BOLD}not renewable${RESET}."
    fi
  else
    echo -e "${RED}[✘]${RESET} No valid ticket found for ${BOLD}$principal${RESET}."
  fi

  echo -e "${CYAN}[→]${RESET} Attempting to ${YELLOW}obtain new ticket${RESET} for ${BOLD}$principal${RESET}..."
  destroy_kerberos_ticket "$principal"

  # -------- Obtain NEW creds into the collection root --------
  if [[ -f "$keytab" ]]; then
    ensure_keytab_perms "$keytab" || return 1

    if KRB5CCNAME="$collection" command kinit -l 168h -r 30d -k -t "$keytab" "$principal"; then
      echo -e "${GREEN}[✔]${RESET} Ticket obtained using ${CYAN}keytab${RESET}."
      LAST_KRB5CCNAME="$(ccache_for_principal "$principal")"
      [[ -n "$LAST_KRB5CCNAME" ]] || LAST_KRB5CCNAME="$collection"
      return 0
    else
      echo -e "${RED}[!!]${RESET} Keytab authentication ${BOLD}failed${RESET}. Falling back to ${YELLOW}password prompt${RESET}."
    fi
  fi

  if KRB5CCNAME="$collection" command kinit -l 168h -r 30d "$principal"; then
    echo -e "${GREEN}[✔]${RESET} Ticket obtained via ${CYAN}password prompt${RESET}."
    LAST_KRB5CCNAME="$(ccache_for_principal "$principal")"
    [[ -n "$LAST_KRB5CCNAME" ]] || LAST_KRB5CCNAME="$collection"
    return 0
  else
    echo -e "${RED}[!!]${RESET} Password login ${BOLD}failed${RESET} for ${BOLD}$principal${RESET}."
    return 1
  fi
}


# --- SSH option builders (zsh) ----------------------------------------------

# Build ssh options for mux vs nomux.
# Usage: ssh_opts_for_mux 0|1  (1 = mux, 0 = nomux)
ssh_opts_for_mux() {
  local use_mux="${1:-1}"
  local -a opts

  if [[ "$use_mux" -eq 1 ]]; then
    # Let ~/.ssh/config control mux (ControlMaster auto, ControlPath ~/.ssh/cm-%C, etc.)
    # Nothing required here.
    opts=()
  else
    # Hard-disable client-side mux attachment.
    # Critical: ControlPath=none prevents attaching to any existing master socket.
    opts=(
      -o ControlMaster=no
      -o ControlPath=none
      -o ControlPersist=no
    )
  fi

  print -r -- "${opts[@]}"
}

# Normalize lxplus node argument.
# Accepts:
#   ""            -> lxplus.cern.ch
#   "953"         -> lxplus953.cern.ch
#   "lxplus953"   -> lxplus953.cern.ch
#   "lxplus953.cern.ch" -> lxplus953.cern.ch
lxplus_host_from_arg() {
  local arg="$1"
  if [[ -z "$arg" ]]; then
    print -r -- "lxplus.cern.ch"
    return 0
  fi

  # Strip domain if present
  arg="${arg%.cern.ch}"

  # If arg is digits, treat as suffix
  if [[ "$arg" == <-> ]]; then
    print -r -- "lxplus${arg}.cern.ch"
    return 0
  fi

  # If arg starts with lxplus and then digits
  if [[ "$arg" == lxplus<-> ]]; then
    print -r -- "${arg}.cern.ch"
    return 0
  fi

  # Otherwise: assume caller passed something sensible (e.g. a full host alias)
  # You can choose to error instead, but this is “robust default”.
  print -r -- "${arg}.cern.ch"
}

remote_ssh_login() {
  local get_ticket_func="$1"
  local host="$2"
  local fallback_ok="${3:-0}"
  shift 3

  local -a extra_ssh_opts
  extra_ssh_opts=("$@")

  if ! $get_ticket_func; then
    if [[ "$fallback_ok" -eq 1 ]]; then
      echo "[⚠] Kerberos ticket not obtained — continuing with password-based SSH."
    else
      echo "[✘] SSH aborted — Kerberos authentication failed."
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
      echo "[⚠] Kerberos ticket not obtained — continuing with password-based SSH."
    else
      echo "[✘] Mount aborted — Kerberos authentication failed."
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
  ssh_cmd=(ssh
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    "${extra_ssh_opts[@]}"
  )

  # Shell-escape each token for sshfs's ssh_command string
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
    echo "[!!] SSHFS mount failed — check network or credentials."
    return 1
  fi
}

CERN_REALM="CERN.CH"
CERN_PRINCIPAL="$KERBEROS_USER@$CERN_REALM"
CERN_KEYTAB="$HOME/.keytabs/${KERBEROS_USER}_cern.keytab"
# Wrapper to get CERN Kerberos ticket.
# Generate keytab on lxplus.cern.ch using:
#   cern-get-keytab --keytab ~/mwadud_cern.keytab --user --login mwadud
# Then scp it locally: scp mwadud@lxplus.cern.ch:~/mwadud_cern.keytab ~/
# Docs: https://linux.web.cern.ch/docs/kerberos-access/
get_CERN_kerberos_ticket() {
    get_kerberos_ticket "$CERN_PRINCIPAL" "$CERN_KEYTAB"
}

destroy_cern_mwadud() {
    destroy_kerberos_ticket "$CERN_PRINCIPAL"
}


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

    remote_ssh_login get_CERN_kerberos_ticket "$host" 1 "${mux_opts[@]}"
}

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

    sshfs_mount get_CERN_kerberos_ticket "lxplus.cern.ch" "/mnt/lxfiles" 1 "$remote_dir" "${mux_opts[@]}"
}

FNAL_REALM="FNAL.GOV"
FNAL_PRINCIPAL="$KERBEROS_USER@$FNAL_REALM"
FNAL_KEYTAB="$HOME/.keytabs/${KERBEROS_USER}_fnal.keytab"
# Wrapper to get FNAL Kerberos ticket.
# Generate keytab locally using ktutil:
#   addent -password -p mwadud@FNAL.GOV -k 1 -e aes256-cts-hmac-sha1-96
#   wkt ~/mwadud_fnal.keytab
# Then test: kinit -k -t ~/mwadud_fnal.keytab mwadud@FNAL.GOV
get_LPC_kerberos_ticket() {
    get_kerberos_ticket "$FNAL_PRINCIPAL" "$FNAL_KEYTAB"
}

destroy_fnal_mwadud() {
    destroy_kerberos_ticket "$FNAL_PRINCIPAL"
}

fermi() {
    local node
    case $1 in
        el8)
            node="cmslpc${2:-201}.fnal.gov"
            [[ -z $2 || ( $2 -ge 201 && $2 -le 250 ) ]] || {
                echo "Invalid el8 node: must be 201–250"; return 1; }
            ;;
        el9|"")
            node="cmslpc${2:-301}.fnal.gov"
            [[ -z $2 || ( $2 -ge 301 && $2 -le 350 ) ]] || {
                echo "Invalid el9 node: must be 301–350"; return 1; }
            ;;
        heavy-el8)
            node="cmslpc-el8-heavy0${2:-1}.fnal.gov"
            [[ -z $2 || $2 -eq 1 || $2 -eq 2 ]] || {
                echo "Invalid heavy-el8 node: must be 1 or 2"; return 1; }
            ;;
        heavy-el9)
            node="cmslpc-el9-heavy01.fnal.gov"
            ;;
        *)
            echo "Usage: fermi [el9|el8|heavy-el9|heavy-el8] [node#]"; return 1
            ;;
    esac

    remote_ssh_login get_LPC_kerberos_ticket "$node" 0
}

fermifiles() {
    local remote_dir="${1:-/}"
    sshfs_mount get_LPC_kerberos_ticket "cmslpc-el9.fnal.gov" "/mnt/fermi" 0 "$remote_dir"
}

hyperupdate() {
  printf "\e[90m[log]\tRun at %s by %s\e[0m\n" "$(date)" "$(whoami)"
  printf "\e[90m[kernel]\tCurrent: %s\e[0m\n" "$(uname -r)"

  if ! ping -q -c1 google.com &>/dev/null; then
    echo -e "\e[1;91m[error]\tNo internet connection — aborting update\e[0m"
    return 1
  fi

  # authenticate sudo once
  sudo -v

  # pkgfile db (for `pkgfile <file>` lookups; update path belongs here)
  sudo pkgfile --update \
    && echo -e "\e[32m[pkgfile]\t✔ db updated\e[0m" \
    || echo -e "\e[31m[pkgfile]\t✘ update failed\e[0m"

  # unified update: yay handles repo + AUR; no separate pacman run
  yay_log=$(mktemp)
  yay -Syyu --noconfirm --needed 2>&1 | tee "$yay_log"
  yay_status=${PIPESTATUS[0]}
  if [[ $yay_status -eq 0 ]]; then
    echo -e "\e[32m[yay]\t✔ AUR + repo updated\e[0m"
  else
    echo -e "\e[31m[yay]\t✘ update failed\e[0m"
  fi

  # detect kernel module dependency conflicts from the yay output
  echo -e "\e[90m[scan]\tScanning for module version conflicts...\e[0m"
  grep -E "breaks dependency '.+=.+?' required by linux[[:alnum:]_-]+" "$yay_log" | while read -r line; do
    dep=$(echo "$line" | sed -nE "s/.*breaks dependency '([^']+)'.*/\1/p")
    req=$(echo "$line" | sed -nE "s/.*required by ([^[:space:]]+).*/\1/p")
    base=${dep%=*}; ver=${dep#*=}
    echo -e "\e[1;91m[module conflict]\e[0m $req needs \e[96m$dep\e[0m"
    echo -e "   advise: align $base to $ver or skip"
  done

  # remove temp log
  rm -f "$yay_log"

  # flatpak app updates (cleanup of unused stays in whisp)
  sudo flatpak update -y \
    && echo -e "\e[32m[flatpak]\t✔ apps updated\e[0m" \
    || echo -e "\e[31m[flatpak]\t✘ update failed\e[0m"

  # systemd health
  fails=$(systemctl --failed --no-legend)
  if [[ -n "$fails" ]]; then
    echo -e "\e[1;91m[systemd]\tFailed services:\e[0m"
    echo "$fails" | awk '{print "   · " $1}'
  else
    echo -e "\e[90m[systemd]\tAll services healthy\e[0m"
  fi

  echo -e "\e[1;36m[hyperupdate]\tDone.\e[0m"
}

whisp () {
    # ===== colors =====
    NEON_GRAY="\e[1;90m"; NEON_GREEN="\e[1;92m"; NEON_RED="\e[1;91m"
    NEON_BLUE="\e[1;94m"; NEON_PURPLE="\e[1;95m"; RESET="\e[0m"

    # ===== behavior =====
    trap 'echo -e "${NEON_RED}[whisp]\tAborted by user${RESET}"; return 130' INT TERM
    # zsh: avoid “no matches” errors and rm confirmation nags
    setopt null_glob rm_star_silent 2>/dev/null

    echo -e "${NEON_PURPLE}[whisp]\tStarting deep system cleanup...${RESET}"

    # upfront sudo (one-time)
    sudo -v || { echo -e "${NEON_RED}[whisp]\tSudo failed${RESET}"; return 1; }

    # guard: don’t race a running package manager
    if pgrep -x pacman >/dev/null || pgrep -x yay >/dev/null || [ -e /var/lib/pacman/db.lck ]; then
      echo -e "${NEON_RED}[guard]\tPackage manager busy; try again later${RESET}"
      return 2
    fi

    # ===== pacman pre-clean: nuke stale partials and broken download dirs (files, dirs, symlinks) =====
    {
      # unstick immutable attrs if any (rare, but makes deletions bulletproof)
      if command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1; then
        sudo find /var/cache/pacman/pkg -maxdepth 1 \
          \( -name '*.part' -o -name 'download-*' \) -exec sudo chattr -i -- {} + 2>/dev/null
      fi
      # delete the junk regardless of type
      sudo find /var/cache/pacman/pkg -maxdepth 1 \
        \( -name '*.part' -o -name 'download-*' \) -exec sudo rm -rf -- {} + 2>/dev/null
    } && echo -e "${NEON_GRAY}[pacman]\t(pre-cleaned stale partials and download-* dirs)${RESET}"

    # ===== yay: AUR orphaned build deps only (fully non-interactive) =====
    yay -Yc --noconfirm --sudoloop --removemake >/dev/null \
      && echo -e "${NEON_GREEN}[yay]\t✔ orphaned AUR deps cleaned${RESET}" \
      || echo -e "${NEON_RED}[yay]\t✘ AUR orphan clean failed${RESET}"

    # ===== pacman orphans (repo pkgs) =====
    if orphans=$(pacman -Qtdq 2>/dev/null) && [[ -n "$orphans" ]]; then
      sudo pacman -Rns --noconfirm -- $orphans \
        && echo -e "${NEON_GREEN}[pacman]\t✔ orphaned system packages removed${RESET}" \
        || echo -e "${NEON_RED}[pacman]\t✘ failed to remove orphans${RESET}"
    else
      echo -e "${NEON_GRAY}[pacman]\t(no orphaned system packages)${RESET}"
    fi

    # ===== pacman cache: quiet and safe =====
    sudo paccache -ruk0 \
      && echo -e "${NEON_GREEN}[paccache]\t✔ uninstalled package cache cleared${RESET}" \
      || echo -e "${NEON_RED}[paccache]\t✘ failed clearing uninstalled cache${RESET}"
    sudo paccache -rk2 \
      && echo -e "${NEON_GREEN}[paccache]\t✔ kept last 2 versions per package${RESET}" \
      || echo -e "${NEON_RED}[paccache]\t✘ failed pruning cache${RESET}"

    # ===== flatpak: remove unused =====
    sudo flatpak uninstall --unused -y \
      && echo -e "${NEON_GREEN}[flatpak]\t✔ unused apps removed${RESET}" \
      || echo -e "${NEON_RED}[flatpak]\t✘ none removed or failed${RESET}"

    # ===== temp dirs: no globs; use find so zsh never prompts =====
    deleted_any=false
    if [ -d "$HOME/.cache" ]; then
      cnt=$(find "$HOME/.cache" -mindepth 1 -maxdepth 1 | wc -l)
      if [ "$cnt" -gt 0 ]; then
        find "$HOME/.cache" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && {
          echo -e "${NEON_GREEN}[temp]\t✔ cleared $HOME/.cache ($cnt items)${RESET}"
          deleted_any=true
        } || echo -e "${NEON_RED}[temp]\t✘ failed clearing $HOME/.cache${RESET}"
      else
        echo -e "${NEON_GRAY}[temp]\t($HOME/.cache already clean)${RESET}"
      fi
    fi
    for dir in /var/tmp /tmp; do
      if [ -d "$dir" ]; then
        cnt=$(sudo find "$dir" -mindepth 1 -maxdepth 1 | wc -l)
        if [ "$cnt" -gt 0 ]; then
          sudo find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && {
            echo -e "${NEON_GREEN}[temp]\t✔ cleared $dir ($cnt items)${RESET}"
            deleted_any=true
          } || echo -e "${NEON_RED}[temp]\t✘ failed clearing $dir${RESET}"
        else
          echo -e "${NEON_GRAY}[temp]\t($dir already clean)${RESET}"
        fi
      else
        echo -e "${NEON_GRAY}[temp]\t($dir does not exist)${RESET}"
      fi
    done
    $deleted_any || echo -e "${NEON_BLUE}[temp]\t✔ nothing to delete${RESET}"

    echo -e "${NEON_PURPLE}[whisp]\tCleanup complete.${RESET}"
}

# # Force unmount all mounted SSHFS filesystems using fusermount
unmountf() {
    USER_HOME=$(eval echo ~"${SUDO_USER:-$USER}")
    sudo bash <<EOF
    umount -l $USER_HOME/cmsfiles/
    umount -l /mnt/lxfiles/
    umount -l /mnt/fermi/
    umount -l $USER_HOME/wisconsinfiles/
    umount -l $USER_HOME/wisconsinfilesRoger/
EOF
}



# ──────────────────────────────────────────────────────────────────────────────
# CVMFS helper utilities (robust + hang-resistant)
# Provides clean mount, test, unmount, and restart helpers for /cvmfs repos.
# Designed to avoid hangs by using timeouts, lazy detaches, and autofs masking.
# ──────────────────────────────────────────────────────────────────────────────
# _cvmfs_timeout:
# Run a command with a timeout if `timeout(1)` exists; otherwise run directly.
# Usage: _cvmfs_timeout <secs> <cmd> [args...]
_cvmfs_timeout() {
  emulate -L zsh
  setopt localoptions
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    command timeout --preserve-status --signal=TERM --kill-after=2s "${secs}s" "$@"
  else
    "$@"
  fi
}

# _cvmfs_repos:
# Resolve repo list.
# - With args: returns them unchanged.
# - Without args: returns effective CVMFS_REPOSITORIES (from cvmfs_config if
#   available, else from /etc/cvmfs/default.local).
_cvmfs_repos() {
  emulate -L zsh
  setopt localoptions
  if (( $# > 0 )); then print -l -- "$@"; return; fi
  # Try effective config first (fast-path if config repo is available)
  local line
  line=$(command cvmfs_config showconfig -s 2>/dev/null | command grep -E '^[[:space:]]*CVMFS_REPOSITORIES=' | tail -n1) || {
    # Fallback: parse local override
    line=$(command grep -E '^[[:space:]]*CVMFS_REPOSITORIES=' /etc/cvmfs/default.local 2>/dev/null | tail -n1) || return
  }
  line=${line#*=}             # strip key=
  line=${line%%#*}            # strip trailing comments
  line=${line##[[:space:]]}   # ltrim
  line=${line%%[[:space:]]}   # rtrim
  line=${line#[\'\"]}; line=${line%[\'\"]}   # strip surrounding quotes
  line=${line//,/ }           # commas → spaces
  print -l -- $=line
}

# _cvmfs_mountpoints:
# List currently active /cvmfs FUSE mountpoints.
# Uses findmnt if present, else parses /proc/self/mountinfo.
# Matches both fuse.cvmfs and fuse.cvmfs2.
_cvmfs_mountpoints() {
  emulate -L zsh
  setopt localoptions
  if command -v findmnt >/dev/null 2>&1; then
    # both fuse.cvmfs and fuse.cvmfs2; only targets under /cvmfs
    command findmnt -rn -t fuse.cvmfs,fuse.cvmfs2 -o TARGET |
      awk '/^\/cvmfs(\/|$)/ {print $1}'
  else
    # fallback: parse mountinfo (reliable; no grep races)
    awk '($0 ~ / - fuse\.cvmfs(2)? /) && ($5 ~ "^/cvmfs(/|$)") {print $5}' /proc/self/mountinfo
  fi
}

# _cvmfs_stop_autofs:
# Deterministically stop autofs without blocking on kernel drains.
# - Issues systemctl stop (non-blocking) and kills automount(8) if it lingers.
# - Lazy-umounts /cvmfs to prevent retriggers.
# - Resets failed state so restart works cleanly.
_cvmfs_stop_autofs() {
  emulate -L zsh
  setopt localoptions
  _cvmfs_timeout 2 systemctl stop autofs 2>/dev/null || true
  _cvmfs_timeout 1 systemctl --no-block stop autofs 2>/dev/null || true
  if pgrep -x automount >/dev/null 2>&1; then
    command sudo pkill -TERM -x automount 2>/dev/null || true
    sleep 0.3
    pgrep -x automount >/dev/null 2>&1 && command sudo pkill -KILL -x automount 2>/dev/null || true
  fi
  # Drop the autofs superblock so nothing re-triggers while unmounting FUSE repos
  command sudo umount -l /cvmfs 2>/dev/null || true
  command systemctl reset-failed autofs 2>/dev/null || true
}

# _cvmfs_prepare:
# Minimal prep before mounting.
# - Runs cvmfs_config setup once.
# - Ensures autofs is enabled and running (with short timeout).
# Idempotent: safe to call multiple times.
_cvmfs_prepare() {
  emulate -L zsh
  setopt localoptions
  # Quiet setup; show only on failure
  command sudo cvmfs_config setup >/dev/null 2>&1 || command sudo cvmfs_config setup
  if ! command systemctl is-active --quiet autofs; then
    _cvmfs_timeout 3 systemctl enable --now autofs >/dev/null 2>&1 || systemctl enable --now autofs
  fi
}

# Mount (probe + touch) one or more repos; if none provided, uses effective set.
cvmfs_mount() {
  emulate -L zsh
  setopt localoptions errreturn pipefail
  local -a repos; repos=($(_cvmfs_repos "$@"))
  if (( ${#repos} == 0 )); then
    print -r -- "cvmfs_mount: no repositories specified (and none discovered)"; return 2
  fi

  _cvmfs_prepare
  _cvmfs_timeout 5 sudo cvmfs_config reload >/dev/null 2>&1 || true

  # Probe config repo first (speeds up domain params)
  if [[ " ${repos[*]} " == *" cvmfs-config.cern.ch "* ]]; then
    print -r -- "· probe config repo…"
    _cvmfs_timeout 8 cvmfs_config probe cvmfs-config.cern.ch || true
  fi

  print -r -- "· probing: ${repos[*]}…"
  _cvmfs_timeout 15 cvmfs_config probe "${repos[@]}" || true

  # Trigger autofs by listing roots (non-fatal)
  local r
  for r in "${repos[@]}"; do
    command ls -d "/cvmfs/${r}" >/dev/null 2>&1 || true
  done

  command cvmfs_config stat
}

# cvmfs_mount:
# Mount/probe one or more repos (defaults to effective repo set).
# - Ensures autofs is active.
# - Reloads CVMFS config, probes repos, touches mountpoints to trigger autofs.
# - Prints cvmfs_config stat at the end.
cvmfs_test() {
  emulate -L zsh
  setopt localoptions errreturn pipefail
  local -a repos; repos=($(_cvmfs_repos "$@"))
  if (( ${#repos} == 0 )); then
    print -r -- "cvmfs_test: no repositories to check"; return 2
  fi

  print -r -- "· chksetup…"
  if ! _cvmfs_timeout 6 sudo cvmfs_config chksetup; then
    print -r -- "⚠ chksetup warnings (non-fatal)"
  fi

  local r
  for r in "${repos[@]}"; do
    print -r -- "──────── repo: ${r}"
    print -r -- "· showconfig (-s)…"
    _cvmfs_timeout 5 cvmfs_config showconfig -s "$r" | sed -n '1,80p' || true
    print -r -- "· probe + touch…"
    _cvmfs_timeout 10 cvmfs_config probe "$r" || true
    command ls -ld "/cvmfs/${r}" 2>/dev/null || true
    ( command ls -1 "/cvmfs/${r}" | head -n 5 ) 2>/dev/null || true

    # Is it mounted?
    if _cvmfs_mountpoints | grep -qx "/cvmfs/${r}"; then
      print -r -- "· live host/proxy/cache…"
      _cvmfs_timeout 3 sudo cvmfs_talk -i "$r" host info  2>/dev/null || true
      _cvmfs_timeout 3 sudo cvmfs_talk -i "$r" proxy info 2>/dev/null || true
      _cvmfs_timeout 3 sudo cvmfs_talk -i "$r" cache list 2>/dev/null | head -n 5 || true
      if command -v attr >/dev/null 2>&1; then
        command attr -q -g logbuffer "/cvmfs/${r}" 2>/dev/null | tail -n 5 || true
      fi
    else
      print -r -- "· not mounted yet (autofs mounts on first access)"
    fi
  done

  print -r -- "──────── overall status"
  command cvmfs_config stat
}

# Hard stop of autofs without blocking; ensure it cannot re-trigger mounts.
_cvmfs_stop_autofs_hard() {
  emulate -L zsh
  setopt localoptions
  # prevent systemd from auto-starting it during teardown
  command sudo systemctl mask autofs >/dev/null 2>&1 || true
  # non-blocking stop; don’t wait on kernel drain
  command sudo systemctl stop autofs 2>/dev/null || true
  command sudo systemctl --no-block stop autofs 2>/dev/null || true
  # kill lingering automount(8) if any
  if pgrep -x automount >/dev/null 2>&1; then
    command sudo pkill -TERM -x automount 2>/dev/null || true
    sleep 0.3
    pgrep -x automount >/dev/null 2>&1 && command sudo pkill -KILL -x automount 2>/dev/null || true
  fi
  # drop autofs superblock so new lookups cannot happen
  command sudo umount -l /cvmfs 2>/dev/null || true
  # clean failure state for next start
  command sudo systemctl reset-failed autofs 2>/dev/null || true
}

# cvmfs_unmount:
# Forcefully detach all CVMFS repos; no network/RPCs. Leaves autofs masked.
# Flags:
#   --wipe-cache|--wipecache : rm -rf contents of /var/lib/cvmfs (local only).
#   --kill-users             : kill processes holding /cvmfs/* (last resort).
# Steps:
# - Mask + stop autofs to freeze triggers.
# - Lazy-umount FUSE repos; fusermount fallback.
# - Kill cvmfs2, mount.cvmfs, helper `mount -t cvmfs` processes.
# - Optionally kill user processes with fuser/lsof.
# - Scrub /var/run/cvmfs runtime state.
# - Verify mounts; optionally wipe cache.
# Autofs stays masked until restarted.
cvmfs_unmount() {
  emulate -L zsh
  setopt localoptions errreturn pipefail

  local wipe_cache=0 kill_users=0 a
  for a in "$@"; do
    case "$a" in
      --wipe-cache|--wipecache) wipe_cache=1 ;;
      --kill-users)             kill_users=1 ;;
    esac
  done

  print -r -- "→ freezing automount activity…"
  _cvmfs_stop_autofs_hard

  # snapshot mountpoints once (avoids re-discovery races)
  local -a mps; mps=($(_cvmfs_mountpoints))
  if (( ${#mps} )); then
    print -r -- "→ detaching ${#mps} CVMFS FUSE mount(s)…"
    local mp
    for mp in "${mps[@]}"; do
      # lazy detach never blocks
      command sudo umount -l -- "$mp" 2>/dev/null || true
      if command -v fusermount3 >/dev/null 2>&1; then
        command sudo fusermount3 -u -z -- "$mp" 2>/dev/null || true
      else
        command sudo fusermount  -u -z -- "$mp" 2>/dev/null || true
      fi
    done
  else
    print -r -- "→ no active /cvmfs FUSE mounts."
  fi

  # terminate cvmfs daemons and helper mounters
  print -r -- "→ killing cvmfs daemons & helpers…"
  command sudo pkill -TERM -x cvmfs2      2>/dev/null || true
  command sudo pkill -TERM -x mount.cvmfs 2>/dev/null || true
  # kill *only* /usr/bin/mount instances that invoked -t cvmfs (no collateral)
  local -a mpids
  mpids=($(ps -eo pid=,args= | awk '/[\/ ]mount[[:space:]].*-t[[:space:]]+cvmfs([[:space:]]|$)/{print $1}'))
  if (( ${#mpids} )); then command sudo kill -TERM -- "${mpids[@]}" 2>/dev/null || true; fi
  sleep 0.3
  command sudo pkill -KILL -x cvmfs2      2>/dev/null || true
  command sudo pkill -KILL -x mount.cvmfs 2>/dev/null || true
  if (( ${#mpids} )); then command sudo kill -KILL -- "${mpids[@]}" 2>/dev/null || true; fi

  # optionally kill user processes still holding /cvmfs (harsh but decisive)
  if (( kill_users )); then
    print -r -- "→ killing processes using /cvmfs/* …"
    if command -v fuser >/dev/null 2>&1; then
      # -k kill, -m treat as mountpoint, -M search mounted fs, -s silent
      command sudo fuser -km /cvmfs 2>/dev/null || true
    elif command -v lsof >/dev/null 2>&1; then
      local -a pids; pids=($(command sudo lsof -t +D /cvmfs 2>/dev/null | sort -u))
      (( ${#pids} )) && command sudo kill -TERM -- "${pids[@]}" 2>/dev/null || true
      sleep 0.2
      (( ${#pids} )) && command sudo kill -KILL -- "${pids[@]}" 2>/dev/null || true
    fi
  fi

  # scrub runtime state
  command sudo rm -rf /var/run/cvmfs/* 2>/dev/null || true

  # final verification
  local -a left; left=($(_cvmfs_mountpoints))
  if (( ${#left} )); then
    print -r -- "‼ still mounted: ${left[*]}"
    print -r -- "   hint: run again with --kill-users to terminate holders."
  else
    print -r -- "✓ all /cvmfs mounts detached."
  fi

  if (( wipe_cache )); then
    print -r -- "→ wiping local cache: /var/lib/cvmfs"
    command sudo find /var/lib/cvmfs -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    command sudo install -d -o cvmfs -g cvmfs /var/lib/cvmfs
  fi

  print -r -- "→ autofs remains *masked*; use cvmfs_restart to bring it back."
}

# cvmfs_restart:
# Clean restart after unmount.
# - Ensures cache and runtime dirs exist with cvmfs ownership.
# - Unmasks autofs and enables/starts it.
# - Prints final autofs state (active or not).
# Does not probe or mount repos until accessed.
cvmfs_restart() {
  emulate -L zsh
  setopt localoptions errreturn pipefail
  command sudo install -d -o cvmfs -g cvmfs /var/lib/cvmfs
  command sudo install -d -o cvmfs -g cvmfs /var/run/cvmfs
  # If you write debug logs to /var/log/cvmfs/cvmfs.log:
  # command sudo install -d -m 0775 -o cvmfs -g cvmfs /var/log/cvmfs

  # allow autofs to start again
  command sudo systemctl unmask autofs >/dev/null 2>&1 || true
  command sudo systemctl enable --now autofs 2>/dev/null || command sudo systemctl start autofs

  if systemctl is-active --quiet autofs; then
    print -r -- "✓ autofs active; repos mount on first access."
  else
    print -r -- "‼ autofs not active."
  fi
}

# hsparse() {
  [ -n "${BASH_VERSION:-}${ZSH_VERSION:-}" ] || { printf 'hsparse: requires bash or zsh
' >&2; return 2; }
  if [ -n "${ZSH_VERSION:-}" ]; then
    emulate -L zsh
    setopt localoptions no_nomatch
  fi

  local repo="" branch="" commit="" dest="" paths_csv=""
  local url="" repo_id="" reponame="" gitv="" rc=0 created_dest=0
  local use_ssh=0 add_mode=0 quiet=0 verify=0 lfs=0
  local export_fmt="" out_name="" script_file="" paths_file="" paths_from=""
  local provider="auto" host="" origin_url="" origin_id="" default_host=""
  local pf="" pg=""
  local -a qflagv=() PATHS=() clone_flags=()

  _hs_err() { printf 'hsparse: %s\n' "$*" >&2; }

  _hs_usage() {
    cat <<'EOS'
hsparse: sparse clone/extract for GitHub/GitLab (bash/zsh)
Usage: hsparse -r OWNER/REPO|URL -p PATH[,PATH2...] [opts]
  -r, --repo REPO             Repo as OWNER/REPO (or GROUP/SUBGROUP/REPO) or URL
  -p, --paths CSV             Comma-separated paths (repeatable)
      --paths-file FILE       Read paths from file (one per line, # comments ok)
      --paths-from FILE|-     Read paths from file or stdin
  -b, --branch BR             Branch to clone/switch/fetch
  -c, --commit SHA            Commit to checkout (detached)
  -d, --dest DIR              Destination directory (default: repo name)
  -S, --ssh                   Use SSH when --repo is path-only or HTTP(S)
  -A, --add, --update         Add paths to an existing sparse checkout at --dest
  -q, --quiet                 Reduce status output
      --verify                Verify requested paths exist at target ref
      --lfs                   Pull matching Git LFS objects for requested paths
      --export tar|zip|dir    Export checkout contents without .git
  -o, --out NAME              Export output name/path (default: dest)
      --script FILE           Write a standalone reproducible bash script
      --provider auto|github|gitlab
                              Provider for path-only --repo values (default: auto)
      --host HOST             Override host (e.g., github.com, gitlab.com, git.example.com)
  -h, --help                  Show this help

Notes:
  * Git >= 2.25 is required.
  * Path-only --repo uses --provider/--host (or gitlab.com when provider=gitlab, else github.com).
EOS
  }

  _hs_need_arg() { [ $# -ge 2 ] && [ -n "${2-}" ] || { _hs_err "option $1 requires an argument"; return 2; }; }
  _hs_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

  _hs_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
  }

  _hs_append_paths_csv() { [ -n "$1" ] && paths_csv=${paths_csv:+$paths_csv,}$1; }

  _hs_read_paths_source() {
    local src=$1 label=$2
    if [ "$src" = "-" ]; then
      sed -e 's/#.*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' -e '/^$/d' | tr -d '' | paste -sd, -
    else
      [ -f "$src" ] || { _hs_err "$label not found: $src"; return 2; }
      sed -e 's/#.*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' -e '/^$/d' "$src" | tr -d '' | paste -sd, -
    fi
  }

  _hs_git_ver_ge() {
    local v1 v2 a1 b1 c1 d1 a2 b2 c2 d2
    v1=${1%%[^0-9.]*}; v2=${2%%[^0-9.]*}
    IFS=. read -r a1 b1 c1 d1 <<<"$v1"; IFS=. read -r a2 b2 c2 d2 <<<"$v2"
    a1=${a1:-0}; b1=${b1:-0}; c1=${c1:-0}; d1=${d1:-0}
    a2=${a2:-0}; b2=${b2:-0}; c2=${c2:-0}; d2=${d2:-0}
    [ "$a1" -gt "$a2" ] && return 0; [ "$a1" -lt "$a2" ] && return 1
    [ "$b1" -gt "$b2" ] && return 0; [ "$b1" -lt "$b2" ] && return 1
    [ "$c1" -gt "$c2" ] && return 0; [ "$c1" -lt "$c2" ] && return 1
    [ "$d1" -ge "$d2" ]
  }

  _hs_repo_id_from_url() {
    local s=$1
    case "$s" in
      https://*/*|http://*/*) s=${s#*://}; s=${s#*/} ;;
      git@*:* ) s=${s#*:} ;;
      ssh://git@*/*) s=${s#ssh://git@}; s=${s#*/} ;;
      *) return 1 ;;
    esac
    s=${s%.git}; s=${s%/}
    [ -n "$s" ] || return 1
    printf '%s\n' "$s"
  }

  _hs_host_from_url() {
    local s=$1
    case "$s" in
      https://*/*|http://*/*) s=${s#*://}; printf '%s\n' "${s%%/*}" ;;
      git@*:* ) s=${s#git@}; printf '%s\n' "${s%%:*}" ;;
      ssh://git@*/*) s=${s#ssh://git@}; printf '%s\n' "${s%%/*}" ;;
      *) return 1 ;;
    esac
  }

  _hs_provider_from_host() {
    case "$(_hs_lc "$1")" in
      github.com|*.github.com) printf 'github\n' ;;
      gitlab.com|*.gitlab.com) printf 'gitlab\n' ;;
      *) printf 'generic\n' ;;
    esac
  }

  _hs_resolve_repo() {
    local input=$1 host_lc=""
    case "$provider" in auto|github|gitlab) ;; *) _hs_err "--provider must be auto|github|gitlab"; return 2 ;; esac

    if [ -n "$host" ]; then
      default_host=$host
    elif [ "$provider" = "gitlab" ]; then
      default_host=gitlab.com
    else
      default_host=github.com
    fi

    case "$input" in
      https://*/*|http://*/*|git@*:*|ssh://git@*/*)
        repo_id=$(_hs_repo_id_from_url "$input") || { _hs_err "invalid repository URL: $input"; return 2; }
        host=$(_hs_host_from_url "$input") || { _hs_err "failed to parse host from URL: $input"; return 2; }
        url=$input
        ;;
      */*)
        repo_id=${input%.git}; repo_id=${repo_id%/}
        host=$default_host
        if [ $use_ssh -eq 1 ]; then
          url="git@${host}:${repo_id}.git"
        else
          url="https://${host}/${repo_id}.git"
        fi
        ;;
      *) _hs_err "--repo must be OWNER/REPO, GROUP/SUBGROUP/REPO, or git URL"; return 2 ;;
    esac

    host_lc=$(_hs_lc "$host")
    if [ "$provider" != "auto" ]; then
      case "$provider" in
        github) case "$host_lc" in *gitlab*) _hs_err "provider=github conflicts with host $host"; return 2;; esac ;;
        gitlab) case "$host_lc" in *github*) _hs_err "provider=gitlab conflicts with host $host"; return 2;; esac ;;
      esac
    else
      provider=$(_hs_provider_from_host "$host")
    fi

    reponame=${repo_id##*/}
    [ -n "$reponame" ] || { _hs_err "failed to derive repository name from --repo"; return 2; }
  }

  _hs_validate_dest() {
    case "$dest" in ""|"/"|"."|"..") _hs_err "unsafe --dest: $dest"; return 2;; esac
    if [ -e "$dest" ] && [ ! -d "$dest/.git" ]; then
      _hs_err "destination exists and is not a git repo: $dest"; return 2
    fi
  }

  _hs_emit_paths() {
    local rest token norm
    rest=$paths_csv
    while :; do
      case "$rest" in *,*) token=${rest%%,*}; rest=${rest#*,} ;; *) token=$rest; rest="" ;; esac
      norm=$(_hs_trim "$token"); norm=${norm#./}
      case "$norm" in ""|"."|".."|../*|*/../*|*/..|/*) ;; *) printf '%s\n' "$norm" ;; esac
      [ -n "$rest" ] || break
    done
  }

  _hs_load_paths() {
    local p
    PATHS=()
    while IFS= read -r p; do [ -n "$p" ] && PATHS+=("$p"); done < <(_hs_emit_paths | awk '!seen[$0]++')
    [ ${#PATHS[@]} -gt 0 ] || { _hs_err "no valid safe paths after normalization"; return 2; }
  }

  _hs_assert_matching_origin() {
    origin_url=$(git remote get-url origin 2>/dev/null || true)
    [ -n "$origin_url" ] || { _hs_err "existing destination repository has no origin remote"; return 2; }
    origin_id=$(_hs_repo_id_from_url "$origin_url") || { _hs_err "existing origin is unsupported: $origin_url"; return 2; }
    [ "$origin_id" = "$repo_id" ] || { _hs_err "destination repo mismatch: origin is $origin_id, expected $repo_id"; return 2; }
  }

  _hs_fetch_branch() { [ -n "$branch" ] || return 0; git fetch "${qflagv[@]}" --filter=blob:none --depth 1 origin "$branch"; }

  _hs_switch_branch() {
    [ -n "$branch" ] || return 0
    _hs_fetch_branch || return $?
    git switch "${qflagv[@]}" "$branch" 2>/dev/null || git switch "${qflagv[@]}" -c "$branch" --track "origin/$branch" 2>/dev/null || git checkout "${qflagv[@]}" "$branch" 2>/dev/null || git checkout "${qflagv[@]}" -b "$branch" --track "origin/$branch"
  }

  _hs_ensure_commit_available() {
    local deepen=50 max=1048576
    [ -n "$commit" ] || return 0
    git fetch "${qflagv[@]}" --filter=blob:none --depth 1 origin "$commit" 2>/dev/null || true
    git cat-file -e "$commit^{commit}" 2>/dev/null && return 0
    [ -n "$branch" ] || { _hs_err "remote refused SHA fetch; provide --branch containing --commit"; return 2; }
    _hs_fetch_branch || return $?
    while ! git cat-file -e "$commit^{commit}" 2>/dev/null; do
      [ $deepen -le $max ] || { _hs_err "commit ${commit:0:12} not found within deepen cap"; return 2; }
      git fetch "${qflagv[@]}" --filter=blob:none --deepen=$deepen origin "$branch" || return 1
      deepen=$((deepen * 2))
    done
  }

  _hs_checkout_target() {
    if [ -n "$commit" ]; then _hs_ensure_commit_available || return $?; git checkout "${qflagv[@]}" --detach "$commit" || return 1
    elif [ -n "$branch" ]; then _hs_switch_branch || return $?
    fi
  }

  _hs_verify_requested() {
    local ref p probe missing=""
    [ $verify -eq 1 ] || return 0
    ref=HEAD; [ -n "$commit" ] && ref=$commit
    for p in "${PATHS[@]}"; do probe=${p%/}; [ -n "$probe" ] || probe=$p; git cat-file -e "$ref:$probe" 2>/dev/null || missing=${missing}${missing:+, }$p; done
    [ -z "$missing" ] || { _hs_err "missing at $ref: $missing"; return 2; }
    if [ -n "$commit" ] && [ -n "$branch" ]; then
      git rev-parse --verify "origin/$branch" >/dev/null 2>&1 || _hs_fetch_branch || return 1
      git merge-base --is-ancestor "$commit" "origin/$branch" || { _hs_err "commit ${commit:0:12} not reachable from $branch"; return 2; }
    fi
  }

  _hs_lfs_include_patterns() {
    local p probe type; local -a inc=()
    for p in "${PATHS[@]}"; do
      probe=${p%/}; [ -n "$probe" ] || probe=$p
      type=$(git cat-file -t "HEAD:$probe" 2>/dev/null || true)
      case "$type" in tree) inc+=("${probe%/}/**") ;; *) case "$p" in */) inc+=("${probe%/}/**") ;; *) inc+=("$p") ;; esac ;; esac
    done
    ( IFS=,; printf '%s' "${inc[*]}" )
  }

  _hs_export_tree() {
    case "$export_fmt" in
      "") return 0 ;;
      tar) tar --exclude=.git -czf "${out_name%%.tar.gz}.tar.gz" -C . . || return 1 ;;
      zip) command -v zip >/dev/null 2>&1 || { _hs_err "zip not found"; return 127; }; zip -qr "${out_name%%.zip}.zip" . -x ".git/*" || return 1 ;;
      dir)
        if command -v rsync >/dev/null 2>&1; then rsync -a --delete --exclude=.git ./ "${out_name}/" || return 1
        else mkdir -p -- "$out_name" || return 1; tar --exclude=.git -cf - . | (cd "$out_name" && tar -xf -) || return 1; fi
        ;;
      *) _hs_err "--export must be tar|zip|dir"; return 2 ;;
    esac
  }

  _hs_run_repo() {
    local op=$1 inc=""
    git sparse-checkout init --no-cone >/dev/null 2>&1 || { _hs_err "need Git >= 2.25 for non-cone sparse checkout"; return 2; }
    _hs_checkout_target || return $?
    _hs_load_paths || return $?
    git sparse-checkout "$op" -- "${PATHS[@]}" || return 1
    _hs_verify_requested || return $?
    if [ $lfs -eq 1 ] && command -v git-lfs >/dev/null 2>&1; then inc=$(_hs_lfs_include_patterns); [ -n "$inc" ] && git lfs pull --include="$inc" --exclude="" || true; fi
    _hs_export_tree || return $?
    git config --local feature.sparseIndex true >/dev/null 2>&1 || true
  }

  _hs_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"; }

  _hs_write_script() {
    local self_def
    self_def=$(typeset -f hsparse 2>/dev/null || declare -f hsparse 2>/dev/null) || { _hs_err "failed to retrieve hsparse definition for --script"; return 1; }
    umask 022
    {
      printf '#!/usr/bin/env bash\nset -euo pipefail\n\n%s\n\n' "$self_def"
      printf 'hsparse -r %s -p %s -d %s' "$(_hs_shq "$url")" "$(_hs_shq "$paths_csv")" "$(_hs_shq "$dest")"
      [ -n "$branch" ] && printf ' -b %s' "$(_hs_shq "$branch")"
      [ -n "$commit" ] && printf ' -c %s' "$(_hs_shq "$commit")"
      [ $quiet -eq 1 ] && printf ' -q'
      [ $verify -eq 1 ] && printf ' --verify'
      [ $lfs -eq 1 ] && printf ' --lfs'
      [ -n "$export_fmt" ] && printf ' --export %s' "$(_hs_shq "$export_fmt")"
      [ -n "$out_name" ] && printf ' -o %s' "$(_hs_shq "$out_name")"
      [ $use_ssh -eq 1 ] && printf ' --ssh'
      [ "$provider" != "auto" ] && printf ' --provider %s' "$(_hs_shq "$provider")"
      [ -n "$host" ] && printf ' --host %s' "$(_hs_shq "$host")"
      printf '\n'
    } >"$script_file" || { _hs_err "failed to write script: $script_file"; return 1; }
    chmod +x -- "$script_file" || true
  }

  [ $# -gt 0 ] || { _hs_usage >&2; return 2; }
  [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ] && { _hs_usage; return 0; }

  while [ $# -gt 0 ]; do
    case "$1" in
      -r|--repo) _hs_need_arg "$@" || return $?; repo=$2; shift 2 ;;
      -p|--paths) _hs_need_arg "$@" || return $?; _hs_append_paths_csv "$2"; shift 2 ;;
      --paths-file) _hs_need_arg "$@" || return $?; paths_file=$2; shift 2 ;;
      --paths-from) _hs_need_arg "$@" || return $?; paths_from=$2; shift 2 ;;
      -b|--branch) _hs_need_arg "$@" || return $?; branch=$2; shift 2 ;;
      -c|--commit) _hs_need_arg "$@" || return $?; commit=$2; shift 2 ;;
      -d|--dest) _hs_need_arg "$@" || return $?; dest=$2; shift 2 ;;
      -S|--ssh) use_ssh=1; shift ;;
      -A|--add|--update) add_mode=1; shift ;;
      -q|--quiet) quiet=1; qflagv=(-q); shift ;;
      --verify) verify=1; shift ;;
      --lfs) lfs=1; shift ;;
      --export) _hs_need_arg "$@" || return $?; export_fmt=$2; shift 2 ;;
      -o|--out) _hs_need_arg "$@" || return $?; out_name=$2; shift 2 ;;
      --script) _hs_need_arg "$@" || return $?; script_file=$2; shift 2 ;;
      --provider) _hs_need_arg "$@" || return $?; provider=$(_hs_lc "$2"); shift 2 ;;
      --host) _hs_need_arg "$@" || return $?; host=$2; shift 2 ;;
      --) shift; break ;;
      -h|--help) _hs_usage; return 0 ;;
      *) _hs_err "unknown option: $1"; return 2 ;;
    esac
  done

  [ $# -eq 0 ] || { _hs_err "unexpected positional arguments: $*"; return 2; }
  command -v git >/dev/null 2>&1 || { _hs_err "git not found"; return 127; }

  gitv=$(git version | sed -E 's/.* ([0-9]+(\.[0-9]+){1,}).*/\1/')
  _hs_git_ver_ge "$gitv" "2.25.0" || { _hs_err "need Git >= 2.25.0 (found $gitv)"; return 2; }

  [ -n "$repo" ] || { _hs_err "missing --repo"; return 2; }
  [ -n "$paths_file" ] && { pf=$(_hs_read_paths_source "$paths_file" "--paths-file") || return $?; _hs_append_paths_csv "$pf"; }
  [ -n "$paths_from" ] && { pg=$(_hs_read_paths_source "$paths_from" "--paths-from") || return $?; _hs_append_paths_csv "$pg"; }
  [ -n "$paths_csv" ] || { _hs_err "missing --paths (or --paths-file/--paths-from)"; return 2; }

  paths_csv=${paths_csv//, /,}; paths_csv=${paths_csv// ,/,}; paths_csv=${paths_csv#,}; paths_csv=${paths_csv%,}
  case "$export_fmt" in ""|tar|zip|dir) ;; *) _hs_err "--export must be tar|zip|dir"; return 2 ;; esac

  _hs_resolve_repo "$repo" || return $?
  [ -n "$dest" ] || dest=$reponame
  [ -n "$out_name" ] || out_name=$dest
  _hs_validate_dest || return $?

  if [ -n "$script_file" ]; then
    _hs_write_script || return $?
    [ $quiet -eq 1 ] || printf 'Wrote reproducible script: %s\n' "$script_file"
  fi

  if [ -d "$dest/.git" ]; then
    [ $add_mode -eq 1 ] || { _hs_err "destination exists as git repo; use --add/--update or --dest"; return 2; }
    ( cd "$dest" || exit 1; _hs_assert_matching_origin || exit $?; _hs_run_repo add )
    rc=$?; [ $rc -eq 0 ] || return $rc
    [ $quiet -eq 1 ] || { printf 'Updated sparse checkout in %s\n' "$dest"; git -C "$dest" sparse-checkout list || true; }
    return 0
  fi

  clone_flags=(--filter=blob:none --sparse --depth 1)
  [ -n "$branch" ] && clone_flags+=(--branch "$branch")
  git clone "${qflagv[@]}" "${clone_flags[@]}" "$url" "$dest" || return $?
  created_dest=1

  ( cd "$dest" || exit 1; _hs_assert_matching_origin || exit $?; _hs_run_repo set )
  rc=$?
  if [ $rc -ne 0 ]; then [ $created_dest -eq 1 ] && rm -rf -- "$dest"; return $rc; fi

  [ $quiet -eq 1 ] || { printf 'Sparse clone ready at %s\n' "$dest"; git -C "$dest" sparse-checkout list || true; }
}
