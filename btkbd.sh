#!/usr/bin/env bash
# btkbd.sh - turn a rooted Android phone into a standard Bluetooth HID keyboard
#            for a Windows PC, driven entirely from bash.
#
#   bash btkbd.sh up                    # check -> enable -> build -> start -> connect
#   bash btkbd.sh type "hello world"
#   bash btkbd.sh key CTRL+ALT+DELETE
#
# or from your own script:
#
#   source btkbd.sh
#   btkbd_require_connected
#   send_text "Hello world"
#   send_key ENTER
#
# Everything except the HID registration itself is bash. The registration needs
# android.bluetooth.BluetoothHidDevice (no shell command exposes it), so this
# script carries a small Java helper, compiles it on-device once, and runs it
# headless via app_process. See README.md.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "btkbd: needs bash 4+ (Termux ships bash 5). Run with: bash btkbd.sh" >&2
  return 1 2>/dev/null || exit 1
fi

# CRLF is fatal but silent: every path variable would carry a trailing \r, so the
# helper's log/pid/jar paths silently become different files and nothing appears
# to run. Common when the file is copied from Windows.
IFS= read -r __btkbd_l0 < "${BASH_SOURCE[0]}" 2>/dev/null
case ${__btkbd_l0:-} in
  *$'\r')
    echo "btkbd: this file has Windows CRLF line endings, which breaks every path it builds." >&2
    echo "btkbd: fix with:  sed -i 's/\r\$//' ${BASH_SOURCE[0]}" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
unset __btkbd_l0

# ---------------------------------------------------------------------------
# configuration (all overridable from the environment)
# ---------------------------------------------------------------------------
BTKBD_HOME=${BTKBD_HOME:-$HOME/.btkbd}          # build dir, owned by Termux
BTKBD_RUN=${BTKBD_RUN:-/data/local/tmp/btkbd}   # runtime dir, owned by uid 2000
BTKBD_PORT=${BTKBD_PORT:-8722}                  # loopback control port
BTKBD_DELAY_MS=${BTKBD_DELAY_MS:-6}             # pause after every HID report
BTKBD_SU=${BTKBD_SU:-su}
BTKBD_DEVICE_NAME=${BTKBD_DEVICE_NAME:-Bluetooth Keyboard}
BTKBD_HID_PROP=bluetooth.profile.hid.device.enabled
# Bumped whenever the helper's command set changes, so a stale running helper is
# reported as such instead of answering "unknown-command".
BTKBD_PROTO=3

BTKBD_SELF=${BASH_SOURCE[0]}
STATE=$BTKBD_HOME/state
SRC=$BTKBD_HOME/src
STUBS=$BTKBD_HOME/stubs
JAR=$BTKBD_RUN/btkbd.jar
SRVLOG=$BTKBD_RUN/server.log
PIDFILE=$BTKBD_RUN/pid

FAILS=0
WARNS=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_C=$'\033[36m'; C_0=$'\033[0m'
else
  C_B=; C_R=; C_G=; C_Y=; C_C=; C_0=
fi

hdr()  { printf '\n%s=== %s ===%s\n' "$C_B" "$*" "$C_0"; }
step() { printf '\n%s%s%s\n' "$C_B" "» $1" "$C_0"; [ -n "${2:-}" ] && printf '   what/why: %s\n' "$2"; }
pass() { printf '   %sPASS%s %s\n' "$C_G" "$C_0" "$*"; }
fail() { printf '   %sFAIL%s %s\n' "$C_R" "$C_0" "$*"; FAILS=$((FAILS+1)); }
warn() { printf '   %sWARN%s %s\n' "$C_Y" "$C_0" "$*"; WARNS=$((WARNS+1)); }
info() { printf '   %s\n' "$*"; }
say()  { printf '%s\n' "$*"; }
err()  { printf '%sbtkbd:%s %s\n' "$C_R" "$C_0" "$*" >&2; }

# When the script is executed, a fatal error must end the process. When it is
# sourced, exiting would kill the user's shell, so `die` only reports and the
# call sites return - hence the `|| { die ...; return 1; }` form below.
BTKBD_SOURCED=0
[ "${BASH_SOURCE[0]}" != "$0" ] && BTKBD_SOURCED=1
die() {
  err "$*"
  [ "$BTKBD_SOURCED" = 1 ] && return 1
  exit 1
}

# ---------------------------------------------------------------------------
# root helpers
#   sur  - run as root (uid 0)
#   sush - run as shell (uid 2000); the HID helper runs here because Android's
#          BLUETOOTH_CONNECT check resolves uid 2000 to package com.android.shell
# ---------------------------------------------------------------------------
sur()  { "$BTKBD_SU" -c "$*" 2>&1; }
sush() { "$BTKBD_SU" 2000 -c "$*" 2>&1; }

have_root() { [ "$(sur id -u 2>/dev/null)" = 0 ]; }

have_shell_su() {
  [ "$(sush id -u 2>/dev/null)" = 2000 ]
}

# ---------------------------------------------------------------------------
# state file
# ---------------------------------------------------------------------------
state_load() { [ -f "$STATE" ] && . "$STATE"; return 0; }
state_save() {
  mkdir -p "$BTKBD_HOME"
  { echo "PORT=$PORT"; echo "TOKEN=$TOKEN"; echo "MAC=${MAC:-}"; } > "$STATE"
  chmod 600 "$STATE"
}

# ===========================================================================
# 1. keymap  (US QWERTY -> HID usage IDs, HID Usage Table 1.12 section 10)
# ===========================================================================
declare -A KEY=()      # named key   -> "0xNN" or "S:0xNN" (S = needs shift)
declare -A CHAR=()     # literal char -> "<shift> 0xNN"
KEYMAP_READY=

keymap_init() {
  [ -n "$KEYMAP_READY" ] && return 0
  local i c

  # a-z -> 0x04..0x1d ; stored uppercase, no shift (CTRL+C must not send shift)
  for i in $(seq 0 25); do
    c=$(printf "\\$(printf '%03o' $((65+i)))")
    KEY[$c]=$(printf '0x%02x' $((0x04+i)))
  done
  # 1-9 -> 0x1e..0x26 , 0 -> 0x27
  for i in $(seq 1 9); do KEY[$i]=$(printf '0x%02x' $((0x1e+i-1))); done
  KEY[0]=0x27

  # "NAME USAGE" pairs; "S:" prefix means the key needs shift. Split on plain
  # whitespace via set --, so no IFS juggling (which silently breaks `read`).
  local named='
    ENTER 0x28  RETURN 0x28  CR 0x28  ESC 0x29  ESCAPE 0x29
    BACKSPACE 0x2a  BKSP 0x2a  BS 0x2a  TAB 0x2b  SPACE 0x2c  SPACEBAR 0x2c
    MINUS 0x2d  DASH 0x2d  HYPHEN 0x2d  EQUAL 0x2e  EQUALS 0x2e
    LBRACKET 0x2f  RBRACKET 0x30  BACKSLASH 0x31  SEMICOLON 0x33
    QUOTE 0x34  APOSTROPHE 0x34  GRAVE 0x35  BACKTICK 0x35
    COMMA 0x36  PERIOD 0x37  DOT 0x37  SLASH 0x38  CAPSLOCK 0x39
    PRINTSCREEN 0x46  PRTSC 0x46  SYSRQ 0x46  SCROLLLOCK 0x47  PAUSE 0x48  BREAK 0x48
    INSERT 0x49  INS 0x49  HOME 0x4a  PAGEUP 0x4b  PGUP 0x4b
    DELETE 0x4c  DEL 0x4c  END 0x4d  PAGEDOWN 0x4e  PGDN 0x4e
    RIGHT 0x4f  LEFT 0x50  DOWN 0x51  UP 0x52  NUMLOCK 0x53
    KP_SLASH 0x54  KP_STAR 0x55  KP_MINUS 0x56  KP_PLUS 0x57  KP_ENTER 0x58  KP_DOT 0x63
    MENU 0x65  APP 0x65  CONTEXT 0x65  POWER 0x66
    BANG S:0x1e  EXCLAIM S:0x1e  AT S:0x1f  HASH S:0x20  DOLLAR S:0x21  PERCENT S:0x22
    CARET S:0x23  AMP S:0x24  STAR S:0x25  LPAREN S:0x26  RPAREN S:0x27
    UNDERSCORE S:0x2d  PLUS S:0x2e  LBRACE S:0x2f  RBRACE S:0x30  PIPE S:0x31
    COLON S:0x33  DQUOTE S:0x34  TILDE S:0x35  LT S:0x36  GT S:0x37  QUESTION S:0x38'
  set -- $named
  while [ $# -ge 2 ]; do KEY[$1]=$2; shift 2; done

  for i in $(seq 1 12);  do KEY[F$i]=$(printf '0x%02x' $((0x3a+i-1))); done
  for i in $(seq 13 24); do KEY[F$i]=$(printf '0x%02x' $((0x68+i-13))); done
  for i in $(seq 1 9);   do KEY[KP_$i]=$(printf '0x%02x' $((0x59+i-1))); done
  KEY[KP_0]=0x62

  # printable ASCII -> (shift, usage). Keyed by hex code so quoting is never an
  # issue for characters like space, backslash or the quotes themselves.
  # "ASCII-HEX SHIFT USAGE" triples. Keyed by character code so that quoting is
  # never an issue for space, backslash or the quote characters themselves.
  local codes='
    20 0 0x2c   21 1 0x1e   22 1 0x34   23 1 0x20   24 1 0x21   25 1 0x22
    26 1 0x24   27 0 0x34   28 1 0x26   29 1 0x27   2a 1 0x25   2b 1 0x2e
    2c 0 0x36   2d 0 0x2d   2e 0 0x37   2f 0 0x38   3a 1 0x33   3b 0 0x33
    3c 1 0x36   3d 0 0x2e   3e 1 0x37   3f 1 0x38   40 1 0x1f   5b 0 0x2f
    5c 0 0x31   5d 0 0x30   5e 1 0x23   5f 1 0x2d   60 0 0x35   7b 1 0x2f
    7c 1 0x31   7d 1 0x30   7e 1 0x35'
  set -- $codes
  while [ $# -ge 3 ]; do
    c=$(printf "\\x$1")
    CHAR[$c]="$2 $3"
    shift 3
  done

  for i in $(seq 0 25); do
    c=$(printf "\\$(printf '%03o' $((97+i)))"); CHAR[$c]="0 $(printf '0x%02x' $((0x04+i)))"
    c=$(printf "\\$(printf '%03o' $((65+i)))"); CHAR[$c]="1 $(printf '0x%02x' $((0x04+i)))"
  done
  for i in $(seq 1 9); do CHAR[$i]="0 $(printf '0x%02x' $((0x1e+i-1)))"; done
  CHAR[0]="0 0x27"

  KEYMAP_READY=1
}

modbit() {
  case ${1^^} in
    CTRL|CONTROL|LCTRL|LEFTCTRL)          echo 1 ;;
    SHIFT|LSHIFT|LEFTSHIFT)               echo 2 ;;
    ALT|LALT|LEFTALT|OPT|OPTION)          echo 4 ;;
    WIN|GUI|META|SUPER|CMD|LWIN|LGUI)     echo 8 ;;
    RCTRL|RIGHTCTRL)                      echo 16 ;;
    RSHIFT|RIGHTSHIFT)                    echo 32 ;;
    RALT|RIGHTALT|ALTGR)                  echo 64 ;;
    RWIN|RGUI|RMETA)                      echo 128 ;;
    *)                                    echo -1 ;;
  esac
}

# ===========================================================================
# 2. transport: one loopback connection to the helper, reused for the run
# ===========================================================================
BTKBD_IN=; BTKBD_OUT=; BTKBD_REPLY=

link_down() {
  [ -n "$BTKBD_IN" ] && exec {BTKBD_IN}>&- 2>/dev/null
  [ -n "$BTKBD_OUT" ] && [ "$BTKBD_OUT" != "$BTKBD_IN" ] && exec {BTKBD_OUT}>&- 2>/dev/null
  BTKBD_IN=; BTKBD_OUT=
}

port_open() {
  (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null && return 0
  command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$1" >/dev/null 2>&1
}

# Was this bash built with /dev/tcp support? Without it (and without nc) the
# control channel cannot be reached even when the helper is running fine.
bash_net_ok() {
  case $( { : </dev/tcp/127.0.0.1/1; } 2>&1 ) in
    *"No such file or directory"*) return 1 ;;
    *) return 0 ;;
  esac
}

helper_pid() {
  local p; p=$(sur "cat $PIDFILE" 2>/dev/null | tr -dc '0-9')
  [ -n "$p" ] && printf '%s' "$p"
}

helper_alive() {
  local p; p=$(helper_pid) || return 1
  [ -n "$p" ] || return 1
  sur "kill -0 $p" >/dev/null 2>&1
}

