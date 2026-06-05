#!/usr/bin/env bash
# normalize_music.sh — even out the loudness of your FS25 radio music (Linux/macOS)
#
# OPTIONAL tool. The game never runs this. Run it yourself to normalize the
# volume of the .mp3 files in your FarmingSimulator2025/music folder so loud and
# quiet songs play at a consistent level.
#
# Method: ffmpeg two-pass EBU R128 loudnorm (linear gain — even loudness, no
# dynamic squashing). Originals are backed up first by default.
#
# ffmpeg not installed? This script downloads a portable static build into
# tools/bin/ (no admin needed) and verifies it against the provider's checksum.
#
# Usage:
#   ./normalize_music.sh [MUSIC_DIR] [options]
# Options:
#   --target N      target loudness in LUFS (default -16)
#   --no-backup     do not copy originals before overwriting
#   --jobs N        process N files in parallel (default 2)
#   --undo          restore originals from the backup folder
#   --dry-run       show what would happen, change nothing
#   -h, --help      this help
set -euo pipefail

# ── Config / defaults ─────────────────────────────────────────────────────────
TARGET=-16
BACKUP=1
JOBS=2
DRYRUN=0
UNDO=0
MUSIC_DIR=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
STATE_DIR="$SCRIPT_DIR/.state"

LINUX_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"

FF=""
FP=""

err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }

pause_if_clicked() {
    if [ "$CLICKED" = 1 ] && [ -r /dev/tty ]; then
        printf "\nPress Enter to close..."; read -r _ </dev/tty || true
    fi
}

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

# Interactive menu shown when launched with no arguments (e.g. double-clicked)
CLICKED=0
[ $# -eq 0 ] && CLICKED=1

show_menu() {
    echo "Radio Shuffle — Music Audio Leveler"
    echo
    echo "  1) Dry run      (show each song's loudness, change nothing)"
    echo "  2) Level audio  (normalize to ${TARGET} LUFS; originals backed up)"
    echo "  3) Undo         (restore your original files)"
    echo "  4) Quit"
    echo
    local choice=""
    if [ -r /dev/tty ]; then
        printf "Choose [1-4]: "; read -r choice </dev/tty
    fi
    echo
    case "$choice" in
        1) DRYRUN=1 ;;
        2) : ;;
        3) UNDO=1 ;;
        4|q|Q|"") echo "Nothing to do. Bye."; exit 0 ;;
        *) DRYRUN=1; info "(unrecognized choice — doing a safe dry run)" ;;
    esac
}

# ── Parse args ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --target)    TARGET="$2"; shift 2 ;;
        --no-backup) BACKUP=0; shift ;;
        --jobs)      JOBS="$2"; shift 2 ;;
        --undo)      UNDO=1; shift ;;
        --dry-run)   DRYRUN=1; shift ;;
        -h|--help)   usage ;;
        -*)          err "Unknown option: $1"; exit 2 ;;
        *)           MUSIC_DIR="$1"; shift ;;
    esac
done

# Show the menu when launched with no arguments (clicked)
[ "$CLICKED" = 1 ] && show_menu

# ── Locate the music folder ───────────────────────────────────────────────────
resolve_music_dir() {
    if [ -n "$MUSIC_DIR" ]; then
        [ -d "$MUSIC_DIR" ] || { err "Music folder not found: $MUSIC_DIR"; exit 1; }
        return
    fi
    # Walk up from the script looking for a dir that has both mods/ and music/
    local d="$SCRIPT_DIR"
    while [ "$d" != "/" ]; do
        if [ -d "$d/mods" ] && [ -d "$d/music" ]; then
            MUSIC_DIR="$d/music"; return
        fi
        d="$(dirname "$d")"
    done
    err "Could not auto-detect your music folder."
    err "Pass it explicitly, e.g.:"
    err "  ./normalize_music.sh \"\$HOME/.../FarmingSimulator2025/music\""
    exit 1
}

# ── Ensure ffmpeg/ffprobe (download a portable build if missing) ──────────────
ensure_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
        FF="$(command -v ffmpeg)"; FP="$(command -v ffprobe)"; return
    fi
    if [ -x "$BIN_DIR/ffmpeg" ] && [ -x "$BIN_DIR/ffprobe" ]; then
        FF="$BIN_DIR/ffmpeg"; FP="$BIN_DIR/ffprobe"; return
    fi

    info "ffmpeg not found — downloading a portable build into tools/bin/ ..."
    local dl; dl="$(command -v curl >/dev/null 2>&1 && echo curl || echo wget)"
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    if [ "$dl" = curl ]; then
        curl -fSL "$LINUX_URL"        -o "$tmp/ff.tar.xz"
        curl -fSL "$LINUX_URL.md5"    -o "$tmp/ff.md5"
    else
        wget -q "$LINUX_URL"     -O "$tmp/ff.tar.xz"
        wget -q "$LINUX_URL.md5" -O "$tmp/ff.md5"
    fi

    local want; want="$(awk '{print $1}' "$tmp/ff.md5")"
    local have; have="$(md5sum "$tmp/ff.tar.xz" | awk '{print $1}')"
    if [ "$want" != "$have" ]; then
        err "Checksum mismatch on downloaded ffmpeg (expected $want, got $have)."
        err "Aborting for safety. Install ffmpeg yourself (e.g. 'sudo dnf install ffmpeg') and re-run."
        exit 1
    fi

    mkdir -p "$BIN_DIR"
    tar -xf "$tmp/ff.tar.xz" -C "$tmp"
    local d; d="$(find "$tmp" -maxdepth 1 -type d -name 'ffmpeg-*-static' | head -1)"
    cp "$d/ffmpeg" "$d/ffprobe" "$BIN_DIR/"
    chmod +x "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe"
    FF="$BIN_DIR/ffmpeg"; FP="$BIN_DIR/ffprobe"
    ok "Portable ffmpeg ready in tools/bin/"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
