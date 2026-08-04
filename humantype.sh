#!/usr/bin/env bash
# humantype.sh - type a file onto the PC the way a person would: uneven speed,
#                pauses to think, occasional typos corrected with BACKSPACE.
#
#   bash humantype.sh mycode.py            # type it once
#   bash humantype.sh mycode.py 3          # type it 3 times
#   REPEAT_COUNT=0 bash humantype.sh f.py  # forever (Ctrl-C to stop)
#   DRY_RUN=1 bash humantype.sh f.py       # preview in the terminal, send nothing
#
# Every knob below can also be overridden from the environment, e.g.
#   TYPO_CHANCE=15 CHAR_MS_MAX=250 bash humantype.sh mycode.py

set -u

# ===========================================================================
# tunables
# ===========================================================================

# how many times to type the whole file; 0 = forever
: "${REPEAT_COUNT:=1}"
: "${REPEAT_PAUSE_S:=8}"          # pause between repetitions
: "${START_DELAY_S:=5}"           # grace period to focus the target window

# per-character speed (milliseconds). Each word picks a speed band, so some
# words come out in a burst and others are laboured.
: "${CHAR_MS_MIN:=45}"
: "${CHAR_MS_MAX:=170}"
: "${FAST_WORD_CHANCE:=35}"       # % of words typed in a burst
: "${SLOW_WORD_CHANCE:=20}"       # % of words typed hesitantly

# pauses
: "${WORD_PAUSE_MS_MIN:=60}"
: "${WORD_PAUSE_MS_MAX:=380}"
: "${LINE_PAUSE_MS_MIN:=350}"
: "${LINE_PAUSE_MS_MAX:=1400}"

# "thinking" stalls of a couple of seconds, as when deciding what comes next
: "${THINK_CHANCE:=7}"            # % chance before a word
: "${THINK_MS_MIN:=1800}"
: "${THINK_MS_MAX:=3200}"
: "${THINK_AFTER_SYMBOLS:=1}"     # also stall after { } ( ) ; = lines

# mistakes
: "${TYPO_CHANCE:=6}"             # % chance per word (words >= 3 chars)
: "${TYPO_NOTICE_MS_MIN:=180}"    # delay before noticing the mistake
: "${TYPO_NOTICE_MS_MAX:=700}"

# Editors that auto-indent will double the leading whitespace. Set to 1 for
# IDEs/editors with auto-indent; leave 0 for Notepad and friends.
: "${AUTO_INDENT:=0}"

: "${TRAILING_ENTER:=1}"          # press ENTER after the last line
: "${DRY_RUN:=0}"                 # 1 = print instead of typing

# ===========================================================================

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

msg() { printf '\033[36m[humantype]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[humantype]\033[0m %s\n' "$*" >&2; exit 1; }

FILE=${1:-}
[ -n "$FILE" ] || die "usage: bash humantype.sh <file> [repeat-count]"
[ -r "$FILE" ] || die "cannot read '$FILE'"
[ $# -ge 2 ] && REPEAT_COUNT=$2

if [ "$DRY_RUN" = 1 ]; then
  send_text() { printf '%s' "$1"; }
  send_key()  { case $1 in ENTER) printf '\n' ;; TAB) printf '\t' ;; BACKSPACE) printf '\b \b' ;; esac; }
  send_raw()  { :; }
  msg "DRY_RUN: printing to the terminal, nothing is sent over Bluetooth"
else
  # our own pacing should dominate, so keep the helper's inter-report delay small
  export BTKBD_DELAY_MS=${BTKBD_DELAY_MS:-2}
  # shellcheck source=btkbd.sh
  source "$SELF_DIR/btkbd.sh"
  btkbd_require_connected || die "not connected - try: bash $SELF_DIR/btkbd.sh status"
fi

# release every key on the way out, so nothing is left stuck down
cleanup() { [ "$DRY_RUN" = 1 ] || send_raw 0000000000000000 2>/dev/null || true; }
trap 'printf "\n" >&2; msg "interrupted"; cleanup; exit 130' INT TERM
trap cleanup EXIT