link_up() {
  [ -n "$BTKBD_IN" ] && return 0
  state_load
  local port=${PORT:-$BTKBD_PORT} token=${TOKEN:-}
  [ -z "$token" ] && { err "no session token - run: bash ${BTKBD_SELF} start"; return 1; }

  if exec {BTKBD_IN}<>/dev/tcp/127.0.0.1/"$port" 2>/dev/null; then
    BTKBD_OUT=$BTKBD_IN
  elif command -v nc >/dev/null 2>&1; then
    coproc BTKBD_NC { exec nc 127.0.0.1 "$port"; }
    BTKBD_IN=${BTKBD_NC[0]}; BTKBD_OUT=${BTKBD_NC[1]}
  else
    err "cannot reach helper on 127.0.0.1:$port (is it running? 'bash ${BTKBD_SELF} status')"
    return 1
  fi

  printf 'AUTH %s\n' "$token" >&"$BTKBD_OUT"
  local reply
  if ! IFS= read -r -t 5 reply <&"$BTKBD_IN" || [ "${reply:0:2}" != OK ]; then
    err "helper rejected AUTH (${reply:-no reply})"
    link_down; return 1
  fi
  # A helper built from an older copy of this script answers "unknown-command"
  # for anything new; say so plainly instead.
  local v=
  case $reply in *version=*) v=${reply##*version=}; v=${v%% *} ;; esac
  if [ "$v" != "$BTKBD_PROTO" ]; then
    warn "the running helper is build '${v:-pre-versioning}' but this script expects $BTKBD_PROTO"
    warn "it will not understand newer commands. Rebuild and restart it:"
    warn "  bash ${BTKBD_SELF} build && bash ${BTKBD_SELF} restart"
    warn "(if you are running it via 'trace', Ctrl-C that session and re-run trace)"
  fi
  ctl "DELAY $BTKBD_DELAY_MS" >/dev/null
  return 0
}

# send one command line, read one reply line
ctl() {
  link_up || return 1
  printf '%s\n' "$1" >&"$BTKBD_OUT"
  local reply
  if ! IFS= read -r -t 20 reply <&"$BTKBD_IN"; then
    err "helper stopped responding"; link_down; return 1
  fi
  BTKBD_REPLY=$reply
  printf '%s\n' "$reply"
  [ "${reply:0:2}" = OK ]
}

# ===========================================================================
# 3. HID report generation  (requirement 6)
#    report = [modifiers, 0x00, key1..key6]; every press is followed by a
#    release report, which is also what makes repeated characters work.
# ===========================================================================
# Never fail silently: the helper's reply is the only explanation of why a
# keystroke went nowhere (not registered / no host / send-failed).
send_report() {
  ctl "R $1" >/dev/null && return 0
  case ${BTKBD_REPLY:-} in
    *not-connected*)  err "the HID link is not open (${BTKBD_REPLY#ERR not-connected }) - paired is not enough."
                      err "run: bash ${BTKBD_SELF} connect     (or click the phone on Windows)" ;;
    *no-host*)        err "no HID host known yet - pair first: bash ${BTKBD_SELF} pair" ;;
    *not-registered*) err "the helper is not registered as a keyboard - run: bash ${BTKBD_SELF} start" ;;
    *send-failed*)    err "the stack refused the report (link dropped?) - bash ${BTKBD_SELF} status" ;;
    "")               err "no reply from the helper - bash ${BTKBD_SELF} status" ;;
    *)                err "helper refused the report: $BTKBD_REPLY" ;;
  esac
  return 1
}

_press() { # $1 modifier byte (dec), $2 usage (dec/hex, 0 = none)
  send_report "$(printf '%02x00%02x0000000000' "$1" "$2")"
}
_release() { send_report 0000000000000000; }

send_key() {
  keymap_init
  local spec=$1 mods=0 parts=() n i tok val usage bit
  [ -z "$spec" ] && { err "send_key: missing key"; return 2; }

  IFS='+' read -ra parts <<<"$spec"
  n=${#parts[@]}
  # a trailing "+" means the literal plus key: CTRL++ -> CTRL + PLUS
  if [ -z "${parts[n-1]}" ] && [ "$n" -gt 1 ]; then parts[n-1]=PLUS; fi

  for ((i=0; i<n-1; i++)); do
    bit=$(modbit "${parts[i]}")
    [ "$bit" -lt 0 ] && { err "send_key: unknown modifier '${parts[i]}' in '$spec'"; return 2; }
    mods=$((mods | bit))
  done

  tok=${parts[n-1]}
  val=${KEY[${tok^^}]:-}
  if [ -z "$val" ] && [ ${#tok} -eq 1 ]; then
    val=${CHAR[$tok]:-}
    if [ -n "$val" ]; then
      set -- $val
      [ "$1" = 1 ] && mods=$((mods | 2))
      val=$2
    fi
  fi
  [ -z "$val" ] && { err "send_key: unknown key '$tok' (try: bash ${BTKBD_SELF} keys)"; return 2; }
  if [ "${val:0:2}" = "S:" ]; then mods=$((mods | 2)); val=${val:2}; fi

  usage=$((val))
  _press "$mods" "$usage" && _release
}

send_text() {
  keymap_init
  local s=$1 i c entry sh us mods
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case $c in
      $'\n') mods=0; us=$((0x28)) ;;
      $'\t') mods=0; us=$((0x2b)) ;;
      $'\r') continue ;;
      *)
        entry=${CHAR[$c]:-}
        if [ -z "$entry" ]; then
          err "send_text: skipping unsupported character '$c' (US-ASCII only)"
          continue
        fi
        set -- $entry
        sh=$1; us=$(($2)); mods=0
        [ "$sh" = 1 ] && mods=2
        ;;
    esac
    _press "$mods" "$us" || return 1
    _release || return 1
  done
  return 0
}

send_raw() { send_report "$1"; }

btkbd_require_connected() {
  if ! server_running; then
    # Don't start a second helper on top of a live one just because the socket
    # is unreachable - that only produces an "address in use" failure.
    if helper_alive; then
      err "the helper process is alive (pid $(helper_pid)) but its control port $PORT"
      err "is unreachable from Termux, so keystrokes cannot be delivered to it."
      err "bash /dev/tcp support: $(bash_net_ok && echo yes || echo no); nc installed: $(need_tool nc && echo yes || echo no)"
      err "fix: pkg install netcat-openbsd"
      return 1
    fi
    cmd_start || return 1
  fi
  local st
  st=$(ctl '?' 2>/dev/null)
  case $st in
    *state=CONNECTED*) return 0 ;;
  esac
  say "not connected yet - trying to reuse an existing pairing..."
  cmd_connect "$@" || return 1
}

# ===========================================================================
# 4. checks  (requirement 1)
# ===========================================================================
sdk_level() { getprop ro.build.version.sdk 2>/dev/null; }

# Which Bluetooth app this ROM ships (AOSP name vs GMS name).
bt_pkg() {
  local p
  for p in com.android.bluetooth com.google.android.bluetooth; do
    sur "pm path $p" | grep -q '^package:' && { printf '%s' "$p"; return 0; }
  done
  return 1
}

bt_apk() {
  local p; p=$(bt_pkg) || return 1
  sur "pm path $p" | sed -n 's/^package://p' | tr -d '\r' | head -1
}

# The decisive signal: is the class in the Bluetooth app's dex at all?
# /apex and /system APKs are world-readable and their dex is stored uncompressed,
# so a plain grep usually works without root. Returns the hit count on stdout.
apk_hid_hits() {
  local apk=$1 n
  [ -n "$apk" ] || { echo 0; return 1; }
  n=$(grep -ac HidDeviceService "$apk" 2>/dev/null | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] 2>/dev/null && { echo "$n"; return 0; }
  n=$(sur "grep -ac HidDeviceService '$apk'" 2>/dev/null | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] 2>/dev/null && { echo "$n"; return 0; }
  if need_tool unzip; then
    n=$(unzip -p "$apk" 'classes*.dex' 2>/dev/null | grep -ac HidDeviceService | tr -dc '0-9')
    [ "${n:-0}" -gt 0 ] 2>/dev/null && { echo "$n"; return 0; }
  fi
  echo 0
  return 1
}

# NOTE: do not use `dumpsys package <pkg>` for this. It only enumerates
# components that have intent filters; HidDeviceService is started internally by
# the profile manager and declares none, so it is invisible there even on ROMs
# with full HID Device support.
#
# prints exactly one of: running | present | absent | unknown
hid_support_verdict() {
  hid_service_running && { echo running; return 0; }

  if sur "test -f $JAR"; then
    case $(cmd_probe 2>/dev/null) in
      *hidDeviceSupported=yes*) echo present; return 0 ;;
    esac
  fi

  local apk; apk=$(bt_apk)
  if [ -n "$apk" ]; then
    if [ "$(apk_hid_hits "$apk")" -gt 0 ] 2>/dev/null; then echo present; else echo absent; fi
    return 0
  fi
  echo unknown
}
hid_service_running() {
  sur "dumpsys activity services com.android.bluetooth" | grep -qi 'HidDeviceService' ||
  sur "dumpsys activity services com.google.android.bluetooth" | grep -qi 'HidDeviceService' ||
  sur "dumpsys bluetooth_manager" | grep -qiE 'hiddevice|hid_device'
}
adapter_on() { [ "$(sur "settings get global bluetooth_on" 2>/dev/null | tr -d '\r')" = 1 ]; }

cmd_check() {
  FAILS=0; WARNS=0
  hdr "Bluetooth HID Device capability check"

  step "Android framework level" \
       "BluetoothHidDevice (the API that lets a phone BE a keyboard) exists since Android 9 / API 28. Reading ro.build.version.sdk."
  local sdk; sdk=$(sdk_level)
  if [ -n "$sdk" ] && [ "$sdk" -ge 28 ] 2>/dev/null; then
    pass "API $sdk (Android $(getprop ro.build.version.release)) >= 28"
  else
    fail "API '${sdk:-unknown}' is below 28 - BluetoothHidDevice does not exist on this platform"
  fi

  step "Root access" \
       "Root is needed to run the HID helper as uid 2000 (shell), to flip the profile sysprop, and to read dumpsys/logcat."
  if have_root; then
    pass "su works, uid 0"
    if have_shell_su; then pass "su can drop to uid 2000 (shell) - preferred way to run the helper"
    else warn "'su 2000 -c' not supported by this su; helper will run as root (usually still fine)"; fi
  else
    fail "no working su - this tool cannot work without root"
  fi

  step "Bluetooth hardware (classic BR/EDR)" \
       "HID Device uses classic Bluetooth L2CAP, not BLE. Checking the android.hardware.bluetooth feature."
  if sur "pm list features" | grep -q 'android.hardware.bluetooth$'; then
    pass "android.hardware.bluetooth present"
  else
    fail "no classic Bluetooth feature reported"
  fi

  step "Bluetooth stack reachable" \
       "The bluetooth_manager binder service must exist and the adapter should be ON before HID can register."
  if sur "service list" | grep -q bluetooth_manager; then
    pass "bluetooth_manager service registered"
  else
    fail "bluetooth_manager service missing"
  fi
  if adapter_on; then pass "adapter is ON"; else warn "adapter is OFF - 'bash ${BTKBD_SELF} start' will turn it on"; fi

  step "BluetoothHidDevice class in this ROM's framework" \
       "Confirms the API class itself is present. Loads it for real if the helper is built; otherwise looks for the Bluetooth framework jar that contains it."
  if sur "test -f $JAR"; then
    local p; p=$(cmd_probe 2>/dev/null)
    if printf '%s' "$p" | grep -q 'BluetoothHidDevice=yes'; then
      pass "android.bluetooth.BluetoothHidDevice loads at runtime"
      printf '%s\n' "$p" | sed 's/^/     /'
    else
      warn "runtime probe inconclusive:"
      printf '%s\n' "$p" | sed 's/^/     /'
    fi
  else
    warn "helper not built yet (run 'bash ${BTKBD_SELF} build'); falling back to a static check"
    # on Android 13+ the Bluetooth framework classes live in the btservices APEX
    if sur "ls /apex/com.android.btservices/javalib/framework-bluetooth.jar" | grep -q framework-bluetooth; then
      pass "framework-bluetooth.jar present (contains BluetoothHidDevice)"
    elif sur "ls /system/framework/framework.jar" | grep -q framework; then
      warn "no btservices APEX; pre-13 layout - build the helper and re-run to confirm"
    else
      warn "could not confirm statically - build the helper and re-run"
    fi
  fi

  step "HidDeviceService shipped by this ROM" \
       "AOSP implements the profile as HidDeviceService inside the Bluetooth app. Some OEM ROMs strip it; then no runtime trick helps. Evidence below so you can check the conclusion yourself."
  local pkg apk hits verdict
  pkg=$(bt_pkg) || pkg=
  apk=$(bt_apk) || apk=
  info "bluetooth app:  ${pkg:-not resolvable via pm path}"
  info "apk:            ${apk:-unknown}"
  if [ -n "$apk" ]; then
    hits=$(apk_hid_hits "$apk")
    info "HidDeviceService occurrences in that apk: $hits"
  fi
  verdict=$(hid_support_verdict)
  case $verdict in
    running) pass "profile is live in the Bluetooth stack (definitive)" ;;
    present) pass "the ROM ships the profile - it just needs enabling" ;;
    absent)  fail "the Bluetooth app was read and does not contain HidDeviceService - this ROM omits the HID Device profile" ;;
    unknown) warn "could not determine it either way - not treating that as a failure"
             info "run this yourself: su -c 'pm path com.android.bluetooth' then grep -ac HidDeviceService <apk>" ;;
  esac

  step "HID Device profile enabled" \
       "Android 13+ gates the profile on the sysprop $BTKBD_HID_PROP (BluetoothProperties.isProfileHidDeviceEnabled())."
  local prop; prop=$(getprop $BTKBD_HID_PROP)
  case $prop in
    true)  pass "$BTKBD_HID_PROP=true" ;;
    false) fail "$BTKBD_HID_PROP=false - run 'bash ${BTKBD_SELF} enable'" ;;
    "")    fail "$BTKBD_HID_PROP is unset, which means OFF (isProfileHidDeviceEnabled().orElse(false)) - run 'bash ${BTKBD_SELF} enable'" ;;
    *)     warn "$BTKBD_HID_PROP='$prop' (unexpected value)" ;;
  esac

  step "Profile actually running" \
       "The definitive test: HidDeviceService instantiated inside the Bluetooth process, so registerApp() can be accepted."
  if hid_service_running; then
    pass "HidDeviceService is live in the Bluetooth stack"
  else
    fail "HidDeviceService is not running - run 'bash ${BTKBD_SELF} enable' (needs the adapter ON)"
  fi

  step "com.android.shell holds BLUETOOTH_CONNECT" \
       "The helper runs as uid 2000, which Android resolves to com.android.shell. registerApp() skips its foreground check for uid < 10000 but still enforces BLUETOOTH_CONNECT through appops."
  local perms; perms=$(sur "dumpsys package com.android.shell" | grep -i 'BLUETOOTH_CONNECT' | head -2)
  case $perms in
    *granted=true*)      pass "granted" ;;
    *BLUETOOTH_CONNECT*) warn "declared but not granted - 'bash ${BTKBD_SELF} start' will grant it"
                         printf '%s\n' "$perms" | sed 's/^ */     /' ;;
    *)                   warn "could not read com.android.shell permission state" ;;
  esac

  hdr "Result"
  if [ "$FAILS" -eq 0 ]; then
    printf '%sPASS%s - this device can act as a Bluetooth HID keyboard (%s warning(s))\n' "$C_G" "$C_0" "$WARNS"
    return 0
  fi
  printf '%sFAIL%s - %s blocking problem(s), %s warning(s)\n' "$C_R" "$C_0" "$FAILS" "$WARNS"
  info "Next step: 'bash ${BTKBD_SELF} enable' fixes the common case (profile present but disabled)."
  return 1
}