json_val() { # json_val <text> <key>
    printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' | head -1
}

state_key() { printf '%s' "$1" | md5sum | awk '{print $1}'; }

is_done() { # is_done <file>
    local m="$STATE_DIR/$(state_key "$1")"
    [ -f "$m" ] || return 1
    local sig; sig="$(stat -c '%s:%Y' "$1" 2>/dev/null || stat -f '%z:%m' "$1")"
    [ "$(cat "$m")" = "$sig" ]
}

mark_done() { # mark_done <file>
    mkdir -p "$STATE_DIR"
    local sig; sig="$(stat -c '%s:%Y' "$1" 2>/dev/null || stat -f '%z:%m' "$1")"
    printf '%s' "$sig" > "$STATE_DIR/$(state_key "$1")"
}

# ── Normalize a single file (two-pass loudnorm) ───────────────────────────────
normalize_one() {
    local f="$1"
    local rel="${f#"$MUSIC_DIR"/}"

    if is_done "$f"; then
        info "skip (done)  $rel"; return 0
    fi

    # Pass 1 — measure
    local p1
    p1="$("$FF" -hide_banner -nostats -i "$f" \
            -af "loudnorm=I=$TARGET:TP=-1.5:LRA=11:print_format=json" \
            -f null - 2>&1 || true)"
    local json; json="$(printf '%s' "$p1" | sed -n '/{/,/}/p')"
    local mi mtp mlra mth off
    mi="$(json_val "$json" input_i)"
    mtp="$(json_val "$json" input_tp)"
    mlra="$(json_val "$json" input_lra)"
    mth="$(json_val "$json" input_thresh)"
    off="$(json_val "$json" target_offset)"
    if [ -z "$mi" ] || [ -z "$off" ]; then
        err "measure failed  $rel (skipping)"; return 1
    fi

    if [ "$DRYRUN" = 1 ]; then
        info "would level  $rel   (in ${mi} LUFS -> ${TARGET})"; return 0
    fi

    # Backup
    if [ "$BACKUP" = 1 ]; then
        local bdest="$BACKUP_DIR/$rel"
        mkdir -p "$(dirname "$bdest")"
        [ -f "$bdest" ] || cp "$f" "$bdest"
    fi

    # Pass 2 — apply. Temp file does NOT end in .mp3, so an interrupted run can
    # never leave a stray song in /music; it's renamed over the original on success.
    local tmp="${f}.partial"
    if "$FF" -hide_banner -nostats -y -i "$f" \
        -af "loudnorm=I=$TARGET:TP=-1.5:LRA=11:measured_I=$mi:measured_TP=$mtp:measured_LRA=$mlra:measured_thresh=$mth:offset=$off:linear=true" \
        -c:a libmp3lame -q:a 2 -map_metadata 0 -f mp3 "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$f"
        mark_done "$f"
        ok "leveled      $rel"
    else
        rm -f "$tmp"
        err "encode failed $rel"; return 1
    fi
}

# ── Undo ──────────────────────────────────────────────────────────────────────
do_undo() {
    [ -d "$BACKUP_DIR" ] || { err "No backup folder at $BACKUP_DIR"; exit 1; }
    info "Restoring originals from $BACKUP_DIR ..."
    ( cd "$BACKUP_DIR" && find . -type f -name '*.mp3' -print0 ) \
        | while IFS= read -r -d '' rel; do
            rel="${rel#./}"
            cp "$BACKUP_DIR/$rel" "$MUSIC_DIR/$rel" && info "restored $rel"
        done
    rm -rf "$STATE_DIR"
    ok "Undo complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────
resolve_music_dir
BACKUP_DIR="$(dirname "$MUSIC_DIR")/music_backup"

info "Music folder : $MUSIC_DIR"
info "Target       : $TARGET LUFS"
info "Backups      : $([ "$BACKUP" = 1 ] && echo "on -> $BACKUP_DIR" || echo off)"
[ "$DRYRUN" = 1 ] && info "(dry run — no files will be changed)"
echo

if [ "$UNDO" = 1 ]; then do_undo; pause_if_clicked; exit 0; fi

ensure_ffmpeg
info "ffmpeg       : $FF"
echo

# Remove any stray temp files from a previously interrupted run
find "$MUSIC_DIR" -type f -name '*.partial' -delete 2>/dev/null || true

# Count + process (parallel via xargs); portable (no mapfile)
total="$(find "$MUSIC_DIR" -type f -iname '*.mp3' | wc -l | tr -d ' ')"
info "Found $total mp3 files. Processing (jobs=$JOBS) ..."
echo

# Export what the worker needs and run
export -f normalize_one is_done mark_done json_val state_key info ok err
export FF FP TARGET BACKUP DRYRUN MUSIC_DIR BACKUP_DIR STATE_DIR

find "$MUSIC_DIR" -type f -iname '*.mp3' -print0 | sort -z \
    | xargs -0 -P "$JOBS" -I {} bash -c 'normalize_one "$@"' _ {} \
    || true

echo
ok "Done. $total files considered. Backups in: $([ "$BACKUP" = 1 ] && echo "$BACKUP_DIR" || echo "(disabled)")"
[ "$DRYRUN" = 0 ] && info "Reload your FS25 save to hear the leveled audio."

pause_if_clicked
