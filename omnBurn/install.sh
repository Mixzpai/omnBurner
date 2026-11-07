#!/usr/bin/env bash
# Builds omnBurn from this directory and installs it. On Omarchy it also adds
# "Burn USB" to the Omarchy menu and a key binding. Run it again to update;
# see ./install.sh --help.

set -euo pipefail

NIM_MIN=2.0.0
# The official Nim build downloaded (for this build only) when no Nim 2.0+ is
# installed. The checksums are nim-lang.org's published ones.
NIM_DL_VERSION=2.2.12
NIM_DL_SHA256_x64=7df1611449a6842af69322aa2c1206942982650a5f6bc0d37bc8ec109932f638
NIM_DL_SHA256_arm64=3dc04191af72a8310cf1c8ffb6f772cc3716fc5f264bc7c453ab4aecb4085221
MENU_ID=trigger.burn
DEFAULT_KEY="SUPER + SHIFT + U"

usage() {
  cat <<EOF
Usage: ./install.sh [OPTIONS]

Builds omnBurn and installs it, by default just for you, in ~/.local.
On Omarchy it also adds "Burn USB" to the Omarchy menu and a key binding.
Run it again at any time to update.

Options:
  --prefix DIR   install into DIR/bin and DIR/share/applications
                 (default: ~/.local; /usr/local installs it for everyone)
  --key COMBO    the key binding to add on Omarchy (default: "$DEFAULT_KEY")
  --no-key       don't add a key binding
  --no-menu      don't add an Omarchy menu entry
  -y, --yes      say yes to every question (installing packages, downloading Nim)
  --uninstall    remove what this script installed (pass the same --prefix)
  -h, --help     show this help
EOF
}

# --- Output ------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'
else
  B="" D="" G="" Y="" R="" N=""
fi
step() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
ok() { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
note() { printf '    %s\n' "$*"; }
item() { printf '  %s-%s %s\n' "$D" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
tilde() { printf '%s' "${1/#"$HOME"/\~}"; }

assume_yes=0
ask() { # ask QUESTION: yes (0) or no (1), defaulting to yes
  if [ "$assume_yes" = 1 ]; then printf '  %s [Y/n] yes\n' "$1"; return 0; fi
  if [ ! -t 0 ]; then printf '  %s [Y/n] no (no terminal to ask on; pass --yes)\n' "$1"; return 1; fi
  local answer
  read -r -p "  $1 [Y/n] " answer || return 1
  case "$answer" in "" | [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# --- Options -----------------------------------------------------------------

prefix=$HOME/.local
key=$DEFAULT_KEY
want_key=1
want_menu=1
uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; prefix=$2; shift ;;
    --prefix=*) prefix=${1#*=} ;;
    --key) [ $# -ge 2 ] || die "--key needs a combination like \"$DEFAULT_KEY\""; key=$2; shift ;;
    --key=*) key=${1#*=} ;;
    --no-key) want_key=0 ;;
    --no-menu) want_menu=0 ;;
    -y | --yes) assume_yes=1 ;;
    --uninstall) uninstall=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option '$1' (see ./install.sh --help)" ;;
  esac
  shift