# ---------------------------------------------------------------------------
# timing helpers (printf and $RANDOM are builtins, so these cost no forks)
# ---------------------------------------------------------------------------
rnd() { echo $(( $1 + RANDOM % ( $2 - $1 + 1 ) )); }

msleep() {
  local ms=$1
  [ "$ms" -le 0 ] && return 0
  sleep "$(printf '%d.%03d' $((ms / 1000)) $((ms % 1000)))"
}

chance() { [ $((RANDOM % 100)) -lt "$1" ]; }

WORD_MS_MIN=$CHAR_MS_MIN
WORD_MS_MAX=$CHAR_MS_MAX

# Pick a speed band for the next word: burst, normal, or hesitant.
roll_word_speed() {
  if chance "$FAST_WORD_CHANCE"; then
    WORD_MS_MIN=$((CHAR_MS_MIN / 2 + 5)); WORD_MS_MAX=$((CHAR_MS_MIN + 25))
  elif chance "$SLOW_WORD_CHANCE"; then
    WORD_MS_MIN=$((CHAR_MS_MAX / 2)); WORD_MS_MAX=$((CHAR_MS_MAX + 120))
  else
    WORD_MS_MIN=$CHAR_MS_MIN; WORD_MS_MAX=$CHAR_MS_MAX
  fi
}

# ---------------------------------------------------------------------------
# QWERTY neighbours, so a typo looks like a slipped finger rather than noise
# ---------------------------------------------------------------------------
declare -A NEAR=(
  [a]="qwsz" [b]="vghn" [c]="xdfv" [d]="serfcx" [e]="wsdr"  [f]="drtgvc"
  [g]="ftyhbv" [h]="gyujnb" [i]="ujko" [j]="huikmn" [k]="jiolm" [l]="kop"
  [m]="njk"  [n]="bhjm"  [o]="iklp" [p]="ol"     [q]="wa"    [r]="edft"
  [s]="awedxz" [t]="rfgy" [u]="yhji" [v]="cfgb"  [w]="qase"  [x]="zsdc"
  [y]="tghu" [z]="asx"
  [1]="2q"   [2]="13w"  [3]="24e"  [4]="35r"    [5]="46t"   [6]="57y"
  [7]="68u"  [8]="79i"  [9]="80o"  [0]="9p"
  [.]=",/"   [,]=".m"   [/]=".;"   [\;]="l'"    [-]="0="    [=]="-"
)

wrong_char() {
  local c=$1 lower=${c,,} set= pick
  set=${NEAR[$lower]:-}
  if [ -z "$set" ]; then
    printf 'abcdefghijklmnopqrstuvwxyz' | cut -c$((1 + RANDOM % 26))
    return
  fi
  pick=${set:$((RANDOM % ${#set})):1}
  # keep the case of the intended character
  if [ "$c" != "$lower" ]; then printf '%s' "${pick^}"; else printf '%s' "$pick"; fi
}

# ---------------------------------------------------------------------------
# typing primitives
# ---------------------------------------------------------------------------
type_char() {
  case $1 in
    $'\t') send_key TAB ;;
    *)     send_text "$1" ;;
  esac
  msleep "$(rnd "$WORD_MS_MIN" "$WORD_MS_MAX")"
}

backspace() {
  local n=${1:-1} i
  for ((i = 0; i < n; i++)); do
    send_key BACKSPACE
    msleep "$(rnd 60 160)"
  done
}

# Three flavours of mistake: an extra character, a wrong character mid-word,
# and two characters transposed - each noticed after a beat, then corrected.
type_word_with_typo() {
  local w=$1 n=${#w} kind=$((RANDOM % 3)) i k bad
  case $kind in
    0)
      for ((i = 0; i < n; i++)); do type_char "${w:i:1}"; done
      bad=$(wrong_char "${w:n-1:1}")
      type_char "$bad"
      msleep "$(rnd "$TYPO_NOTICE_MS_MIN" "$TYPO_NOTICE_MS_MAX")"
      backspace 1
      ;;
    1)
      k=$((1 + RANDOM % (n - 1)))
      for ((i = 0; i < k; i++)); do type_char "${w:i:1}"; done
      bad=$(wrong_char "${w:k:1}")
      type_char "$bad"
      msleep "$(rnd "$TYPO_NOTICE_MS_MIN" "$TYPO_NOTICE_MS_MAX")"
      backspace 1
      for ((i = k; i < n; i++)); do type_char "${w:i:1}"; done
      ;;
    2)
      k=$((RANDOM % (n - 1)))
      for ((i = 0; i < k; i++)); do type_char "${w:i:1}"; done
      type_char "${w:k+1:1}"
      type_char "${w:k:1}"
      msleep "$(rnd "$TYPO_NOTICE_MS_MIN" "$TYPO_NOTICE_MS_MAX")"
      backspace 2
      for ((i = k; i < n; i++)); do type_char "${w:i:1}"; done
      ;;
  esac
}