cmd_probe() {
  [ -f "$JAR" ] || sur "test -f $JAR" || { err "helper not built - run: bash ${BTKBD_SELF} build"; return 1; }
  local out
  out=$(sush "CLASSPATH=$JAR app_process /system/bin dev.btkbd.Server --probe" 2>&1)
  [ -n "$out" ] || out=$(sur "CLASSPATH=$JAR app_process /system/bin dev.btkbd.Server --probe" 2>&1)
  printf '%s\n' "$out"
}

# ===========================================================================
# 5. enable a present-but-disabled profile  (requirement 2)
# ===========================================================================
root_manager() {
  if sur "command -v magisk" | grep -q .; then echo magisk
  elif sur "command -v ksud" | grep -q .; then echo kernelsu
  elif sur "command -v apd" | grep -q .; then echo apatch
  else echo plain; fi
}

bt_off() { sur "cmd bluetooth_manager disable" >/dev/null 2>&1 || sur "svc bluetooth disable" >/dev/null 2>&1; }
bt_on()  { sur "cmd bluetooth_manager enable"  >/dev/null 2>&1 || sur "svc bluetooth enable"  >/dev/null 2>&1; }

# A plain adapter off/on is NOT enough: the Bluetooth app builds its profile list
# in a `static final` array, so the value is latched for the life of the process.
bt_restart() {
  info "turning the adapter off..."
  bt_off; sleep 3
  info "killing the Bluetooth process (needed: the profile list is latched at class-load)..."
  sur "pkill -f com.android.bluetooth" >/dev/null 2>&1
  sur "pkill -f com.google.android.bluetooth" >/dev/null 2>&1
  sleep 3
  info "turning the adapter back on..."
  bt_on
  local i
  for i in $(seq 1 25); do adapter_on && break; sleep 1; done
  sleep 3
}

cmd_enable() {
  local persist=
  [ "${1:-}" = "--persist" ] && persist=1
  hdr "Enabling the Bluetooth HID Device profile"
  have_root || { die "root required"; return 1; }

  local verdict; verdict=$(hid_support_verdict)
  case $verdict in
    absent)
      local apk; apk=$(bt_apk)
      fail "the HID Device profile is not in this ROM's Bluetooth app."
      info "evidence: read $apk and found no HidDeviceService."
      info "Nothing at runtime can add it - the profile code simply is not there."
      info "Only replacing the Bluetooth APEX / flashing a ROM that ships it would help; not recommended,"
      info "and not attempted by this script. Double-check with: grep -ac HidDeviceService '$apk'"
      return 1
      ;;
    unknown)
      warn "could not confirm whether this ROM ships the profile - trying anyway (nothing here is destructive)"
      ;;
  esac

  if hid_service_running && [ "$(getprop $BTKBD_HID_PROP)" != false ]; then
    pass "profile already running - nothing to do"
    [ -n "$persist" ] && persist_prop
    return 0
  fi

  local mgr; mgr=$(root_manager)
  info "root manager detected: $mgr"
  info "background: HidDeviceService.isEnabled() returns"
  info "BluetoothProperties.isProfileHidDeviceEnabled().orElse(false) - so an unset property means OFF."

  step "Method 1: resetprop (the one that actually works)" \
       "In SELinux policy $BTKBD_HID_PROP is labelled bluetooth_config_prop, writable only by vendor_init. resetprop -n bypasses property_service entirely."
  case $mgr in
    magisk) sur "magisk resetprop -n $BTKBD_HID_PROP true" >/dev/null 2>&1 ;;
    *)      sur "resetprop -n $BTKBD_HID_PROP true" >/dev/null 2>&1 ;;
  esac
  if [ "$(getprop $BTKBD_HID_PROP)" = true ]; then
    pass "property forced to true"
  else
    warn "resetprop unavailable or refused"
    step "Method 2: plain setprop" \
         "Expected to fail on a stock policy, but harmless to try - some ROMs relabel the property."
    sur "setprop $BTKBD_HID_PROP true" >/dev/null 2>&1
    if [ "$(getprop $BTKBD_HID_PROP)" = true ]; then
      pass "sysprop set to true"
    else
      fail "could not set $BTKBD_HID_PROP at runtime"
      info "Install Magisk (or a root manager with resetprop), or set the property at boot:"
      info "  'bash ${BTKBD_SELF} enable --persist' writes a module system.prop, then reboot."
      persist=1
    fi
  fi

  step "Method 3: restart the Bluetooth process" \
       "The profile list lives in a static final array, built once when the Bluetooth app's Config class loads. Cycling only the adapter would keep the old list."
  bt_restart
  if hid_service_running; then
    pass "HidDeviceService is now running"
  else
    fail "HidDeviceService did not come up"
    info "Most reliable fix: make the property permanent so it is set before Bluetooth ever starts:"
    info "  bash ${BTKBD_SELF} enable --persist   &&   reboot"
    info "If it still does not appear after a reboot with the property set to true, this ROM's"
    info "native stack was built without HID Device support and no runtime method can add it."
    persist=1
  fi

  [ -n "$persist" ] && persist_prop
  [ "$FAILS" -eq 0 ]
}

persist_prop() {
  step "Persisting across reboots" \
       "A module system.prop is applied at post-fs-data, i.e. BEFORE the Bluetooth app ever starts - the most reliable way to get the profile enabled, and /system stays untouched."
  local mod=/data/adb/modules/btkbd-hid
  if sur "test -d /data/adb/modules"; then
    sur "mkdir -p $mod && printf '%s\n' \
'id=btkbd-hid' \
'name=btkbd HID Device profile' \
'version=1' \
'versionCode=1' \
'author=btkbd' \
'description=Enables the Bluetooth HID Device profile ($BTKBD_HID_PROP)' > $mod/module.prop" >/dev/null
    sur "printf '%s\n' '$BTKBD_HID_PROP=true' > $mod/system.prop" >/dev/null
    pass "module written to $mod (system.prop) - survives reboot"
  elif sur "test -d /data/adb"; then
    sur "mkdir -p /data/adb/post-fs-data.d && printf '%s\n' '#!/system/bin/sh' 'resetprop -n $BTKBD_HID_PROP true' > /data/adb/post-fs-data.d/btkbd-hid.sh && chmod 755 /data/adb/post-fs-data.d/btkbd-hid.sh" >/dev/null
    pass "post-fs-data script written - survives reboot"
  else
    warn "no /data/adb - cannot persist; re-run 'bash ${BTKBD_SELF} enable' after each reboot"
  fi
}

# ===========================================================================
# 6. build the helper  (embedded Java -> classes -> dex -> jar)
# ===========================================================================
need_tool() { command -v "$1" >/dev/null 2>&1; }

cmd_build() {
  hdr "Building the HID helper"
  have_root || { die "root required (the dex has to live in $BTKBD_RUN)"; return 1; }

  local javac=javac dexer=
  need_tool javac || { need_tool ecj && javac=ecj; }
  need_tool "$javac" || { die "no Java compiler. In Termux: pkg install openjdk-17"; return 1; }
  if need_tool d8; then dexer=d8; elif need_tool dx; then dexer=dx; else
    die "no dexer. In Termux: pkg install d8"; return 1
  fi
  need_tool jar || { die "no 'jar' tool. In Termux: pkg install openjdk-17"; return 1; }

  info "compiler=$javac dexer=$dexer"
  rm -rf "$SRC" "$STUBS" "$BTKBD_HOME/classes" "$BTKBD_HOME/dex"
  mkdir -p "$SRC/dev/btkbd" "$STUBS" "$BTKBD_HOME/classes" "$BTKBD_HOME/dex"
  emit_sources

  step "Compile" "Compiled against small hand-written android.* stubs, so no android.jar download is needed. The real framework classes win at runtime (parent-first class loading)."
  if [ "$javac" = ecj ]; then
    ecj -nowarn -source 1.8 -target 1.8 -d "$BTKBD_HOME/classes" \
        $(find "$SRC" "$STUBS" -name '*.java') || { die "compile failed"; return 1; }
  else
    javac -nowarn -source 8 -target 8 -implicit:none -d "$BTKBD_HOME/classes" \
        $(find "$SRC" "$STUBS" -name '*.java') 2>&1 | grep -v 'bootstrap class path\|source value 8\|target value 8\|deprecat'
    [ -f "$BTKBD_HOME/classes/dev/btkbd/Server.class" ] || { die "compile failed"; return 1; }
  fi
  pass "classes built"

  step "Dex" "Only dev/btkbd classes go into the dex; the stubs are passed as classpath so they never shadow the real framework."
  local dexed=
  if [ "$dexer" = d8 ]; then
    d8 --min-api 28 --no-desugaring --classpath "$BTKBD_HOME/classes" \
       --output "$BTKBD_HOME/dex" $(find "$BTKBD_HOME/classes/dev" -name '*.class') 2>&1 | tail -5
    [ -f "$BTKBD_HOME/dex/classes.dex" ] && dexed=1
    if [ -z "$dexed" ]; then
      warn "d8 with --no-desugaring failed; retrying with defaults"
      d8 --min-api 28 --classpath "$BTKBD_HOME/classes" \
         --output "$BTKBD_HOME/dex" $(find "$BTKBD_HOME/classes/dev" -name '*.class') 2>&1 | tail -5
      [ -f "$BTKBD_HOME/dex/classes.dex" ] && dexed=1
    fi
  fi
  if [ -z "$dexed" ] && need_tool dx; then
    warn "falling back to dx (stubs end up in the dex; harmless, the boot classpath still wins)"
    dx --dex --min-sdk-version=28 --output="$BTKBD_HOME/dex/classes.dex" "$BTKBD_HOME/classes" 2>&1 | tail -5
    [ -f "$BTKBD_HOME/dex/classes.dex" ] && dexed=1
  fi
  [ -n "$dexed" ] || { die "dexing failed - see the output above"; return 1; }
  pass "$(ls -l "$BTKBD_HOME/dex/classes.dex" | awk '{print $5" bytes"}')"

  step "Package + install" "app_process loads a jar containing classes.dex from CLASSPATH."
  ( cd "$BTKBD_HOME/dex" && jar cf "$BTKBD_HOME/btkbd.jar" classes.dex ) || { die "jar failed"; return 1; }
  sur "mkdir -p $BTKBD_RUN && chown 2000:2000 $BTKBD_RUN && chmod 755 $BTKBD_RUN" >/dev/null
  # 444, not 644: app_process/ART refuses to load a dex writable by the loading uid (Android 14+)
  sur "cp '$BTKBD_HOME/btkbd.jar' $JAR && chown 2000:2000 $JAR && chmod 444 $JAR" >/dev/null
  sur "test -f $JAR" || { die "could not install $JAR"; return 1; }
  pass "installed $JAR"

  cmd_probe | sed 's/^/   /'
}