done
case "$prefix" in /*) ;; *) prefix=$PWD/$prefix ;; esac
prefix=${prefix%/}
[[ $prefix =~ ^[A-Za-z0-9_./@+\ -]+$ ]] || die "the prefix '$prefix' has characters this script doesn't handle"
bindir=$prefix/bin
appdir=$prefix/share/applications

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/omnburn-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- Privileges and packages ---------------------------------------------------

as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif command -v sudo >/dev/null; then sudo "$@"
  elif command -v doas >/dev/null; then doas "$@"
  elif command -v run0 >/dev/null; then run0 "$@"
  else die "this needs root, and there's no sudo, doas or run0 to get it: $*"
  fi
}

writable() { # is DIR writable, or creatable, by us?
  local d=$1
  while [ ! -e "$d" ]; do d=$(dirname "$d"); done
  [ -w "$d" ]
}
priv() { # run a command that writes into the prefix
  if writable "$prefix"; then "$@"; else as_root "$@"; fi
}

family=unknown
if [ -r /etc/os-release ]; then
  for id in $(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}"); do
    case "$id" in
      arch | archarm | manjaro | endeavouros | cachyos | garuda) family=arch ;;
      debian | ubuntu | linuxmint | pop | raspbian | elementary | zorin | kali) family=debian ;;
      fedora | rhel | centos | rocky | almalinux | nobara) family=fedora ;;
      opensuse* | suse | sles) family=suse ;;
      alpine) family=alpine ;;
      void) family=void ;;
      *) continue ;;
    esac
    break
  done
fi

describe() {
  case "$1" in
    cc) echo "a C compiler" ;;
    zlib) echo "zlib" ;;
    bzip2) echo "bzip2 (libbz2)" ;;
    lzma) echo "xz (liblzma)" ;;
    lz4) echo "lz4" ;;
    zstd) echo "zstd" ;;
    crypto) echo "OpenSSL (libcrypto)" ;;
    kernel) echo "the Linux kernel headers" ;;
    curl) echo "curl or wget" ;;
    xz) echo "the xz tool" ;;
    tar) echo "tar" ;;
    nim) echo "Nim" ;;
  esac
}

package_for() { # package_for COMPONENT: the package(s) providing it on this distro
  case "$family:$1" in
    arch:cc | fedora:cc | suse:cc | void:cc) echo gcc ;;
    debian:cc) echo gcc libc6-dev ;;
    alpine:cc) echo build-base ;;
    arch:zlib) echo zlib ;;
    debian:zlib) echo zlib1g-dev ;;
    alpine:zlib) echo zlib-dev ;;
    *:zlib) echo zlib-devel ;;
    arch:bzip2) echo bzip2 ;;
    debian:bzip2) echo libbz2-dev ;;
    suse:bzip2) echo libbz2-devel ;;
    alpine:bzip2) echo bzip2-dev ;;
    *:bzip2) echo bzip2-devel ;;
    arch:lzma) echo xz ;;
    debian:lzma) echo liblzma-dev ;;
    alpine:lzma) echo xz-dev ;;
    void:lzma) echo liblzma-devel ;;
    *:lzma) echo xz-devel ;;
    arch:lz4) echo lz4 ;;
    debian:lz4) echo liblz4-dev ;;
    fedora:lz4) echo lz4-devel ;;
    alpine:lz4) echo lz4-dev ;;
    *:lz4) echo liblz4-devel ;;
    arch:zstd) echo zstd ;;
    debian:zstd) echo libzstd-dev ;;
    alpine:zstd) echo zstd-dev ;;
    *:zstd) echo libzstd-devel ;;
    arch:crypto) echo openssl ;;
    debian:crypto) echo libssl-dev ;;
    suse:crypto) echo libopenssl-devel ;;
    alpine:crypto) echo openssl-dev ;;
    *:crypto) echo openssl-devel ;;
    arch:kernel) echo linux-api-headers ;;
    debian:kernel) echo linux-libc-dev ;;
    fedora:kernel) echo kernel-headers ;;
    suse:kernel) echo linux-glibc-devel ;;
    alpine:kernel) echo linux-headers ;;
    void:kernel) echo kernel-libc-headers ;;
    debian:xz) echo xz-utils ;;
    debian:curl) echo curl ca-certificates ;; # only a Recommends there
    *:curl | *:xz | *:tar | *:nim) echo "$1" ;;
  esac
}

pkg_install() { # pkg_install PACKAGES...
  case "$family" in
    arch) as_root pacman -S --needed --noconfirm "$@" ;;
    debian) as_root apt-get update -qq && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
    fedora) as_root dnf install -y "$@" ;;
    suse) as_root zypper --non-interactive install "$@" ;;
    alpine) as_root apk add "$@" ;;
    void) as_root xbps-install -y "$@" ;;
  esac
}

install_missing() { # install_missing COMPONENTS...: offer to install them; false if not done
  local c pkgs=()
  for c in "$@"; do
    warn "Missing: $(describe "$c")"
    pkgs+=($(package_for "$c"))
  done
  if [ "$family" = unknown ] || [ ${#pkgs[@]} = 0 ]; then
    note "Install them with your package manager (the development packages,"
    note "often called *-dev or *-devel), then run ./install.sh again."
    return 1
  fi
  if ask "Install ${pkgs[*]} with your package manager?"; then
    pkg_install "${pkgs[@]}" || { warn "Installing the packages failed."; return 1; }
    return 0
  fi
  return 1
}

# --- Building ------------------------------------------------------------------

cc=""
find_cc() {
  local c
  for c in ${CC:-} gcc cc clang; do
    if command -v "$c" >/dev/null; then cc=$c; return 0; fi
  done
  return 1
}

try_c() { # try_c HEADER LIBFLAG: can we compile and link against it?
  { [ -n "$1" ] && printf '#include <%s>\n' "$1"; printf 'int main(void) { return 0; }\n'; } > "$tmp/conftest.c"
  "$cc" "$tmp/conftest.c" -o "$tmp/conftest" $2 >/dev/null 2>&1
}

missing_build_deps() {
  if ! find_cc || ! try_c stdlib.h ""; then
    echo cc zlib bzip2 lzma lz4 zstd crypto kernel # can't check the rest without a compiler
    return
  fi
  try_c zlib.h -lz || echo zlib
  try_c bzlib.h -lbz2 || echo bzip2
  try_c lzma.h -llzma || echo lzma
  try_c "" -llz4 || echo lz4
  try_c "" -lzstd || echo zstd
  try_c "" -lcrypto || echo crypto
  try_c linux/fs.h "" || echo kernel
}

version_ge() { # version_ge A B: is version A >= B?
  local IFS=. i
  local -a a=($1) b=($2)
  for i in 0 1 2; do
    ((10#${a[i]:-0} > 10#${b[i]:-0})) && return 0
    ((10#${a[i]:-0} < 10#${b[i]:-0})) && return 1
  done
  return 0
}

nim="" old_nim=""
find_nim() {
  local n v
  for n in ${NIM:-} "$(command -v nim 2>/dev/null || true)" "$HOME/.nimble/bin/nim" "$HOME"/.choosenim/toolchains/nim-*/bin/nim; do
    [ -n "$n" ] && [ -x "$n" ] || continue
    v=$("$n" --version 2>/dev/null | sed -n '1s/.*Version \([0-9][0-9.]*\).*/\1/p')
    [ -n "$v" ] || continue
    if version_ge "$v" "$NIM_MIN"; then nim=$n; return 0; fi
    old_nim="$n ($v)"
  done
  return 1
}