type_word() {
  local w=$1 i
  roll_word_speed
  chance "$THINK_CHANCE" && msleep "$(rnd "$THINK_MS_MIN" "$THINK_MS_MAX")"

  if [ ${#w} -ge 3 ] && chance "$TYPO_CHANCE"; then
    type_word_with_typo "$w"
  else
    for ((i = 0; i < ${#w}; i++)); do type_char "${w:i:1}"; done
  fi
}

type_line() {
  local line=$1 n=${#line} i=0 c w
  while [ $i -lt $n ]; do
    c=${line:i:1}
    case $c in
      ' '|$'\t')
        type_char "$c"
        i=$((i + 1))
        msleep "$(rnd "$WORD_PAUSE_MS_MIN" "$WORD_PAUSE_MS_MAX")"
        ;;
      *)
        w=""
        while [ $i -lt $n ]; do
          c=${line:i:1}
          case $c in ' '|$'\t') break ;; esac
          w+=$c
          i=$((i + 1))
        done
        type_word "$w"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
mapfile -t LINES < "$FILE"
TOTAL=${#LINES[@]}
[ "$TOTAL" -gt 0 ] || die "'$FILE' is empty"

type_file() {
  local idx line
  for idx in "${!LINES[@]}"; do
    line=${LINES[idx]}
    [ "$AUTO_INDENT" = 1 ] && line=${line#"${line%%[![:space:]]*}"}

    type_line "$line"

    if [ "$idx" -lt $((TOTAL - 1)) ]; then
      send_key ENTER
      msleep "$(rnd "$LINE_PAUSE_MS_MIN" "$LINE_PAUSE_MS_MAX")"
      # a closing brace or a blank line is a natural place to pause and think
      if [ "$THINK_AFTER_SYMBOLS" = 1 ]; then
        case ${line//[[:space:]]/} in
          ''|*'}'|*';'|*':') chance 35 && msleep "$(rnd "$THINK_MS_MIN" "$THINK_MS_MAX")" ;;
        esac
      fi
    elif [ "$TRAILING_ENTER" = 1 ]; then
      send_key ENTER
    fi
    printf '\r\033[36m[humantype]\033[0m line %d/%d  ' "$((idx + 1))" "$TOTAL" >&2
  done
  printf '\n' >&2
}

msg "file: $FILE ($TOTAL lines)"
msg "repeat: $([ "$REPEAT_COUNT" = 0 ] && echo forever || echo "$REPEAT_COUNT")   speed: ${CHAR_MS_MIN}-${CHAR_MS_MAX}ms/char   typos: ${TYPO_CHANCE}%"
if [ "$DRY_RUN" != 1 ]; then
  msg "focus the target window on the PC - starting in ${START_DELAY_S}s"
  sleep "$START_DELAY_S"
fi

iteration=0
while :; do
  iteration=$((iteration + 1))
  msg "pass $iteration"
  type_file
  if [ "$REPEAT_COUNT" != 0 ] && [ "$iteration" -ge "$REPEAT_COUNT" ]; then break; fi
  msg "pausing ${REPEAT_PAUSE_S}s before the next pass"
  sleep "$REPEAT_PAUSE_S"
done

msg "done ($iteration pass(es))"