# ===========================================================================
# 7. start / stop the helper  (requirement 3)
# ===========================================================================
server_running() {
  state_load
  [ -n "${PORT:-}" ] || return 1
  port_open "$PORT"
}

cmd_start() {
  hdr "Starting the HID helper"
  have_root || { die "root required"; return 1; }
  sur "test -f $JAR" || { cmd_build || return 1; }

  if server_running; then pass "already running on port $PORT"; return 0; fi

  adapter_on || { info "turning Bluetooth on..."; bt_on; sleep 4; }
  hid_service_running || warn "HidDeviceService not visible - registration will probably fail (run 'bash ${BTKBD_SELF} enable')"

  # our uid (2000) resolves to com.android.shell; registerApp() enforces BLUETOOTH_CONNECT on it
  local p
  for p in BLUETOOTH_CONNECT BLUETOOTH_SCAN BLUETOOTH_ADVERTISE; do
    sur "pm grant com.android.shell android.permission.$p" >/dev/null 2>&1
    sur "appops set com.android.shell $p allow" >/dev/null 2>&1
  done

  PORT=$BTKBD_PORT
  while port_open "$PORT"; do PORT=$((PORT+1)); done
  TOKEN=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  state_save

  # The phantom-process reaper is stock AOSP behaviour since Android 12 (it kills
  # apps' detached child processes), so this applies to plain AOSP builds too.
  # Both knobs are best-effort and harmless if unsupported.
  sur "settings put global settings_enable_monitor_phantom_procs false" >/dev/null 2>&1
  sur "device_config put activity_manager max_phantom_processes 2147483647" >/dev/null 2>&1
  info "phantom-process monitor: $(sur "settings get global settings_enable_monitor_phantom_procs" | tr -d '\r')"

  # No exec: the wrapper stays alive to record why app_process exited, which is the
  # one thing a detached launch otherwise never tells us.
  local run=$BTKBD_HOME/run.sh
  cat > "$run" <<RUNEOF
#!/system/bin/sh
echo "RUNSH start pid=\$\$ uid=\$(id -u)"
echo \$\$ > $PIDFILE
export CLASSPATH=$JAR
app_process /system/bin dev.btkbd.Server \\
     --port $PORT --token $TOKEN --name "$BTKBD_DEVICE_NAME" --delay $BTKBD_DELAY_MS
echo "RUNSH app_process exited rc=\$?"
RUNEOF
  sur "cp '$run' $BTKBD_RUN/run.sh && chmod 755 $BTKBD_RUN/run.sh && chown 2000:2000 $BTKBD_RUN/run.sh" >/dev/null
  sur "rm -f $SRVLOG $PIDFILE; touch $SRVLOG; chown 2000:2000 $SRVLOG; chmod 666 $SRVLOG" >/dev/null
  # ART refuses to load a dex that is writable by the loading uid (Android 14+)
  sur "chmod 444 $JAR" >/dev/null

  if ! bash_net_ok && ! need_tool nc; then
    warn "this bash has no /dev/tcp support and 'nc' is missing - the control channel"
    warn "will be unreachable even if the helper starts. Fix: pkg install netcat-openbsd"
  fi

  info "launching as uid 2000 (shell) - Android resolves that uid to com.android.shell, which holds BLUETOOTH_CONNECT"
  local launcher=sush
  have_shell_su || { launcher=sur; warn "running as root instead of shell"; }

  local launchlog=$BTKBD_HOME/launch.log
  # Pick the detach tool up front. Chaining with || would re-launch a second
  # instance whenever app_process itself exits non-zero.
  local detach=
  if sur "command -v setsid" | grep -q setsid; then detach="setsid "
  elif sur "command -v nohup" | grep -q nohup; then detach="nohup "
  else warn "neither setsid nor nohup found"; fi
  info "detach via: ${detach:-none}"

  local -a SU_PREFIX
  if [ "$launcher" = sush ]; then SU_PREFIX=("$BTKBD_SU" 2000 -c); else SU_PREFIX=("$BTKBD_SU" -c); fi

  # Two strategies, because "su backgrounds the helper and exits" leaves the helper
  # orphaned - and some su builds tear down the whole process group on exit.
  local i ok= strategy
  for strategy in detach-inside-su su-stays-alive; do
    info "launch strategy: $strategy"
    : > "$launchlog"
    case $strategy in
      detach-inside-su)
        # su returns immediately; the helper must survive on its own
        local cmd="${detach}sh $BTKBD_RUN/run.sh >>$SRVLOG 2>&1 </dev/null & echo launched-ok"
        if need_tool timeout; then
          timeout 25 "${SU_PREFIX[@]}" "$cmd" >"$launchlog" 2>&1
        else
          "${SU_PREFIX[@]}" "$cmd" >"$launchlog" 2>&1
        fi
        grep -q launched-ok "$launchlog" 2>/dev/null || warn "su did not confirm the launch"
        ;;
      su-stays-alive)
        # keep the su client itself alive as a detached Termux-side job, so the
        # helper always has a living parent and is never orphaned
        ( "${SU_PREFIX[@]}" "sh $BTKBD_RUN/run.sh" >>"$SRVLOG" 2>&1 </dev/null & ) 2>>"$launchlog"
        disown 2>/dev/null
        ;;
    esac

    for i in $(seq 1 24); do
      if port_open "$PORT"; then ok=port; break; fi
      # spawning su is slow, so only consult the log occasionally
      if [ $((i % 6)) = 0 ] && sur "grep -q 'LISTEN port=' $SRVLOG"; then ok=log; break; fi
      sleep 0.5
    done
    [ -n "$ok" ] && break
    warn "strategy '$strategy' did not bring the helper up"
    sur "tail -3 $SRVLOG" 2>/dev/null | sed 's/^/     /'
  done

  if [ -z "$ok" ]; then
    fail "helper did not start"
    info "--- launch output (su / sh) ---"
    if [ -s "$launchlog" ]; then sed 's/^/     /' "$launchlog" | head -20
    else info "     (empty: su produced no output at all)"; fi
    info "--- helper log ($SRVLOG) ---"
    local lg; lg=$(sur "cat $SRVLOG" 2>/dev/null)
    if [ -n "$lg" ]; then printf '%s\n' "$lg" | head -30 | sed 's/^/     /'
    else info "     (empty: app_process produced no output, so it never actually ran)"; fi
    info "--- process ---"
    info "     pid file: $(helper_pid || echo none)"
    info "     ps:       $(sur "ps -A -o pid,user,name" | grep -i btkbd || echo 'no btkbd process')"
    info "--- was it killed? (phantom-process reaper / lmkd / ActivityManager) ---"
    sur "logcat -d -b all -t 400" 2>/dev/null |
      grep -iE 'phantom|lmkd|btkbd|app_process|dev\.btkbd' | tail -12 | sed 's/^/     /'
    info "--- crash buffer (ART aborts land here, not on stderr) ---"
    sur "logcat -d -b crash -t 40" 2>/dev/null | tail -12 | sed 's/^/     /'
    info "--- dex file ---"
    info "     $(sur "ls -l $JAR" 2>/dev/null || echo "$JAR missing")"
    info "--- run this by hand; the real error prints straight to your terminal ---"
    info "     $BTKBD_SU 2000 -c 'CLASSPATH=$JAR app_process /system/bin dev.btkbd.Server --port $PORT --token $TOKEN'"
    info "and check app_process works at all:  bash ${BTKBD_SELF} probe"
    return 1
  fi

  if [ "$ok" = log ]; then
    warn "the helper IS running (its log says LISTEN) but Termux cannot reach 127.0.0.1:$PORT"
    warn "that is a local socket problem, not a Bluetooth one: pkg install netcat-openbsd"
    return 1
  fi
  pass "listening on 127.0.0.1:$PORT"

  for i in $(seq 1 20); do
    case $(ctl '?' 2>/dev/null) in *registered=1*) break ;; esac
    sleep 0.5
  done
  local st; st=$(ctl '?')
  case $st in
    *registered=1*) pass "HID keyboard registered with the Bluetooth stack" ;;
    *) fail "registerApp did not complete"
       info "helper log:"; sur "tail -30 $SRVLOG" | sed 's/^/     /'
       info "if you see a SecurityException about BLUETOOTH_CONNECT, see README -> 'APK fallback'"
       return 1 ;;
  esac
  info "$st"
}

# Run the helper in the foreground so every message - ART aborts, dex rejections,
# SecurityExceptions - lands on the terminal instead of in a log nobody can find.
cmd_trace() {
  hdr "Running the helper in the FOREGROUND (Ctrl-C to stop)"
  have_root || { die "root required"; return 1; }
  sur "test -f $JAR" || { cmd_build || return 1; }

  # Two helpers cannot share the control port; without this the foreground run
  # dies on EADDRINUSE and looks like a new failure.
  if server_running || helper_alive; then
    warn "a helper is already running (pid $(helper_pid)) - stopping it so this one can bind"
    cmd_stop >/dev/null 2>&1
    sleep 1
  fi

  info "layer 1: su as root         -> $(sur id -u 2>&1 | head -1)"
  info "layer 2: su as uid 2000     -> $(sush id -u 2>&1 | head -1)"
  info "layer 3: files in $BTKBD_RUN"
  sur "ls -l $BTKBD_RUN" 2>&1 | sed 's/^/     /'
  info "layer 4: app_process + dex  -> running --probe"
  cmd_probe 2>&1 | sed 's/^/     /'

  state_load
  PORT=${PORT:-$BTKBD_PORT}
  TOKEN=${TOKEN:-trace}
  state_save
  adapter_on || { info "turning Bluetooth on..."; bt_on; sleep 4; }

  local launcher=sush
  have_shell_su || { launcher=sur; warn "falling back to root (su 2000 unsupported)"; }
  hdr "helper output (everything below comes straight from the helper)"
  $launcher "CLASSPATH=$JAR app_process /system/bin dev.btkbd.Server --port $PORT --token $TOKEN --name '$BTKBD_DEVICE_NAME' --delay $BTKBD_DELAY_MS" 2>&1
  local rc=$?
  hdr "helper exited (rc=$rc)"
  info "if you saw nothing at all above, app_process never started - check the crash buffer:"
  info "  su -c 'logcat -d -b crash -t 60'"
}

cmd_stop() {
  hdr "Stopping the HID helper"
  state_load
  [ -n "${TOKEN:-}" ] && ctl Q >/dev/null 2>&1
  link_down
  sur "kill \$(cat $PIDFILE 2>/dev/null) 2>/dev/null; pkill -f dev.btkbd.Server" >/dev/null 2>&1
  sleep 1
  if server_running; then fail "still running"; else pass "stopped"; fi
}

# ===========================================================================
# 8. pair / connect  (requirement 4)
# ===========================================================================
cmd_bond()   { server_running || { cmd_start || return 1; }; ctl "BOND ${1:-}"; }
cmd_unbond() { server_running || { cmd_start || return 1; }; ctl "UNBOND ${1:-}"; }

cmd_pair() {
  hdr "Pairing with the Windows PC"
  server_running || { cmd_start || return 1; }

  # Without a registered HID app the phone advertises no keyboard service, and
  # Windows fails with "Couldn't connect".
  case $(ctl '?') in
    *registered=1*) pass "HID keyboard is registered - Windows will find a keyboard service" ;;
    *) fail "the helper is not registered as a keyboard yet"
       info "pair only after 'start' (or 'trace') has reported READY"
       return 1 ;;
  esac

  local bonded; bonded=$(ctl BONDED); bonded=${bonded#OK }; bonded=${bonded# }
  if [ -n "$bonded" ]; then
    warn "the phone already holds bond(s): $bonded"
    warn "If Windows shows the phone under \"Add a device\" and then says"
    warn "\"Couldn't connect\", the two sides disagree about the link key: the phone"
    warn "kept it, Windows did not. Clear BOTH sides, then pair again:"
    warn "  1) Windows: Settings > Bluetooth & devices > (phone) > Remove device"
    warn "  2) phone:   bash ${BTKBD_SELF} unbond <MAC>"
    warn "  3) phone:   bash ${BTKBD_SELF} pair"
  fi
  info "Alternative that often works when Windows-initiated pairing fails:"
  info "  open Windows' 'Add a device' dialog (that makes the PC pairable), then run"
  info "  bash ${BTKBD_SELF} bond <WINDOWS-MAC>     # phone initiates the bond"

  cat <<'EOT'
   How Bluetooth HID pairing works here:
     1. the phone has registered an HID SDP record (device class = keyboard, subclass 0x40)
        plus the report descriptor, so any host that queries it sees a keyboard
     2. the phone must be connectable/discoverable
     3. WINDOWS initiates the bond: Settings > Bluetooth & devices > Add device >
        "Everything else" > pick your phone
     4. confirm the pairing prompt on the phone if one appears
     5. Windows reads the SDP record, loads its own built-in HID keyboard driver
        (nothing to install) and the input channel opens
   Pairing is a one-time step - after this, "bash btkbd.sh connect" reuses the bond.
EOT

  local r; r=$(ctl 'DISCOVERABLE 300')
  case $r in
    OK*) pass "adapter is now connectable + discoverable for 300s" ;;
    *)   warn "could not set scan mode from the helper ($r)"
         info "opening Android's Bluetooth settings instead - keeping that screen open makes the phone discoverable"
         sur "am start -a android.settings.BLUETOOTH_SETTINGS" >/dev/null 2>&1 ;;
  esac

  info "waiting for Windows to bond (Ctrl-C to abort)..."
  local i before after
  before=$(ctl BONDED | tr -d '\n')
  for i in $(seq 1 120); do
    after=$(ctl BONDED | tr -d '\n')
    [ "$after" != "$before" ] && { pass "new bond: $after"; break; }
    sleep 2
  done
  cmd_connect
}