nim_download_arch() { # the official build's name for this machine, if there is one
  # The builds need glibc (Alpine's base image has no ldd, hence the second test).
  if ldd --version 2>&1 | grep -qi musl || compgen -G "/lib/ld-musl-*" >/dev/null; then return 1; fi
  case "$(uname -m)" in
    x86_64 | amd64) echo x64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) return 1 ;;
  esac
}

missing_download_tools() {
  command -v curl >/dev/null || command -v wget >/dev/null || echo curl
  command -v xz >/dev/null || echo xz
  command -v tar >/dev/null || echo tar
}

download_nim() {
  local arch sha name
  arch=$(nim_download_arch)
  if [ "$arch" = x64 ]; then sha=$NIM_DL_SHA256_x64; else sha=$NIM_DL_SHA256_arm64; fi
  name=nim-$NIM_DL_VERSION-linux_$arch.tar.xz
  local progress=()
  if command -v curl >/dev/null; then
    if [ -t 2 ]; then progress=(--progress-bar); else progress=(-sS); fi
    curl -fL --retry 3 "${progress[@]}" -o "$tmp/$name" "https://nim-lang.org/download/$name"
  else
    [ ! -t 2 ] || progress=(--show-progress)
    wget -q ${progress[@]+"${progress[@]}"} -O "$tmp/$name" "https://nim-lang.org/download/$name"
  fi || die "downloading Nim failed"
  local got
  read -r got _ < <(sha256sum "$tmp/$name")
  [ "$got" = "$sha" ] || die "the Nim download doesn't match its published checksum, so it wasn't used"
  tar -xJf "$tmp/$name" -C "$tmp"
  nim=$tmp/nim-$NIM_DL_VERSION/bin/nim
  ok "Downloaded Nim $NIM_DL_VERSION (checksum verified)"
}

nim_install_hint() {
  if command -v omarchy >/dev/null; then echo "omarchy pkg add nim"
  elif [ "$family" = arch ]; then echo "sudo pacman -S nim"
  else echo "your package manager, or https://nim-lang.org/install.html"
  fi
}

build() {
  step "Checking what the build needs"
  local missing
  missing=($(missing_build_deps))
  if ! find_nim; then
    if nim_download_arch >/dev/null; then missing+=($(missing_download_tools))
    else missing+=(nim)
    fi
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    install_missing "${missing[@]}" || die "omnBurn can't be built without $(describe "${missing[0]}")."
    missing=($(missing_build_deps))
    [ ${#missing[@]} = 0 ] || die "still missing $(describe "${missing[0]}") after installing packages."
    [ -n "$nim" ] || find_nim || true
  fi
  find_cc # (missing_build_deps ran in a subshell)
  ok "C compiler and libraries ($cc)"

  if [ -z "$nim" ]; then
    [ -n "$old_nim" ] && warn "Found Nim $old_nim, but omnBurn needs Nim $NIM_MIN or newer."
    if nim_download_arch >/dev/null; then
      note "No Nim $NIM_MIN+ is installed. The official Nim $NIM_DL_VERSION build (about 19 MB)"
      note "can be downloaded from nim-lang.org just for this build, then deleted."
      ask "Download it?" || die "install Nim $NIM_MIN+ ($(nim_install_hint)), then run ./install.sh again."
      download_nim
    else
      die "install Nim $NIM_MIN+ ($(nim_install_hint)), then run ./install.sh again."
    fi
  else
    ok "Nim $("$nim" --version | sed -n '1s/.*Version \([0-9][0-9.]*\).*/\1/p') ($(tilde "$nim"))"
  fi

  step "Building omnBurn"
  local ccflags=()
  case "$(basename "$cc")" in
    gcc) ;;
    clang) ccflags=(--cc:clang) ;;
    *) ccflags=(--cc:gcc "--gcc.exe:$cc" "--gcc.linkerexe:$cc") ;;
  esac
  if ! (cd "$src" && "$nim" c --hints:off --nimcache:"$tmp/nimcache" ${ccflags[@]+"${ccflags[@]}"} \
    -o:"$tmp/omnburn" src/omnburn.nim) > "$tmp/build.log" 2>&1; then
    tail -n 30 "$tmp/build.log" >&2
    cp "$tmp/build.log" "${TMPDIR:-/tmp}/omnburn-build.log"
    die "the build failed; the full log is in ${TMPDIR:-/tmp}/omnburn-build.log"
  fi
  "$tmp/omnburn" --version >/dev/null || die "the freshly built omnburn doesn't run"
  ok "Built $("$tmp/omnburn" --version)"
}

# --- Omarchy ---------------------------------------------------------------------

omarchy_path=""
for d in ${OMARCHY_PATH:-} /usr/share/omarchy "$HOME/.local/share/omarchy"; do
  if [ -d "$d/default" ]; then omarchy_path=$d; break; fi
done
on_omarchy() { [ -n "$omarchy_path" ] && command -v omarchy-launch-or-focus-tui >/dev/null; }

live_session() { # is this the Hyprland session whose config we're editing?
  [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null || return 1
  local home
  home=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  [ -z "$home" ] || [ "$home" = "$HOME" ]
}

backup() { # backup FILE: copies it aside and prints the copy's path
  local b
  b=$1.bak.$(date +%s)
  cp -p "$1" "$b"
  echo "$b"
}

menu_file=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc
hypr_dir=$HOME/.config/hypr

valid_jsonc() { # valid_jsonc FILE (only checked when python3 is around)
  command -v python3 >/dev/null || return 0
  python3 -I - "$1" <<'PY'
import json, re, sys
s = open(sys.argv[1], encoding="utf-8").read()
out, i, n = [], 0, len(s)
while i < n:
    if s[i] == '"':
        j = i + 1
        while j < n and s[j] != '"':
            j += 2 if s[j] == "\\" else 1
        out.append(s[i:j + 1])
        i = j + 1
    elif s.startswith("//", i):
        j = s.find("\n", i)
        i = n if j < 0 else j
    elif s.startswith("/*", i):
        j = s.find("*/", i + 2)
        i = n if j < 0 else j + 2
    else:
        out.append(s[i])
        i += 1
json.loads(re.sub(r",(\s*[}\]])", r"\1", "".join(out)))
PY
}

add_menu() { # add_menu COMMAND
  if [ ! -f "$omarchy_path/default/omarchy/omarchy-menu.jsonc" ]; then
    note "This Omarchy version's menu can't be extended; omnBurn is in the app launcher instead."
    return
  fi
  local line="\"$MENU_ID\": {\"icon\":\"󰕓\",\"label\":\"Burn USB\",\"aliases\":[\"omnburn\"],\"description\":\"Burn, back up or restore USB sticks with omnBurn\",\"action\":\"omarchy-launch-or-focus-tui $1\"},"
  if [ -f "$menu_file" ] && grep -q "\"$MENU_ID\"" "$menu_file"; then
    ok "The Omarchy menu already has omnBurn"
    menu_hint=1
    return
  fi
  local bak="" created=0
  mkdir -p "$(dirname "$menu_file")"
  if [ -f "$menu_file" ]; then
    bak=$(backup "$menu_file")
  else
    created=1
    if [ -f "$omarchy_path/config/omarchy/extensions/omarchy-menu.jsonc" ]; then
      cp "$omarchy_path/config/omarchy/extensions/omarchy-menu.jsonc" "$menu_file"
    else
      printf '{\n}\n' > "$menu_file"
    fi
  fi
  # Put the entry straight after the opening brace (and the comments under
  # it), so it never needs a comma added to someone else's line.
  if awk -v entry="$line" '
      function skip(l) { sub(/^[ \t]+/, "", l); return l == "" || l ~ /^\/\// }
      state == 0 {
        if (skip($0)) { print; next }
        t = $0; sub(/^[ \t]+/, "", t)
        if (t ~ /^\{[ \t]*(\/\/.*)?$/) { state = 1; print; next }
        exit 1
      }
      state == 1 {
        if (skip($0)) { print; next }
        print "  " entry; state = 2
      }
      { print }
      END { if (state != 2) exit 1 }' "$menu_file" > "$tmp/menu.jsonc" &&
    valid_jsonc "$tmp/menu.jsonc"; then
    cat "$tmp/menu.jsonc" > "$menu_file" # keeps symlinks (dotfile repos) intact
    ok "Added \"Burn USB\" to the Omarchy menu (under Trigger, or search for it)"
    menu_hint=1
    [ -z "$bak" ] || note "${D}Backup: $(tilde "$bak")${N}"
  else
    [ "$created" = 0 ] || rm -f "$menu_file"
    warn "Couldn't add the menu entry automatically. Add this line inside the outer braces of $(tilde "$menu_file"):"
    note "$line"
  fi
}

combo_id() { # combo_id "SUPER + SHIFT + U" → 65:U (Hyprland's modmask and key)
  local mask=0 k="" t
  for t in $(printf '%s' "$1" | tr '+,' '  ' | tr '[:lower:]' '[:upper:]'); do
    case "$t" in
      SHIFT) mask=$((mask | 1)) ;;
      CAPS | LOCK) mask=$((mask | 2)) ;;
      CTRL | CONTROL) mask=$((mask | 4)) ;;
      ALT | MOD1) mask=$((mask | 8)) ;;
      MOD2) mask=$((mask | 16)) ;;
      MOD3) mask=$((mask | 32)) ;;
      SUPER | WIN | LOGO | MOD4 | META) mask=$((mask | 64)) ;;
      MOD5) mask=$((mask | 128)) ;;
      *) [ -z "$k" ] || return 1; k=$t ;;
    esac
  done
  [ -n "$k" ] || return 1
  echo "$mask:$k"
}