# prints one MAC on stdout; all prompts go to stderr so the caller can capture it
pick_bonded() {
  local list count i e
  list=$(ctl BONDED)
  list=${list#OK }
  list=${list# }
  if [ -z "$list" ] || [ "$list" = OK ]; then
    err "no bonded devices - run: bash ${BTKBD_SELF} pair"
    return 1
  fi
  count=$(printf '%s' "$list" | tr ',' '\n' | grep -c .)
  if [ "$count" -eq 1 ]; then
    printf '%s' "${list%%|*}"
    return 0
  fi
  say "bonded devices:" >&2
  i=1
  while IFS= read -r e; do
    printf '  %d) %s\n' "$i" "$e" >&2
    i=$((i+1))
  done <<<"$(printf '%s' "$list" | tr ',' '\n')"
  printf 'pick a number: ' >&2
  read -r i
  e=$(printf '%s' "$list" | cut -d, -f"$i")
  [ -z "$e" ] && { err "invalid selection"; return 1; }
  printf '%s' "${e%%|*}"
}

cmd_connect() {
  hdr "Connecting as a keyboard"
  server_running || { cmd_start || return 1; }
  state_load
  local mac=${1:-${MAC:-}}
  if [ -z "$mac" ]; then mac=$(pick_bonded) || return 1; fi
  [ -z "$mac" ] && { err "no device to connect to"; return 1; }

  info "asking the stack to open the HID channel to $mac"
  ctl "C $mac" >/dev/null || { err "connect call failed: $BTKBD_REPLY"; return 1; }
  MAC=$mac; state_save

  local i st
  for i in $(seq 1 30); do
    st=$(ctl '?')
    case $st in *state=CONNECTED*) pass "connected: $st"; return 0 ;; esac
    sleep 1
  done
  fail "not connected after 30s: $st"
  info "Windows must have the phone paired and not blocked. Try: remove the device on Windows, then 'bash ${BTKBD_SELF} pair'."
  return 1
}

cmd_disconnect() { ctl D >/dev/null && pass disconnected; }

cmd_status() {
  state_load
  if ! server_running; then
    if helper_alive; then
      say "helper: ${C_Y}running (pid $(helper_pid)) but control port ${PORT:-?} unreachable${C_0}"
      say "  bash /dev/tcp: $(bash_net_ok && echo yes || echo no)   nc installed: $(need_tool nc && echo yes || echo no)"
      say "  fix: pkg install netcat-openbsd"
      say "  helper log: su -c 'tail -20 $SRVLOG'"
    else
      say "helper: ${C_R}not running${C_0}"
    fi
    return 1
  fi
  say "helper: ${C_G}running${C_0} (port $PORT, pid $(sur "cat $PIDFILE" 2>/dev/null))"
  say "$(ctl '?')"
  say "bonded: $(ctl BONDED)"
}

# ===========================================================================
# 9. diagnostics  (requirement 8)
# ===========================================================================
cmd_doctor() {
  hdr "btkbd diagnostics"
  cmd_check || true

  hdr "Helper process"
  if server_running; then
    pass "control port $PORT open"
    info "$(ctl '?')"
    info "bonded: $(ctl BONDED)"
  else
    fail "helper not reachable (state: $([ -f "$STATE" ] && echo "$STATE exists" || echo "no state file"))"
  fi
  info "pid file: $(sur "cat $PIDFILE" 2>/dev/null || echo none)"
  info "process:  $(sur "ps -A -o pid,user,name" | grep -i btkbd || echo 'no btkbd process')"

  hdr "Helper log (tail)"
  sur "tail -40 $SRVLOG" 2>/dev/null | sed 's/^/  /' || info "no log"

  hdr "HID Device profile support (evidence)"
  local apk; apk=$(bt_apk)
  info "bluetooth app: $(bt_pkg || echo 'not resolvable')"
  info "apk:           ${apk:-unknown}"
  [ -n "$apk" ] && info "HidDeviceService occurrences in apk: $(apk_hid_hits "$apk")"
  info "verdict:       $(hid_support_verdict)"
  info "$BTKBD_HID_PROP=$(getprop $BTKBD_HID_PROP)"
  sur "test -f $JAR" && cmd_probe | sed 's/^/  /'
  info "note: 'dumpsys bluetooth' does not exist on Android 13+ (the stack moved into the"
  info "      com.android.btservices APEX and IBluetooth is not in servicemanager)."
  info "      'Can't find service: bluetooth' is expected - use dumpsys bluetooth_manager."

  hdr "Bluetooth stack view of HID"
  sur "dumpsys bluetooth_manager" | grep -i -A3 'hid' | head -40 | sed 's/^/  /'

  hdr "Bonded devices (stack)"
  sur "dumpsys bluetooth_manager" | grep -i -A2 'bonded\|BondState' | head -20 | sed 's/^/  /'

  hdr "Recent Bluetooth log lines"
  sur "logcat -d -t 200 -b all -s BluetoothHidDevice HidDeviceService BluetoothAdapter BluetoothManagerService bt_stack btadapterservice" 2>/dev/null | tail -40 | sed 's/^/  /'

  hdr "Deeper debugging (copy/paste)"
  cat <<EOT
  live log:        su -c 'logcat -b all | grep -iE "hid|btkbd"'
  helper log:      su -c 'tail -f $SRVLOG'
  profile state:   su -c 'dumpsys bluetooth_manager | grep -i hid'
  is it enabled:   getprop $BTKBD_HID_PROP
  service present: su -c 'dumpsys package com.android.bluetooth | grep -i HidDeviceService'
  HCI snoop log:   su -c 'setprop persist.bluetooth.btsnoopenable true' ; then restart Bluetooth;
                   capture lands in /data/misc/bluetooth/logs/btsnoop_hci.log (open in Wireshark)
  raw report test: bash ${BTKBD_SELF} raw 0200040000000000   # shift+a down, then:
                   bash ${BTKBD_SELF} raw 0000000000000000   # all keys up
EOT
}

cmd_keys() {
  keymap_init
  hdr "Named keys accepted by send_key"
  printf '%s\n' "${!KEY[@]}" | sort | tr '\n' ' ' | fold -s -w 78 | sed 's/^/  /'
  echo
  info "modifiers: CTRL SHIFT ALT WIN (also RCTRL RSHIFT RALT RWIN, aliases GUI/META/SUPER/CMD)"
  info "examples:  send_key ENTER | send_key CTRL+C | send_key ALT+TAB | send_key CTRL+SHIFT+ESC | send_key WIN+R"
}

cmd_help() {
  cat <<EOT
btkbd.sh - Bluetooth HID keyboard from a rooted Android phone

  bash btkbd.sh check              explain + verify HID Device support (PASS/FAIL)
  bash btkbd.sh enable [--persist] enable the profile if it is present but disabled
  bash btkbd.sh build              compile the embedded HID helper (once)
  bash btkbd.sh start | stop       run/stop the helper (registers the keyboard)
  bash btkbd.sh trace              run the helper in the FOREGROUND - use this when
                                   'start' fails: it shows every error directly
  bash btkbd.sh pair               guided first-time pairing with the PC
  bash btkbd.sh connect [MAC]      reuse an existing pairing
  bash btkbd.sh disconnect
  bash btkbd.sh bond MAC           phone initiates pairing with the PC
  bash btkbd.sh unbond [MAC]       clear a stale bond/link key on the phone side
  bash btkbd.sh status             registered / bonded / connected
  bash btkbd.sh up                 check -> enable -> build -> start -> connect
  bash btkbd.sh type "text"        type text on the PC
  bash btkbd.sh key CTRL+ALT+DEL   press a key combination
  bash btkbd.sh raw <16 hex>       send one raw 8-byte HID report
  bash btkbd.sh keys               list key names
  bash btkbd.sh doctor             full diagnostics
  bash btkbd.sh probe              runtime capability probe

In your own scripts:
  source btkbd.sh
  btkbd_require_connected
  send_text "Hello world"
  send_key ENTER

Environment: BTKBD_PORT=$BTKBD_PORT BTKBD_DELAY_MS=$BTKBD_DELAY_MS BTKBD_HOME=$BTKBD_HOME
EOT
}

cmd_up() {
  cmd_check || {
    warn "check reported problems - attempting to enable the profile"
    cmd_enable || return 1
    cmd_check || return 1
  }
  sur "test -f $JAR" || cmd_build || return 1
  cmd_start || return 1
  state_load
  if [ -n "${MAC:-}" ]; then cmd_connect "$MAC"; else
    say "no remembered PC - run 'bash ${BTKBD_SELF} pair' for the first-time pairing"
  fi
}

# ===========================================================================
# 10. embedded Java: the HID helper + compile-only android.* stubs
# ===========================================================================
emit_sources() {
  mkdir -p "$SRC/dev/btkbd" "$STUBS/android/bluetooth" "$STUBS/android/content" "$STUBS/android/os"

  cat > "$SRC/dev/btkbd/Server.java" <<'JAVA_SERVER'
  package dev.btkbd;

  import android.bluetooth.BluetoothAdapter;
  import android.bluetooth.BluetoothDevice;
  import android.bluetooth.BluetoothHidDevice;
  import android.bluetooth.BluetoothHidDeviceAppQosSettings;
  import android.bluetooth.BluetoothHidDeviceAppSdpSettings;
  import android.bluetooth.BluetoothManager;
  import android.bluetooth.BluetoothProfile;
  import android.content.AttributionSource;
  import android.content.Context;
  import android.content.ContextWrapper;
  import android.os.IBinder;
  import android.os.Looper;
  import android.os.Process;

  import java.io.BufferedReader;
  import java.io.FileInputStream;
  import java.io.InputStreamReader;
  import java.io.PrintWriter;
  import java.lang.reflect.Constructor;
  import java.lang.reflect.Method;
  import java.lang.reflect.Modifier;
  import java.net.InetAddress;
  import java.net.ServerSocket;
  import java.net.Socket;
  import java.util.ArrayList;
  import java.util.List;
  import java.util.Set;
  import java.util.concurrent.Executor;
  import java.util.concurrent.Executors;

  /**
  * The one piece that cannot be bash: it owns the BluetoothHidDevice registration
  * and relays 8-byte keyboard reports. Driven over 127.0.0.1 by btkbd.sh.
  */
  public final class Server {

      /* Boot-protocol keyboard, Report ID 1: 8-byte input [mods,0,k1..k6] + 1-byte LED output.
      * This is the descriptor Windows recognises with its built-in HID driver. */
      private static final byte[] DESCRIPTOR = {
          (byte) 0x05, (byte) 0x01,              // Usage Page (Generic Desktop)
          (byte) 0x09, (byte) 0x06,              // Usage (Keyboard)
          (byte) 0xA1, (byte) 0x01,              // Collection (Application)
          (byte) 0x85, (byte) 0x01,              //  Report ID (1)
          (byte) 0x05, (byte) 0x07,              //  Usage Page (Keyboard/Keypad)
          (byte) 0x19, (byte) 0xE0,              //  Usage Min (Left Control)
          (byte) 0x29, (byte) 0xE7,              //  Usage Max (Right GUI)
          (byte) 0x15, (byte) 0x00,              //  Logical Min (0)
          (byte) 0x25, (byte) 0x01,              //  Logical Max (1)
          (byte) 0x75, (byte) 0x01,              //  Report Size (1)
          (byte) 0x95, (byte) 0x08,              //  Report Count (8)
          (byte) 0x81, (byte) 0x02,              //  Input (Data,Var,Abs)   -> byte 0 modifiers
          (byte) 0x75, (byte) 0x08,              //  Report Size (8)
          (byte) 0x95, (byte) 0x01,              //  Report Count (1)
          (byte) 0x81, (byte) 0x01,              //  Input (Const)          -> byte 1 reserved
          (byte) 0x05, (byte) 0x08,              //  Usage Page (LEDs)
          (byte) 0x19, (byte) 0x01,              //  Usage Min (Num Lock)
          (byte) 0x29, (byte) 0x05,              //  Usage Max (Kana)
          (byte) 0x75, (byte) 0x01,              //  Report Size (1)
          (byte) 0x95, (byte) 0x05,              //  Report Count (5)
          (byte) 0x91, (byte) 0x02,              //  Output (Data,Var,Abs)  <- host LED state
          (byte) 0x75, (byte) 0x03,              //  Report Size (3)
          (byte) 0x95, (byte) 0x01,              //  Report Count (1)
          (byte) 0x91, (byte) 0x01,              //  Output (Const)         <- padding
          (byte) 0x05, (byte) 0x07,              //  Usage Page (Keyboard/Keypad)
          (byte) 0x19, (byte) 0x00,              //  Usage Min (0)
          (byte) 0x29, (byte) 0x73,              //  Usage Max (0x73 = F24; covers every key we map)
          (byte) 0x15, (byte) 0x00,              //  Logical Min (0)
          (byte) 0x25, (byte) 0x73,              //  Logical Max (0x73) - single byte on purpose:
                                                //  the 2-byte form (26 FF 00) is what Windows
                                                //  hosts have been reported to choke on
          (byte) 0x75, (byte) 0x08,              //  Report Size (8)
          (byte) 0x95, (byte) 0x06,              //  Report Count (6)
          (byte) 0x81, (byte) 0x00,              //  Input (Data,Ary,Abs)   -> bytes 2..7 keys
          (byte) 0xC0                            // End Collection
      };

      private static final int STATE_DISCONNECTED = 0, STATE_CONNECTING = 1,
                              STATE_CONNECTED = 2, STATE_DISCONNECTING = 3;

      /** Must match BTKBD_PROTO in btkbd.sh; bumped whenever commands change. */
      private static final String VERSION = "3";

      private static String name = "Bluetooth Keyboard";
      private static String token = "";
      private static int port = 8722;
      private static volatile int delayMs = 6;

      private static BluetoothAdapter adapter;
      private static Context context;
      private static volatile BluetoothHidDevice hid;
      private static volatile boolean registered;
      private static volatile BluetoothDevice peer;      // last known host
      private static volatile int peerState = STATE_DISCONNECTED;
      private static volatile byte[] lastReport = new byte[8];
      private static volatile boolean autoReconnect = true;
      private static volatile boolean reconnecting;

      public static void main(String[] args) {
          for (int i = 0; i < args.length; i++) {
              if ("--probe".equals(args[i])) { probe(); return; }
              else if ("--port".equals(args[i]) && i + 1 < args.length) port = Integer.parseInt(args[++i]);
              else if ("--token".equals(args[i]) && i + 1 < args.length) token = args[++i];
              else if ("--name".equals(args[i]) && i + 1 < args.length) name = args[++i];
              else if ("--delay".equals(args[i]) && i + 1 < args.length) delayMs = Integer.parseInt(args[++i]);
          }
          try {
              run();
          } catch (java.net.BindException e) {
              // Almost always "a helper is already running" - that deserves a
              // sentence, not a stack trace.
              out("ERR control port " + port + " is already in use.");
              out("HINT another helper is already running. Use it, or stop it first:");
              out("HINT   bash btkbd.sh stop      (or: su -c 'pkill -f dev.btkbd.Server')");
              out("HINT   bash btkbd.sh status    shows if it is registered/connected");
              System.exit(2);
          } catch (Throwable t) {
              out("FATAL " + t);
              t.printStackTrace();
              System.exit(1);
          }
      }

      private static void out(String s) { System.out.println(s); System.out.flush(); }

      private static void probe() {
          out("PROBE uid=" + Process.myUid());
          // Adapter construction builds Handlers, which need a Looper - without this
          // the probe fails for a reason the real run() would never hit.
          if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
          context = buildContext();
          String[] classes = {
              "android.bluetooth.BluetoothHidDevice",
              "android.bluetooth.BluetoothHidDeviceAppSdpSettings",
              "android.bluetooth.BluetoothHidDeviceAppQosSettings",
              "android.bluetooth.BluetoothAdapter"
          };
          for (String c : classes) {
              boolean ok;
              try { Class.forName(c); ok = true; } catch (Throwable t) { ok = false; }
              out("PROBE " + c.substring(c.lastIndexOf('.') + 1) + "=" + (ok ? "yes" : "no"));
          }
          dumpServiceVisibility();
          BluetoothAdapter a = acquireAdapter();
          out("PROBE adapter=" + (a != null ? "yes" : "no") + " enabled=" + (a != null && a.isEnabled()));
          if (a == null) dumpAdapterApi();
          // getSupportedProfiles() is @hide, but it is the list Config/BluetoothProperties
          // actually produced on this build - the most authoritative answer to
          // "does this ROM support HID Device" short of the profile already running.
          try {
              Method m = BluetoothAdapter.class.getMethod("getSupportedProfiles");
              Object r = m.invoke(a);
              boolean hid = false;
              if (r instanceof List) {
                  for (Object o : (List<?>) r) {
                      if (o instanceof Integer && ((Integer) o).intValue() == 19) hid = true;
                  }
              }
              out("PROBE supportedProfiles=" + r);
              out("PROBE hidDeviceSupported=" + (hid ? "yes" : "no"));
          } catch (Throwable t) {
              out("PROBE hidDeviceSupported=error " + t);
          }
      }

      private static void run() throws Exception {
          if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
          context = buildContext();
          out("CONTEXT uid=" + Process.myUid() + " package=" + shellPackage());
          if (Process.myUid() != 2000) {
              out("WARN not running as uid 2000 (shell). Bluetooth validates the AttributionSource"
                  + " against Binder.getCallingUid(), and uid " + Process.myUid()
                  + " has no matching package for the BLUETOOTH_CONNECT appops check.");
              out("HINT start with 'su 2000 -c ...' (btkbd.sh does this when your su supports it).");
          }

          adapter = acquireAdapter();
          if (adapter == null) {
              out("ERR could not obtain a BluetoothAdapter by any route.");
              dumpServiceVisibility();
              dumpAdapterApi();
              out("HINT the binder is visible, so this is not SELinux: BluetoothAdapter simply cannot");
              out("HINT reach the mainline BluetoothServiceManager from a headless process. The API");
              out("HINT shapes printed above show which factory/constructor this build actually has.");
              throw new IllegalStateException("no BluetoothAdapter");
          }
          out("ADAPTER enabled=" + adapter.isEnabled());

          startControlServer();

          BluetoothProfile.ServiceListener listener = new BluetoothProfile.ServiceListener() {
              public void onServiceConnected(int profile, BluetoothProfile proxy) {
                  hid = (BluetoothHidDevice) proxy;
                  out("PROXY connected");
                  registerApp();
              }
              public void onServiceDisconnected(int profile) {
                  hid = null; registered = false;
                  out("PROXY disconnected");
              }
          };
          if (!adapter.getProfileProxy(context, listener, BluetoothProfile.HID_DEVICE)) {
              out("ERR getProfileProxy(HID_DEVICE) returned false - profile probably disabled in this ROM");
          }
          Looper.loop();
      }

      private static String readFile(String path) {
          try {
              FileInputStream in = new FileInputStream(path);
              byte[] b = new byte[256];
              int n = in.read(b);
              in.close();
              return n > 0 ? new String(b, 0, n, "UTF-8").trim().replace("\0", "") : "";
          } catch (Throwable t) {
              return "?";
          }
      }

      private static AttributionSource attributionSource() {
          return new AttributionSource.Builder(Process.myUid()).setPackageName(shellPackage()).build();
      }

      /** android.os.ServiceManager.getService(name), reflectively. */
      private static IBinder smGetService(String name) {
          try {
              Class<?> sm = Class.forName("android.os.ServiceManager");
              Method m = sm.getMethod("getService", String.class);
              return (IBinder) m.invoke(null, name);
          } catch (Throwable t) {
              out("SM getService(" + name + ") threw " + t);
              return null;
          }
      }

      private static void dumpServiceVisibility() {
          out("SELINUX " + readFile("/proc/self/attr/current"));
          out("SM bluetooth_manager binder=" + (smGetService("bluetooth_manager") != null));
          out("SM bluetooth binder=" + (smGetService("bluetooth") != null));
          try {
              Class<?> sm = Class.forName("android.os.ServiceManager");
              String[] all = (String[]) sm.getMethod("listServices").invoke(null);
              StringBuilder sb = new StringBuilder();
              if (all != null) {
                  for (String s : all) if (s != null && s.toLowerCase().contains("bluetooth")) sb.append(s).append(' ');
              }
              out("SM services matching bluetooth: " + (sb.length() > 0 ? sb.toString().trim() : "(none visible)"));
          } catch (Throwable t) {
              out("SM listServices threw " + t);
          }
      }

      /**
       * Bluetooth is a mainline module, so BluetoothAdapter does not use
       * ServiceManager.getService() - it asks BluetoothFrameworkInitializer for a
       * BluetoothServiceManager. ActivityThread installs that during normal app
       * binding, which a headless app_process never performs, leaving the registerer
       * unset and every adapter null. Install it ourselves.
       */
      private static void initFrameworkServiceManager() {
          try {
              Class<?> smClass = Class.forName("android.os.BluetoothServiceManager");
              Constructor<?> ctor = smClass.getDeclaredConstructor();
              ctor.setAccessible(true);
              Object sm = ctor.newInstance();
              Class<?> init = Class.forName("android.bluetooth.BluetoothFrameworkInitializer");
              Method set = init.getDeclaredMethod("setBluetoothServiceManager", smClass);
              set.setAccessible(true);
              set.invoke(null, sm);
              out("INIT BluetoothServiceManager installed");
          } catch (Throwable t) {
              // "called twice" simply means something already set it - not a problem
              out("INIT BluetoothServiceManager: " + t);
          }
      }

      /** Print the real shapes, so a wrong guess above is immediately visible. */
      private static void dumpAdapterApi() {
          try {
              for (Constructor<?> c : BluetoothAdapter.class.getDeclaredConstructors()) {
                  out("API ctor " + c);
              }
              for (Method m : BluetoothAdapter.class.getDeclaredMethods()) {
                  String n = m.getName();
                  if (n.toLowerCase().contains("createadapter") || n.equals("getDefaultAdapter")
                          || n.contains("ServiceManager") || n.contains("getBluetoothManager")) {
                      out("API method " + m);
                  }
              }
          } catch (Throwable t) {
              out("API dump (BluetoothAdapter) failed: " + t);
          }
          try {
              Class<?> init = Class.forName("android.bluetooth.BluetoothFrameworkInitializer");
              for (Method m : init.getDeclaredMethods()) out("API init " + m);
          } catch (Throwable t) {
              out("API dump (BluetoothFrameworkInitializer) failed: " + t);
          }
          try {
              Class<?> smClass = Class.forName("android.os.BluetoothServiceManager");
              for (Constructor<?> c : smClass.getDeclaredConstructors()) out("API bsm ctor " + c);
              for (Method m : smClass.getDeclaredMethods()) out("API bsm method " + m.getName());
          } catch (Throwable t) {
              out("API dump (BluetoothServiceManager) failed: " + t);
          }
      }

      private static BluetoothAdapter acquireAdapter() {
          BluetoothAdapter a = null;
          initFrameworkServiceManager();

          try {
              a = BluetoothAdapter.getDefaultAdapter();
              out("ADAPTER route1 getDefaultAdapter=" + (a != null));
          } catch (Throwable t) {
              out("ADAPTER route1 threw " + t);
          }
          if (a != null) return a;

          if (context != null) {
              try {
                  BluetoothManager bm = (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
                  out("ADAPTER route2 getSystemService=" + (bm != null));
                  if (bm != null) {
                      a = bm.getAdapter();
                      out("ADAPTER route2 getAdapter=" + (a != null));
                  }
              } catch (Throwable t) {
                  out("ADAPTER route2 threw " + t);
              }
              if (a != null) return a;
          }

          // Route 3: construct the adapter ourselves. Signatures differ between
          // builds, so discover them and fill parameters by type instead of guessing.
          IBinder binder = smGetService("bluetooth_manager");
          out("ADAPTER route3 bluetooth_manager binder=" + (binder != null));
          Object mgr = null;
          if (binder != null) {
              try {
                  mgr = Class.forName("android.bluetooth.IBluetoothManager$Stub")
                          .getMethod("asInterface", IBinder.class).invoke(null, binder);
              } catch (Throwable t) {
                  out("ADAPTER route3 asInterface failed: " + t);
              }
          }

          for (Method m : BluetoothAdapter.class.getDeclaredMethods()) {
              if (!m.getName().equals("createAdapter") || !Modifier.isStatic(m.getModifiers())) continue;
              Object[] args = buildArgs(m.getParameterTypes(), mgr);
              if (args == null) { out("ADAPTER route3a skip (unknown params) " + m); continue; }
              try {
                  m.setAccessible(true);
                  a = (BluetoothAdapter) m.invoke(null, args);
                  out("ADAPTER route3a " + m.getName() + argTypes(m.getParameterTypes()) + " -> " + (a != null));
                  if (a != null) return a;
              } catch (Throwable t) {
                  out("ADAPTER route3a " + m.getName() + argTypes(m.getParameterTypes()) + " failed: " + t);
              }
          }

          for (Constructor<?> c : BluetoothAdapter.class.getDeclaredConstructors()) {
              Object[] args = buildArgs(c.getParameterTypes(), mgr);
              if (args == null) { out("ADAPTER route3b skip (unknown params) " + c); continue; }
              try {
                  c.setAccessible(true);
                  a = (BluetoothAdapter) c.newInstance(args);
                  out("ADAPTER route3b ctor" + argTypes(c.getParameterTypes()) + " -> " + (a != null));
                  if (a != null) return a;
              } catch (Throwable t) {
                  out("ADAPTER route3b ctor" + argTypes(c.getParameterTypes()) + " failed: " + t);
              }
          }
          return a;
      }

      /** Fill a parameter list by type; null if any parameter is not one we can supply. */
      private static Object[] buildArgs(Class<?>[] params, Object bluetoothManager) {
          Object[] args = new Object[params.length];
          for (int i = 0; i < params.length; i++) {
              String n = params[i].getName();
              if (n.equals("android.bluetooth.IBluetoothManager")) {
                  if (bluetoothManager == null) return null;
                  args[i] = bluetoothManager;
              } else if (n.equals("android.content.Context")) {
                  if (context == null) return null;
                  args[i] = context;
              } else if (n.equals("android.content.AttributionSource")) {
                  args[i] = attributionSource();
              } else {
                  return null;
              }
          }
          return args;
      }

      private static String argTypes(Class<?>[] params) {
          StringBuilder sb = new StringBuilder("(");
          for (int i = 0; i < params.length; i++) {
              if (i > 0) sb.append(',');
              String n = params[i].getName();
              sb.append(n.substring(n.lastIndexOf('.') + 1));
          }
          return sb.append(')').toString();
      }

      private static String shellPackage() {
          int uid = Process.myUid();
          if (uid == 0) return "root";
          if (uid == 1000) return "android";
          return "com.android.shell";
      }

      /** A context whose attribution says "com.android.shell", which is what the
      *  BLUETOOTH_CONNECT appops check validates against our uid. */
      private static Context buildContext() {
          Context base = null;
          try {
              Class<?> at = Class.forName("android.app.ActivityThread");
              Object thread;
              try {
                  thread = at.getDeclaredMethod("systemMain").invoke(null);
              } catch (Throwable t) {
                  thread = at.getDeclaredMethod("currentActivityThread").invoke(null);
              }
              Method m = at.getDeclaredMethod("getSystemContext");
              m.setAccessible(true);
              base = (Context) m.invoke(thread);
          } catch (Throwable t) {
              out("WARN no system context: " + t);
          }
          return new ShellContext(base);
      }

      static final class ShellContext extends ContextWrapper {
          ShellContext(Context base) { super(base); }
          @Override public String getPackageName() { return shellPackage(); }
          @Override public String getOpPackageName() { return shellPackage(); }
          @Override public AttributionSource getAttributionSource() {
              return new AttributionSource.Builder(Process.myUid())
                      .setPackageName(shellPackage()).build();
          }
      }

      private static void registerApp() {
          try {
              BluetoothHidDeviceAppSdpSettings sdp = new BluetoothHidDeviceAppSdpSettings(
                      name, "Android HID keyboard", "btkbd",
                      BluetoothHidDevice.SUBCLASS1_KEYBOARD, DESCRIPTOR);
              Executor exec = Executors.newSingleThreadExecutor();
              boolean ok = hid.registerApp(sdp, (BluetoothHidDeviceAppQosSettings) null,
                      (BluetoothHidDeviceAppQosSettings) null, exec, new Cb());
              out("REGISTERAPP call=" + ok);
              if (!ok) out("ERR registerApp returned false");
          } catch (SecurityException e) {
              out("ERR SecurityException on registerApp: " + e.getMessage());
              out("HINT this build refuses HID registration from a shell process - see README 'APK fallback'");
          } catch (Throwable t) {
              out("ERR registerApp: " + t);
          }
      }

      static final class Cb extends BluetoothHidDevice.Callback {
          @Override public void onAppStatusChanged(BluetoothDevice pluggedDevice, boolean reg) {
              registered = reg;
              out("EVENT registered=" + (reg ? 1 : 0) + (pluggedDevice != null ? " plugged=" + pluggedDevice.getAddress() : ""));
              if (reg) out("READY");
              if (pluggedDevice != null) peer = pluggedDevice;
          }
          @Override public void onConnectionStateChanged(BluetoothDevice device, int state) {
              peer = device; peerState = state;
              out("EVENT connection=" + stateName(state) + " device=" + (device != null ? device.getAddress() : "?"));
              // Windows does not reliably re-initiate after sleep, so the phone re-dials.
              if (state == STATE_DISCONNECTED) scheduleReconnect(device);
          }
          @Override public void onGetReport(BluetoothDevice device, byte type, byte id, int bufferSize) {
              // Windows asks for the current input report during setup; answer or it may stall.
              try { hid.replyReport(device, type, id, lastReport); } catch (Throwable ignored) { }
          }
          @Override public void onSetReport(BluetoothDevice device, byte type, byte id, byte[] data) {
              out("EVENT led=" + toHex(data));
          }
          @Override public void onSetProtocol(BluetoothDevice device, byte protocol) {
              out("EVENT protocol=" + protocol);
          }
          @Override public void onVirtualCableUnplug(BluetoothDevice device) {
              out("EVENT unplug");
              peerState = STATE_DISCONNECTED;
          }
      }

      private static synchronized void scheduleReconnect(final BluetoothDevice d) {
          if (d == null || !autoReconnect || reconnecting) return;
          reconnecting = true;
          Thread t = new Thread(new Runnable() {
              public void run() {
                  try {
                      for (int i = 1; i <= 12 && autoReconnect; i++) {
                          Thread.sleep(5000);
                          if (peerState == STATE_CONNECTED || peerState == STATE_CONNECTING) return;
                          if (hid == null || !registered) return;
                          out("RECONNECT attempt=" + i + " device=" + d.getAddress());
                          try { hid.connect(d); } catch (Throwable ignored) { }
                      }
                  } catch (InterruptedException ignored) {
                  } finally {
                      reconnecting = false;
                  }
              }
          }, "btkbd-reconnect");
          t.setDaemon(true);
          t.start();
      }

      private static String stateName(int s) {
          switch (s) {
              case STATE_CONNECTED: return "CONNECTED";
              case STATE_CONNECTING: return "CONNECTING";
              case STATE_DISCONNECTING: return "DISCONNECTING";
              default: return "DISCONNECTED";
          }
      }

      /* ---------------- control channel ---------------- */

      private static void startControlServer() throws Exception {
          final ServerSocket ss = new ServerSocket(port, 8, InetAddress.getByName("127.0.0.1"));
          out("LISTEN port=" + port);
          Thread t = new Thread(new Runnable() {
              public void run() {
                  while (true) {
                      try {
                          final Socket s = ss.accept();
                          Thread c = new Thread(new Runnable() {
                              public void run() { serve(s); }
                          }, "btkbd-client");
                          c.setDaemon(true);
                          c.start();
                      } catch (Throwable t) {
                          out("ERR accept: " + t);
                          return;
                      }
                  }
              }
          }, "btkbd-accept");
          t.setDaemon(true);
          t.start();
      }

      private static void serve(Socket s) {
          try {
              s.setTcpNoDelay(true);
              BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
              PrintWriter w = new PrintWriter(s.getOutputStream(), true);
              String first = in.readLine();
              if (first == null || !first.startsWith("AUTH ") || !first.substring(5).trim().equals(token)) {
                  w.println("ERR auth");
                  s.close();
                  return;
              }
              w.println("OK auth version=" + VERSION);
              String line;
              while ((line = in.readLine()) != null) {
                  if (line.length() == 0) continue;
                  String reply = handle(line.trim());
                  w.println(reply);
                  if ("Q".equals(line.trim())) { s.close(); out("BYE"); System.exit(0); }
              }
          } catch (Throwable t) {
              out("ERR client: " + t);
          } finally {
              try { s.close(); } catch (Throwable ignored) { }
          }
      }

      private static String handle(String line) {
          String cmd = line, arg = "";
          int sp = line.indexOf(' ');
          if (sp > 0) { cmd = line.substring(0, sp); arg = line.substring(sp + 1).trim(); }
          try {
              if (cmd.equals("PING")) return "OK pong";
              if (cmd.equals("?") || cmd.equals("STATUS")) return status();
              if (cmd.equals("R")) return sendReport(arg);
              if (cmd.equals("DELAY")) { delayMs = Integer.parseInt(arg); return "OK delay=" + delayMs; }
              if (cmd.equals("BONDED")) return bonded();
              if (cmd.equals("C")) return connect(arg);
              if (cmd.equals("D")) return disconnect();
              if (cmd.equals("BOND")) return bond(arg);
              if (cmd.equals("UNBOND")) return unbond(arg);
              if (cmd.equals("DISCOVERABLE")) return discoverable(arg);
              if (cmd.equals("AUTORECONNECT")) { autoReconnect = !"0".equals(arg); return "OK autoreconnect=" + autoReconnect; }
              if (cmd.equals("Q")) return "OK bye";
              return "ERR unknown-command " + cmd;
          } catch (Throwable t) {
              return "ERR " + t;
          }
      }

      private static String status() {
          BluetoothDevice t = target();
          int st = peerState;
          if (hid != null && t != null) {
              try { st = hid.getConnectionState(t); } catch (Throwable ignored) { }
          }
          return "OK version=" + VERSION
               + " registered=" + (registered ? 1 : 0)
              + " state=" + stateName(st)
              + " host=" + (t != null ? t.getAddress() : "none")
               + " bond=" + (t != null ? bondStateName(t.getBondState()) : "NONE")
              + " adapter=" + (adapter != null && adapter.isEnabled() ? "on" : "off")
              + " uid=" + Process.myUid()
              + " autoreconnect=" + (autoReconnect ? 1 : 0)
              + " delay=" + delayMs;
      }

      private static BluetoothDevice target() {
          if (hid != null) {
              try {
                  List<BluetoothDevice> l = hid.getConnectedDevices();
                  if (l != null && !l.isEmpty()) return l.get(0);
              } catch (Throwable ignored) { }
          }
          return peer;
      }

      private static String bonded() {
          StringBuilder sb = new StringBuilder("OK ");
          try {
              Set<BluetoothDevice> set = adapter.getBondedDevices();
              boolean first = true;
              if (set != null) {
                  for (BluetoothDevice d : set) {
                      if (!first) sb.append(',');
                      sb.append(d.getAddress()).append('|').append(d.getName())
                        .append('|').append(bondStateName(d.getBondState()));
                      first = false;
                  }
              }
          } catch (Throwable t) {
              return "ERR bonded " + t;
          }
          return sb.toString();
      }

      private static synchronized String sendReport(String hex) {
          if (hid == null) return "ERR not-registered";
          if (!registered) return "ERR not-registered";
          BluetoothDevice d = target();
          if (d == null) return "ERR no-host";
          // A virtually-cabled host is not necessarily a connected one; without this
          // check the caller only sees a vague send-failed.
          int cs = STATE_DISCONNECTED;
          try { cs = hid.getConnectionState(d); } catch (Throwable ignored) { }
          if (cs != STATE_CONNECTED) return "ERR not-connected state=" + stateName(cs) + " host=" + d.getAddress();
          byte[] data = parseHex(hex);
          if (data.length != 8) return "ERR report-must-be-8-bytes";
          boolean ok;
          try {
              ok = hid.sendReport(d, 1, data);
          } catch (Throwable t) {
              return "ERR sendReport " + t;
          }
          lastReport = data;
          if (delayMs > 0) {
              try { Thread.sleep(delayMs); } catch (InterruptedException ignored) { }
          }
          return ok ? "OK" : "ERR send-failed";
      }

      private static String connect(String mac) {
          if (hid == null) return "ERR not-registered";
          BluetoothDevice d;
          if (mac == null || mac.length() == 0) {
              d = target();
              if (d == null) return "ERR no-device";
          } else {
              d = adapter.getRemoteDevice(mac.toUpperCase());
          }
          peer = d;
          autoReconnect = true;
          boolean ok;
          try { ok = hid.connect(d); } catch (Throwable t) { return "ERR connect " + t; }
          return ok ? "OK connecting " + d.getAddress() : "ERR connect-refused";
      }

      private static String bondStateName(int s) {
          switch (s) {
              case BluetoothDevice.BOND_BONDED: return "BONDED";
              case BluetoothDevice.BOND_BONDING: return "BONDING";
              default: return "NONE";
          }
      }

      /** Let the phone initiate pairing; often succeeds where Windows-initiated fails. */
      private static String bond(String mac) {
          if (adapter == null) return "ERR no-adapter";
          if (mac == null || mac.length() == 0) return "ERR need-mac";
          BluetoothDevice d;
          try { d = adapter.getRemoteDevice(mac.toUpperCase()); } catch (Throwable t) { return "ERR bad-mac " + t; }
          peer = d;
          int bs = d.getBondState();
          out("BOND state-before=" + bondStateName(bs) + " " + d.getAddress());
          if (bs == BluetoothDevice.BOND_BONDED) return "OK already-bonded " + d.getAddress();

          // A bonding attempt left half-finished makes every later createBond()
          // return false immediately, which looks like a flat refusal.
          if (bs == BluetoothDevice.BOND_BONDING) {
              try {
                  Method c = BluetoothDevice.class.getMethod("cancelBondProcess");
                  c.setAccessible(true);
                  out("BOND cancelBondProcess=" + c.invoke(d));
                  Thread.sleep(1500);
              } catch (Throwable t) {
                  out("BOND cancelBondProcess failed: " + t);
              }
          }

          boolean ok = false;
          try {
              ok = d.createBond();
              out("BOND createBond()=" + ok);
          } catch (Throwable t) {
              return "ERR createBond " + t;
          }
          if (!ok) {
              // The default transport can resolve to LE; HID here is BR/EDR only.
              try {
                  Method m = BluetoothDevice.class.getMethod("createBond", int.class);
                  m.setAccessible(true);
                  Object r = m.invoke(d, 1); // TRANSPORT_BREDR
                  ok = Boolean.TRUE.equals(r);
                  out("BOND createBond(TRANSPORT_BREDR)=" + r);
              } catch (Throwable t) {
                  out("BOND createBond(transport) unavailable: " + t);
              }
          }
          if (!ok) {
              return "ERR createBond-refused state=" + bondStateName(d.getBondState())
                   + " hint=open Windows' 'Add a device' dialog first so the PC accepts pairing";
          }

          // Report the outcome rather than just "we asked".
          for (int i = 0; i < 20; i++) {
              try { Thread.sleep(500); } catch (InterruptedException e) { break; }
              int s = d.getBondState();
              if (s == BluetoothDevice.BOND_BONDED) return "OK bonded " + d.getAddress();
              if (s == BluetoothDevice.BOND_NONE && i > 4) {
                  return "ERR bond-failed (rejected or timed out) " + d.getAddress();
              }
          }
          return "OK bonding " + d.getAddress() + " state=" + bondStateName(d.getBondState());
      }

      /** removeBond() is hidden API - the only way to clear a stale link key from here. */
      private static String unbond(String mac) {
          if (adapter == null) return "ERR no-adapter";
          BluetoothDevice d;
          if (mac == null || mac.length() == 0) {
              d = target();
              if (d == null) return "ERR need-mac";
          } else {
              try { d = adapter.getRemoteDevice(mac.toUpperCase()); } catch (Throwable t) { return "ERR bad-mac " + t; }
          }
          try {
              Method m = BluetoothDevice.class.getMethod("removeBond");
              m.setAccessible(true);
              Object r = m.invoke(d);
              return "OK removeBond=" + r + " " + d.getAddress();
          } catch (Throwable t) {
              return "ERR removeBond " + t;
          }
      }

      private static String disconnect() {
          autoReconnect = false;
          if (hid == null) return "ERR not-registered";
          BluetoothDevice d = target();
          if (d == null) return "OK already-disconnected";
          try { hid.disconnect(d); } catch (Throwable t) { return "ERR disconnect " + t; }
          return "OK disconnecting";
      }

      /** setScanMode is a hidden/system API whose signature changed across releases. */
      private static String discoverable(String secs) {
          int duration = 300;
          try { if (secs != null && secs.length() > 0) duration = Integer.parseInt(secs); } catch (Throwable ignored) { }
          final int SCAN_MODE_CONNECTABLE_DISCOVERABLE = 23;
          Throwable last = null;
          try {
              Method m = BluetoothAdapter.class.getMethod("setScanMode", int.class, long.class);
              Object r = m.invoke(adapter, SCAN_MODE_CONNECTABLE_DISCOVERABLE, (long) duration * 1000L);
              return "OK scanmode " + r;
          } catch (Throwable t) { last = t; }
          try {
              Method m = BluetoothAdapter.class.getMethod("setScanMode", int.class, int.class);
              Object r = m.invoke(adapter, SCAN_MODE_CONNECTABLE_DISCOVERABLE, duration);
              return "OK scanmode " + r;
          } catch (Throwable t) { last = t; }
          try {
              Method m = BluetoothAdapter.class.getMethod("setScanMode", int.class);
              Object r = m.invoke(adapter, SCAN_MODE_CONNECTABLE_DISCOVERABLE);
              return "OK scanmode " + r;
          } catch (Throwable t) { last = t; }
          return "ERR setScanMode " + last;
      }

      private static byte[] parseHex(String s) {
          s = s.replaceAll("[^0-9a-fA-F]", "");
          byte[] b = new byte[s.length() / 2];
          for (int i = 0; i < b.length; i++) {
              b[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
          }
          return b;
      }

      private static String toHex(byte[] b) {
          if (b == null) return "";
          StringBuilder sb = new StringBuilder();
          for (byte x : b) sb.append(String.format("%02x", x & 0xff));
          return sb.toString();
      }
  }
JAVA_SERVER

  # ---- compile-only stubs: signatures must match the platform exactly, but no
  # ---- bodies are needed because these classes are never put into the dex.
  cat > "$STUBS/android/content/Context.java" <<'JAVA_CTX'
package android.content;
public class Context {
    public static final String BLUETOOTH_SERVICE = "bluetooth";
    public Object getSystemService(String name) { return null; }
    public String getPackageName() { return null; }
    public String getOpPackageName() { return null; }
    public AttributionSource getAttributionSource() { return null; }
}
JAVA_CTX

  cat > "$STUBS/android/content/ContextWrapper.java" <<'JAVA_CTXW'
package android.content;
public class ContextWrapper extends Context {
    public ContextWrapper(Context base) { }
}
JAVA_CTXW

  cat > "$STUBS/android/content/AttributionSource.java" <<'JAVA_ATTR'
package android.content;
public final class AttributionSource {
    public static final class Builder {
        public Builder(int uid) { }
        public Builder setPackageName(String packageName) { return this; }
        public AttributionSource build() { return null; }
    }
}
JAVA_ATTR

  cat > "$STUBS/android/os/Looper.java" <<'JAVA_LOOPER'
package android.os;
public final class Looper {
    public static void prepareMainLooper() { }
    public static Looper getMainLooper() { return null; }
    public static void loop() { }
}
JAVA_LOOPER

  cat > "$STUBS/android/os/IBinder.java" <<'JAVA_IBINDER'
package android.os;
public interface IBinder { }
JAVA_IBINDER

  cat > "$STUBS/android/os/Process.java" <<'JAVA_PROC'
package android.os;
public class Process {
    public static final int ROOT_UID = 0;
    public static final int SYSTEM_UID = 1000;
    public static final int SHELL_UID = 2000;
    public static final int myUid() { return 0; }
}
JAVA_PROC

  cat > "$STUBS/android/bluetooth/BluetoothProfile.java" <<'JAVA_PROFILE'
package android.bluetooth;
public interface BluetoothProfile {
    int STATE_DISCONNECTED = 0;
    int STATE_CONNECTING = 1;
    int STATE_CONNECTED = 2;
    int STATE_DISCONNECTING = 3;
    int HID_DEVICE = 19;
    interface ServiceListener {
        void onServiceConnected(int profile, BluetoothProfile proxy);
        void onServiceDisconnected(int profile);
    }
}
JAVA_PROFILE

  cat > "$STUBS/android/bluetooth/BluetoothDevice.java" <<'JAVA_DEV'
package android.bluetooth;
public final class BluetoothDevice {
    public static final int BOND_NONE = 10;
    public static final int BOND_BONDING = 11;
    public static final int BOND_BONDED = 12;
    public String getAddress() { return null; }
    public String getName() { return null; }
    public int getBondState() { return 0; }
    public boolean createBond() { return false; }
}
JAVA_DEV

  cat > "$STUBS/android/bluetooth/BluetoothAdapter.java" <<'JAVA_ADAPTER'
package android.bluetooth;
import android.content.Context;
import java.util.Set;
public final class BluetoothAdapter {
    public static final int SCAN_MODE_NONE = 20;
    public static final int SCAN_MODE_CONNECTABLE = 21;
    public static final int SCAN_MODE_CONNECTABLE_DISCOVERABLE = 23;
    public static BluetoothAdapter getDefaultAdapter() { return null; }
    public boolean isEnabled() { return false; }
    public String getName() { return null; }
    public boolean setName(String name) { return false; }
    public int getScanMode() { return 0; }
    public Set<BluetoothDevice> getBondedDevices() { return null; }
    public BluetoothDevice getRemoteDevice(String address) { return null; }
    public boolean getProfileProxy(Context context, BluetoothProfile.ServiceListener listener, int profile) { return false; }
    public void closeProfileProxy(int profile, BluetoothProfile proxy) { }
}
JAVA_ADAPTER

  cat > "$STUBS/android/bluetooth/BluetoothManager.java" <<'JAVA_BM'
package android.bluetooth;
public final class BluetoothManager {
    public BluetoothAdapter getAdapter() { return null; }
}
JAVA_BM

  cat > "$STUBS/android/bluetooth/BluetoothHidDeviceAppSdpSettings.java" <<'JAVA_SDP'
package android.bluetooth;
public final class BluetoothHidDeviceAppSdpSettings {
    public BluetoothHidDeviceAppSdpSettings(String name, String description, String provider,
                                            byte subclass, byte[] descriptors) { }
}
JAVA_SDP

  cat > "$STUBS/android/bluetooth/BluetoothHidDeviceAppQosSettings.java" <<'JAVA_QOS'
package android.bluetooth;
public final class BluetoothHidDeviceAppQosSettings {
    public BluetoothHidDeviceAppQosSettings(int serviceType, int tokenRate, int tokenBucketSize,
                                            int peakBandwidth, int latency, int delayVariation) { }
}
JAVA_QOS

  cat > "$STUBS/android/bluetooth/BluetoothHidDevice.java" <<'JAVA_HID'
package android.bluetooth;
import java.util.List;
import java.util.concurrent.Executor;
public final class BluetoothHidDevice implements BluetoothProfile {
    public static final byte SUBCLASS1_NONE = (byte) 0x00;
    public static final byte SUBCLASS1_KEYBOARD = (byte) 0x40;
    public static final byte SUBCLASS1_MOUSE = (byte) 0x80;
    public static final byte SUBCLASS1_COMBO = (byte) 0xC0;
    public static final byte REPORT_TYPE_INPUT = (byte) 1;
    public static final byte REPORT_TYPE_OUTPUT = (byte) 2;
    public static final byte REPORT_TYPE_FEATURE = (byte) 3;
    public static final byte PROTOCOL_BOOT_MODE = (byte) 0;
    public static final byte PROTOCOL_REPORT_MODE = (byte) 1;

    public boolean registerApp(BluetoothHidDeviceAppSdpSettings sdp,
                              BluetoothHidDeviceAppQosSettings inQos,
                              BluetoothHidDeviceAppQosSettings outQos,
                              Executor executor, Callback callback) { return false; }
    public boolean unregisterApp() { return false; }
    public boolean sendReport(BluetoothDevice device, int id, byte[] data) { return false; }
    public boolean replyReport(BluetoothDevice device, byte type, byte id, byte[] data) { return false; }
    public boolean reportError(BluetoothDevice device, byte error) { return false; }
    public boolean connect(BluetoothDevice device) { return false; }
    public boolean disconnect(BluetoothDevice device) { return false; }
    public int getConnectionState(BluetoothDevice device) { return 0; }
    public List<BluetoothDevice> getConnectedDevices() { return null; }

    public abstract static class Callback {
        public void onAppStatusChanged(BluetoothDevice pluggedDevice, boolean registered) { }
        public void onConnectionStateChanged(BluetoothDevice device, int state) { }
        public void onGetReport(BluetoothDevice device, byte type, byte id, int bufferSize) { }
        public void onSetReport(BluetoothDevice device, byte type, byte id, byte[] data) { }
        public void onSetProtocol(BluetoothDevice device, byte protocol) { }
        public void onInterruptData(BluetoothDevice device, byte reportId, byte[] data) { }
        public void onVirtualCableUnplug(BluetoothDevice device) { }
    }
}
JAVA_HID
}

# ===========================================================================
# dispatcher (skipped when the script is sourced)
# ===========================================================================
btkbd_main() {
  local c=${1:-help}; shift || true
  case $c in
    check)              cmd_check "$@" ;;
    enable)             cmd_enable "$@" ;;
    build)              cmd_build "$@" ;;
    start)              cmd_start "$@" ;;
    trace)              cmd_trace "$@" ;;
    stop)               cmd_stop "$@" ;;
    restart)            cmd_stop; cmd_start ;;
    pair)               cmd_pair "$@" ;;
    connect)            cmd_connect "$@" ;;
    disconnect)         cmd_disconnect "$@" ;;
    bond)               cmd_bond "$@" ;;
    unbond|forget)      cmd_unbond "$@" ;;
    status)             cmd_status "$@" ;;
    up)                 cmd_up "$@" ;;
    probe)              cmd_probe "$@" ;;
    doctor)             cmd_doctor "$@" ;;
    keys)               cmd_keys ;;
    type|text)          btkbd_require_connected >/dev/null && send_text "$*" ;;
    key)                btkbd_require_connected >/dev/null && send_key "$1" ;;
    raw)                btkbd_require_connected >/dev/null && send_raw "$1" ;;
    help|-h|--help)     cmd_help ;;
    *)                  err "unknown command '$c'"; cmd_help; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  btkbd_main "$@"
  rc=$?
  link_down
  exit $rc
fi