pretty_combo() { # pretty_combo "super shift, u" → SUPER + SHIFT + U
  local t out=""
  for t in $(printf '%s' "$1" | tr '+,' '  ' | tr '[:lower:]' '[:upper:]'); do out=${out:+$out + }$t; done
  printf '%s' "$out"
}

key_taken() { # key_taken MASK:KEY → prints what already uses that combination
  local want=$1
  if live_session; then
    hyprctl binds 2>/dev/null | awk -v want="$want" '
      /^[a-z]/ { mm = ""; kk = ""; sm = ""; d = "" }
      /^\tmodmask:/ { mm = $2 }
      /^\tsubmap:/ { sm = $2 }
      /^\tkey:/ { kk = toupper($2) }
      /^\tdescription:/ { d = $0; sub(/^\tdescription: */, "", d) }
      /^\targ:/ {
        a = $0; sub(/^\targ: */, "", a)
        if (mm ":" kk == want && sm == "") { print (d != "" ? d : a); exit }
      }' || true
    return 0
  fi
  # Hyprland isn't running this config, so look through the files instead.
  local f combo files=()
  for f in "$hypr_dir"/*.lua "$hypr_dir"/*.conf "$omarchy_path"/default/hypr/*.lua \
    "$omarchy_path"/default/hypr/*/*.lua "$omarchy_path"/default/hypr/*.conf "$omarchy_path"/default/hypr/*/*.conf; do
    [ -f "$f" ] && files+=("$f")
  done
  [ ${#files[@]} -gt 0 ] || return 0
  {
    grep -ohE '^[[:space:]]*[a-z.]*bind\("[^"]+"' "${files[@]}" | sed -E 's/.*\("//; s/"$//'
    grep -ohE '^[[:space:]]*bind[a-z]*[[:space:]]*=[^,]*,[^,]*' "${files[@]}" | sed -E 's/^[^=]*=//'
  } 2>/dev/null | while read -r combo; do
    if [ "$(combo_id "$combo" || true)" = "$want" ]; then
      echo "another binding in your Hyprland config"
      break
    fi
  done || true
}

hypr_reload_checked() { # hypr_reload_checked FILE BACKUP ERRORS_BEFORE: undo FILE if Hyprland objects
  live_session || return 0
  hyprctl reload >/dev/null 2>&1 || true
  local errors
  errors=$(hyprctl configerrors 2>/dev/null || true)
  if [ -n "$errors" ] && [ "$errors" != "$3" ]; then
    cat "$2" > "$1"
    hyprctl reload >/dev/null 2>&1 || true
    warn "Hyprland reported errors, so $(tilde "$1") was put back as it was:"
    printf '%s\n' "$errors" | sed 's/^/      /'
    return 1
  fi
}

add_key() { # add_key COMMAND
  local file style
  if [ -f "$hypr_dir/bindings.lua" ]; then file=$hypr_dir/bindings.lua style=lua
  elif [ -f "$hypr_dir/bindings.conf" ]; then file=$hypr_dir/bindings.conf style=conf
  else
    note "No ~/.config/hypr/bindings.lua or bindings.conf, so no key binding was added."
    return
  fi
  local existing
  existing=$(grep -Ei '^[[:space:]]*([a-z.]*bind\(|bind[a-z]*[[:space:]]*=).*omnburn' "$file" | head -n 1 || true)
  if [ -n "$existing" ]; then
    local combo
    combo=$(printf '%s\n' "$existing" |
      sed -nE 's/^[^"]*bind\("([^"]+)".*/\1/p; s/^[[:space:]]*bind[a-z]*[[:space:]]*=[[:space:]]*([^,]*),([^,]*),.*/\1 \2/p')
    [ -z "$combo" ] || [[ $combo == *'$'* ]] || key_hint=$(pretty_combo "$combo") # skip $mainMod-style variables
    ok "omnBurn already has a key binding${key_hint:+ ($key_hint)} in $(tilde "$file")"
    return
  fi
  local id
  id=$(combo_id "$key") || die "--key \"$key\" isn't a key combination like \"$DEFAULT_KEY\""
  local mods=() t
  for t in $(printf '%s' "$key" | tr '+,' '  ' | tr '[:lower:]' '[:upper:]'); do mods+=("$t"); done
  local k=${mods[${#mods[@]} - 1]}
  unset 'mods[${#mods[@]}-1]'
  local pretty
  pretty=$(pretty_combo "$key")
  local taken
  taken=$(key_taken "$id")
  if [ -n "$taken" ]; then
    warn "$pretty is already taken ($taken), so no key binding was added."
    note "Pick another one with ./install.sh --key \"SUPER + ALT + U\"."
    return
  fi
  local bak before=""
  bak=$(backup "$file")
  if live_session; then before=$(hyprctl configerrors 2>/dev/null || true); fi
  [ -z "$(tail -c 1 "$file")" ] || echo >> "$file"
  if [ "$style" = lua ]; then
    printf '\n-- omnBurn: burn, back up or restore USB sticks\no.bind("%s", "omnBurn", "omarchy-launch-or-focus-tui %s")\n' \
      "$pretty" "$1" >> "$file"
  else
    printf '\n# omnBurn: burn, back up or restore USB sticks\nbindd = %s, %s, omnBurn, exec, omarchy-launch-or-focus-tui %s\n' \
      "${mods[*]-}" "$k" "$1" >> "$file"
  fi
  hypr_reload_checked "$file" "$bak" "$before" || return 0
  ok "Bound $pretty to omnBurn (in $(tilde "$file"))"
  note "${D}Backup: $(tilde "$bak")${N}"
  key_hint=$pretty
}

remove_menu() {
  [ -f "$menu_file" ] && grep -q "\"$MENU_ID\"" "$menu_file" || return 0
  local bak
  bak=$(backup "$menu_file")
  awk -v id="\"$MENU_ID\"" 'index($0, id) && tolower($0) ~ /omnburn/ { next } { print }' "$menu_file" > "$tmp/menu.jsonc"
  if valid_jsonc "$tmp/menu.jsonc"; then
    cat "$tmp/menu.jsonc" > "$menu_file"
  fi
  if grep -q "\"$MENU_ID\"" "$menu_file"; then
    warn "Couldn't remove \"$MENU_ID\" from $(tilde "$menu_file"); please delete it by hand."
  else
    ok "Removed omnBurn from the Omarchy menu"
  fi
}

remove_key() {
  local file
  for file in "$hypr_dir/bindings.lua" "$hypr_dir/bindings.conf"; do
    [ -f "$file" ] && grep -Eiq '^[[:space:]]*([a-z.]*bind\(|bind[a-z]*[[:space:]]*=).*omnburn' "$file" || continue
    local bak before=""
    bak=$(backup "$file")
    if live_session; then before=$(hyprctl configerrors 2>/dev/null || true); fi
    # Drops our comment and binding, and the blank line in front of them.
    awk '
      function ours(l) {
        l = tolower(l)
        return l ~ /^[ \t]*(--|#) omnburn:/ || (l ~ /^[ \t]*([a-z.]*bind\(|bind[a-z]*[ \t]*=)/ && l ~ /omnburn/)
      }
      ours($0) { held = 0; next }
      held { print ""; held = 0 }
      /^[ \t]*$/ { held = 1; next }
      { print }
      END { if (held) print "" }' "$file" > "$tmp/bindings"
    cat "$tmp/bindings" > "$file"
    hypr_reload_checked "$file" "$bak" "$before" || continue
    ok "Removed omnBurn's key binding from $(tilde "$file")"
  done
}

# --- Installing ------------------------------------------------------------------

desktop_entry() { # desktop_entry COMMAND → the launcher entry for it
  local exec=$1 term=false
  case "$exec" in *" "*) exec="\"$exec\"" ;; esac
  if on_omarchy; then
    exec="xdg-terminal-exec --app-id=org.omarchy.omnburn -e $exec %f"
  else
    exec="$exec %f" term=true
  fi
  local line # (not awk: minimal openSUSE doesn't have it)
  while IFS= read -r line; do
    case "$line" in
      Exec=*) printf 'Exec=%s\n' "$exec" ;;
      Terminal=*) printf 'Terminal=%s\n' "$term" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$src/extras/omnburn.desktop"
}

# What omnBurn runs, by the name it looks for, and what each is for. The
# Windows ones match WindowsTools in src/omnburn/tools.nim.
TOOLS=(
  "curl:downloading images"
  "gpg:checking signatures"
  "udisksctl:powering sticks off"
  "wipefs:restoring sticks and making Windows sticks"
  "sfdisk:restoring sticks and making Windows sticks"
  "blockdev:making Windows sticks"
  "mount:making Windows sticks"
  "mkfs.exfat:restoring sticks as exFAT"
  "mkfs.fat:restoring sticks as FAT32 and making Windows sticks"
  "wimlib-imagex:making Windows sticks (it splits install.wim, too big for FAT32)"
  "notify-send:desktop notifications"
)

tool_package() { # tool_package TOOL: the package(s) that have it on this distro
  case "$family:$1" in
    debian:curl) echo curl ca-certificates ;;
    fedora:gpg) echo gnupg2 ;;
    suse:gpg) echo gpg2 ;;
    *:gpg) echo gnupg ;;
    *:udisksctl) echo udisks2 ;;
    debian:sfdisk) echo fdisk ;;
    debian:mount) echo mount ;;
    *:wipefs | *:sfdisk | *:blockdev | *:mount) echo util-linux ;;
    *:mkfs.exfat) echo exfatprogs ;;
    *:mkfs.fat) echo dosfstools ;;
    debian:wimlib-imagex | suse:wimlib-imagex) echo wimtools ;;
    fedora:wimlib-imagex) echo wimlib-utils ;;
    *:wimlib-imagex) echo wimlib ;;
    debian:notify-send) echo libnotify-bin ;;
    suse:notify-send) echo libnotify-tools ;;
    *:notify-send) echo libnotify ;;
    *) echo "$1" ;;
  esac
}

has_tool() { # has_tool NAME: is it installed? (sbin isn't on users' PATH on Debian and Ubuntu)
  command -v "$1" >/dev/null || [ -x "/usr/local/sbin/$1" ] || [ -x "/usr/sbin/$1" ] || [ -x "/sbin/$1" ]
}

missing_tools() {
  local t
  for t in "${TOOLS[@]}"; do has_tool "${t%%:*}" || echo "${t%%:*}"; done
}

purpose() {
  local t
  for t in "${TOOLS[@]}"; do [ "${t%%:*}" != "$1" ] || echo "${t#*:}"; done
}

can_be_root() {
  [ "$(id -u)" = 0 ] || command -v sudo >/dev/null || command -v doas >/dev/null || command -v run0 >/dev/null
}

reads_udf() { # can the kernel read UDF, which Windows ISOs keep their files in? (yes if it can't tell)
  grep -qw udf /proc/filesystems 2>/dev/null && return 0
  local d
  for d in /lib/modules /usr/lib/modules; do
    [ -d "$d/$(uname -r)" ] || continue
    grep -qs '/udf\.ko' "$d/$(uname -r)/modules.dep" "$d/$(uname -r)/modules.builtin"
    return
  done
  return 0
}

runtime_tools() {
  step "Checking the tools omnBurn runs"
  local missing pkgs=() t p
  missing=($(missing_tools))
  for t in ${missing[@]+"${missing[@]}"}; do
    warn "Missing: $t, for $(purpose "$t")"
    for p in $(tool_package "$t"); do
      [[ " ${pkgs[*]-} " == *" $p "* ]] || pkgs+=("$p")
    done
  done
  if [ ${#missing[@]} -gt 0 ] && [ "$family" != unknown ] && can_be_root &&
    ask "Install ${pkgs[*]} with your package manager?"; then
    if ! pkg_install "${pkgs[@]}"; then
      # One package that isn't there (say, wimlib-utils on RHEL without EPEL)
      # mustn't stop the others.
      for p in "${pkgs[@]}"; do pkg_install "$p" || warn "Couldn't install $p."; done
    fi
    hash -r
    missing=($(missing_tools))
    for t in ${missing[@]+"${missing[@]}"}; do warn "Still missing: $t"; done
  fi
  if [ ${#missing[@]} = 0 ]; then
    ok "All there, including what Windows sticks need"
  else
    pkgs=()
    for t in "${missing[@]}"; do
      for p in $(tool_package "$t"); do
        [[ " ${pkgs[*]-} " == *" $p "* ]] || pkgs+=("$p")
      done
    done
    note "omnBurn works without them, minus what they're for. To add them later,"
    note "install ${pkgs[*]} with your package manager, or run ./install.sh again."
  fi
  if ! reads_udf; then
    warn "This kernel can't read UDF, the filesystem of Windows ISOs, so omnBurn can't"
    note "make Windows sticks with it. Start the PC with your distribution's standard kernel."
  fi
}

do_install() {
  [ -f "$src/src/omnburn.nim" ] || die "run this from a copy of the omnBurn repository."
  if [ "$(id -u)" = 0 ] && [ "$prefix" = "$HOME/.local" ]; then
    warn "You're running this as root, so omnBurn would only be installed for root."
    note "Run it as yourself instead; it uses sudo when it needs to."
    ask "Install it for root anyway?" || exit 1
  fi
  build

  step "Installing into $(tilde "$prefix")"
  writable "$prefix" || note "That needs root."
  priv install -Dm755 "$tmp/omnburn" "$bindir/omnburn"
  ok "$(tilde "$bindir/omnburn")"
  hash -r
  local cmd=$bindir/omnburn on_path
  on_path=$(command -v omnburn 2>/dev/null || true)
  [ -z "$on_path" ] || [ "$(readlink -f "$on_path")" != "$(readlink -f "$cmd")" ] || cmd=omnburn
  desktop_entry "$cmd" > "$tmp/omnburn.desktop"
  priv install -Dm644 "$tmp/omnburn.desktop" "$appdir/omnburn.desktop"
  if command -v update-desktop-database >/dev/null; then priv update-desktop-database -q "$appdir" || true; fi
  ok "$(tilde "$appdir/omnburn.desktop") (app launcher, and \"Open with\" for disk images)"

  key_hint="" menu_hint=0
  if on_omarchy && { [ "$want_menu" = 1 ] || [ "$want_key" = 1 ]; }; then
    step "Adding omnBurn to Omarchy"
    if [[ ! $cmd =~ ^[A-Za-z0-9_./+-]+$ ]]; then
      warn "The install path has spaces, so the menu entry and key binding were skipped."
    else
      [ "$want_menu" = 0 ] || add_menu "$cmd"
      [ "$want_key" = 0 ] || add_key "$cmd"
    fi
  fi

  runtime_tools

  step "Done. Open omnBurn with any of these:"
  [ -z "$key_hint" ] || item "${B}$key_hint${N}"
  [ "$menu_hint" = 0 ] || item "${B}Burn USB${N} in the Omarchy menu"
  item "${B}omnBurn${N} in your app launcher"
  if [ "$cmd" = omnburn ]; then
    item "${B}omnburn${N} in a terminal"
  else
    item "${B}$(tilde "$bindir/omnburn")${N} in a terminal (add $(tilde "$bindir") to your PATH to type just omnburn)"
  fi
}

do_uninstall() {
  step "Removing omnBurn from $(tilde "$prefix")"
  local f
  for f in "$bindir/omnburn" "$appdir/omnburn.desktop"; do
    if [ -e "$f" ]; then priv rm -f "$f" && ok "Removed $(tilde "$f")"; fi
  done
  if command -v update-desktop-database >/dev/null && [ -d "$appdir" ]; then
    priv update-desktop-database -q "$appdir" || true
  fi
  if on_omarchy; then
    remove_menu
    remove_key
  fi
  hash -r
  if command -v omnburn >/dev/null; then
    warn "There's still an omnburn at $(tilde "$(command -v omnburn)"); pass its --prefix to remove it."
  fi
  step "Done"
}

if [ "$uninstall" = 1 ]; then do_uninstall; else do_install; fi
