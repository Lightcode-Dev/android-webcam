#!/bin/bash
# Android phone -> virtual webcam (scrcpy + v4l2loopback), with auto-relaunch.
# Usage: webcam.sh [serial]
#   PREFER_FACING=back|front|external (default: back)
#   AUDIO=mic|playback|off           (default: mic)
#   VIRTUAL_MIC=on|off               (default: on; needs pactl/PipeWire)
set -u

PREFER_FACING=${PREFER_FACING:-back}
AUDIO=${AUDIO:-mic}
case $AUDIO in
    mic|playback|off) ;;
    *) echo "AUDIO must be mic, playback, or off (got: $AUDIO)" >&2; exit 1 ;;
esac
VIRTUAL_MIC=${VIRTUAL_MIC:-on}
case $VIRTUAL_MIC in
    on|off) ;;
    *) echo "VIRTUAL_MIC must be on or off (got: $VIRTUAL_MIC)" >&2; exit 1 ;;
esac
MIC_SINK=AndroidMic             # virtual sink the phone's audio is routed to
MIC_SOURCE=$MIC_SINK-source     # the selectable "microphone" other apps see
VIDEO_NR=${VIDEO_NR:-0}              # which /dev/videoN to use; set VIDEO_NR=10 etc. to use another
DEV=${WEBCAM_DEV:-/dev/video$VIDEO_NR}   # or set WEBCAM_DEV=/dev/videoN directly
LABEL=${LOOPBACK_LABEL:-AndroidWebcam}   # name given to $DEV only if the script has to create it
V4L_SYS=/sys/class/video4linux           # where the kernel lists each video device's name
WANT=${1:-}          # optional: only ever use this serial
MIN_RUNTIME=5        # a stream that dies sooner than this (seconds) counts as a failure
MAX_FAILS=3          # give up after this many failures in a row

for cmd in adb scrcpy; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

# Newer scrcpy keeps a (blank) window open with --no-playback; --no-window
# removes it. Older versions only know --no-playback.
if scrcpy --help 2>&1 | grep -q -e '--no-window'; then
    NOWIN=--no-window
else
    NOWIN=--no-playback
fi

# Ctrl+C or SIGTERM stops the whole loop (not just the current stream).
trap 'echo; echo "Stopping."; exit 0' INT TERM

declare -A REJECTED=()   # phones we can't use (too old, unparseable); cleared on unplug
SERIALS=() SERIAL="" CAM="" CAM_FACING="" BITRATE="" ARGS=()

# ---------------------------------------------------------------- helpers

# Fill SERIALS with every authorized phone ($2 == "device").
list_phones() {
    mapfile -t SERIALS < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
}

# Block until at least one usable phone is connected; leave only usable ones in SERIALS.
wait_for_phone() {
    local announced=0 s r
    local -a usable
    while true; do
        list_phones

        # Forget rejected phones that were unplugged, so replugging retries them.
        for r in "${!REJECTED[@]}"; do
            [[ " ${SERIALS[*]} " == *" $r "* ]] || unset "REJECTED[$r]"
        done

        usable=()
        for s in "${SERIALS[@]}"; do
            [ -n "${REJECTED[$s]+x}" ] && continue
            [ -n "$WANT" ] && [ "$s" != "$WANT" ] && continue
            usable+=("$s")
        done

        if [ "${#usable[@]}" -gt 0 ]; then
            SERIALS=("${usable[@]}")
            return 0
        fi

        ((announced)) || { echo "Waiting for an Android phone..."; announced=1; }
        sleep 1
    done
}

# Set SERIAL: the only phone, or an fzf choice when several are plugged in.
pick_phone() {
    SERIAL=""
    if [ "${#SERIALS[@]}" -eq 1 ] || ! command -v fzf >/dev/null; then
        SERIAL=${SERIALS[0]}
        return 0
    fi
    local menu=() s model
    for s in "${SERIALS[@]}"; do
        model=$(adb -s "$s" shell getprop ro.product.model | tr -d '\r')
        menu+=("$s  $model")
    done
    SERIAL=$(printf '%s\n' "${menu[@]}" | fzf --prompt="Webcam phone> " | awk '{print $1}')
    [ -n "$SERIAL" ]
}

# Camera mirroring needs Android 12 (SDK 31).
check_sdk() {
    local sdk
    sdk=$(adb -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')
    if [ "${sdk:-0}" -lt 31 ]; then
        echo "$SERIAL is on SDK ${sdk:-?}; camera mirroring needs Android 12+. Skipping it." >&2
        return 1
    fi
}

# Parse `scrcpy --list-camera-sizes`, then set CAM, CAM_FACING, ARGS and BITRATE.
# (Plain --list-cameras only prints one line per camera; the size lines under
# each camera, like " - 1920x1080", only appear with --list-camera-sizes.)
detect_camera() {
    local -A FACING=() FPS=() SIZES=()
    local -a IDS=()
    local cam="" line f id sizes fps
    local re_cam='--camera-id=([^[:space:]]+)[[:space:]]+\(([a-z]+),'
    local re_fps='fps=(.*)\)'
    local re_size='^[[:space:]]+-[[:space:]]+([0-9]+x[0-9]+)[[:space:]]*$'

    while IFS= read -r line; do
        line=${line#"[server] INFO: "}      # first line may carry a log prefix
        if [[ $line =~ $re_cam ]]; then
            cam=${BASH_REMATCH[1]}
            FACING[$cam]=${BASH_REMATCH[2]}
            IDS+=("$cam")
            if [[ $line =~ $re_fps ]]; then
                f=${BASH_REMATCH[1]}
                FPS[$cam]=${f//[^0-9]/ }       # "[15, 30]" or "[[15, 15], [30, 60]]" -> numbers
            fi
        elif [[ -n $cam && $line =~ $re_size ]]; then
            SIZES[$cam]+=" ${BASH_REMATCH[1]}"
        fi
    done < <(scrcpy -s "$SERIAL" --list-camera-sizes 2>&1)

    if [ "${#IDS[@]}" -eq 0 ]; then
        echo "Couldn't parse any cameras. Run: scrcpy -s $SERIAL --list-camera-sizes" >&2
        return 1
    fi

    # Preferred facing, else the first camera.
    CAM=""
    for id in "${IDS[@]}"; do
        [ "${FACING[$id]}" = "$PREFER_FACING" ] && { CAM=$id; break; }
    done
    [ -z "$CAM" ] && CAM=${IDS[0]}
    CAM_FACING=${FACING[$CAM]}

    # Padding with spaces lets "* 60 *" match whole numbers only.
    sizes=" ${SIZES[$CAM]:-} "
    fps=" ${FPS[$CAM]:-} "
    ARGS=(--camera-id="$CAM")
    BITRATE=12M

    if [[ $sizes == *" 1920x1080 "* ]]; then
        ARGS+=(--camera-size=1920x1080)
        if [[ $fps == *" 60 "* ]]; then
            ARGS+=(--camera-fps=60); BITRATE=25M
        elif [[ $fps == *" 30 "* ]]; then
            ARGS+=(--camera-fps=30)
        fi
    elif [[ $sizes == *" 1280x720 "* ]]; then
        ARGS+=(--camera-size=1280x720)
        [[ $fps == *" 30 "* ]] && ARGS+=(--camera-fps=30)
    else
        echo "No 1080p/720p listed; letting scrcpy pick defaults."
    fi
}

# udev grants your user access a moment after a device appears.
wait_writable() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -w "$DEV" ] && return 0
        sleep 0.3
    done
    return 1
}

# Make sure $DEV (/dev/video0 by default) is there and we can write to it.
# A module that is already loaded (for example at boot, for Droidcam or
# another virtual camera) is used and never reloaded or reconfigured.
ensure_loopback() {
    if [ -e "$DEV" ]; then
        wait_writable && return 0
        echo "$DEV exists but your user can't write to it." >&2
        echo "If it is root:video mode 0660, add yourself to the video group" >&2
        echo "(sudo usermod -aG video \$USER, then log out and back in)." >&2
        diagnose; return 1
    fi

    if lsmod | grep -q '^v4l2loopback'; then
        # The module is already loaded (for something else, e.g. Droidcam on
        # another /dev/videoN), so don't unload it -- that would kill it.
        # Add $DEV to the running module instead, if we can.
        if command -v v4l2loopback-ctl >/dev/null; then
            echo "v4l2loopback is loaded; adding $DEV to it..."
            if sudo v4l2loopback-ctl add -n "$LABEL" -x1 "$DEV" >/tmp/.webcam-add.$$ 2>&1; then
                rm -f /tmp/.webcam-add.$$
                wait_writable && return 0
            else
                cat /tmp/.webcam-add.$$ >&2; rm -f /tmp/.webcam-add.$$
            fi
        fi
        echo "Couldn't create $DEV on the running v4l2loopback module." >&2
        echo "Install v4l2loopback-utils for this to work without a reboot" >&2
        echo "(sudo pacman -S v4l2loopback-utils), or add it at boot: see" >&2
        echo "/etc/modprobe.d/v4l2loopback.conf (sudoedit it), then reboot." >&2
        echo "Or set VIDEO_NR/WEBCAM_DEV to a device listed below." >&2
        diagnose; return 1
    fi

    echo "Loading v4l2loopback..."
    sudo modprobe v4l2loopback video_nr=$VIDEO_NR card_label="$LABEL" \
        exclusive_caps=1 max_buffers=2 || return 1
    wait_writable && return 0
    diagnose; return 1
}

# Print what is useful for working out why $DEV can't be used.
diagnose() {
    local d
    {
        echo "--- diagnostics ---"
        echo "video devices:"
        for d in "$V4L_SYS"/video*; do
            [ -e "$d/name" ] && echo "  ${d##*/}: $(cat "$d/name")"
        done
        echo "target: $DEV"
        ls -l "$DEV" 2>&1
        command -v getfacl >/dev/null && getfacl -p "$DEV" 2>/dev/null | sed 's/^/  /'
        echo "module loaded: $(lsmod | grep -c '^v4l2loopback')"
        echo "your groups: $(id -nG)"
        echo "processes with the device open:"
        if command -v fuser >/dev/null; then
            fuser -v "$DEV" 2>&1 | sed 's/^/  /'
        else
            echo "  (install psmisc to see this: sudo pacman -S psmisc)"
        fi
        echo "running scrcpy processes:"
        pgrep -a scrcpy | sed 's/^/  /'
        echo "---"
    } >&2
}

# Create the virtual mic once, if it isn't there yet: a null sink (so nothing
# plays out loud) plus a remapped source (so it shows up as a normal
# selectable microphone, not hidden as a sink's "monitor").
ensure_virtual_mic() {
    command -v pactl >/dev/null || {
        echo "pactl not found (install pipewire-pulse); phone audio will play" >&2
        echo "through your normal output instead of a virtual microphone." >&2
        return 1
    }
    pactl list short sinks 2>/dev/null | awk -v n="$MIC_SINK" '$2==n{f=1} END{exit !f}' || \
        pactl load-module module-null-sink sink_name="$MIC_SINK" \
            sink_properties=device.description="$MIC_SINK" >/dev/null 2>&1
    pactl list short sources 2>/dev/null | awk -v n="$MIC_SOURCE" '$2==n{f=1} END{exit !f}' || \
        pactl load-module module-remap-source master="$MIC_SINK".monitor \
            source_name="$MIC_SOURCE" source_properties=device.description="$MIC_SINK" \
            >/dev/null 2>&1
    pactl list short sinks 2>/dev/null | awk -v n="$MIC_SINK" '$2==n{f=1} END{exit !f}'
}

# Wait for scrcpy's audio stream to appear, then move it onto $MIC_SINK so it
# plays into the virtual mic instead of your speakers/headphones. Matches
# whichever sink-input appears after $1 (the pre-launch snapshot), since
# scrcpy's stream isn't reliably named -- this can grab the wrong stream if
# something else starts playing audio in the same moment.
route_to_virtual_mic() {
    local before=$1 after id i
    for i in $(seq 1 100); do
        after=$(pactl list short sink-inputs 2>/dev/null | awk '{print $1}')
        id=$(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | head -n1)
        if [ -n "$id" ]; then
            pactl move-sink-input "$id" "$MIC_SINK" >/dev/null 2>&1 && return 0
        fi
        sleep 0.2
    done
}

# ---------------------------------------------------------------- main loop

fails=0
while true; do
    wait_for_phone
    pick_phone || { echo "No phone selected." >&2; exit 1; }
    echo "Found phone: $SERIAL"

    if ! check_sdk || ! detect_camera; then
        REJECTED[$SERIAL]=1
        continue
    fi

    ensure_loopback || exit 1

    # v4l2loopback is video-only, so audio never goes through $DEV; scrcpy
    # plays it like any other app. With VIRTUAL_MIC=on that playback is
    # routed to a virtual sink (below) instead of your speakers/headphones,
    # so other apps can pick it up as a microphone and you don't hear it live.
    MOVER_PID=""
    if [ "$AUDIO" = off ]; then
        AUDIO_ARGS=(--no-audio)
    else
        AUDIO_ARGS=(--audio-source="$AUDIO" --audio-codec=opus)
        if [ "$VIRTUAL_MIC" = on ] && ensure_virtual_mic; then
            before_sink_inputs=$(pactl list short sink-inputs 2>/dev/null | awk '{print $1}')
            route_to_virtual_mic "$before_sink_inputs" &
            MOVER_PID=$!
        fi
    fi

    echo "🚀 $SERIAL | camera $CAM ($CAM_FACING) | ${ARGS[*]} | $BITRATE | audio=$AUDIO | -> $DEV"

    start=$SECONDS
    # Runs in the foreground; returns when the phone is unplugged or scrcpy dies.
    scrcpy -s "$SERIAL" \
        --video-source=camera \
        "${ARGS[@]}" \
        --video-bit-rate="$BITRATE" \
        --video-codec=h264 \
        --v4l2-sink="$DEV" \
        "$NOWIN" \
        "${AUDIO_ARGS[@]}" \
        --video-buffer=0 \
        --v4l2-buffer=0
    status=$?
    runtime=$((SECONDS - start))
    [ -n "$MOVER_PID" ] && kill "$MOVER_PID" 2>/dev/null

    if [ "$runtime" -lt "$MIN_RUNTIME" ]; then
        fails=$((fails + 1))
        echo "Stream ended after ${runtime}s (exit $status), failure $fails/$MAX_FAILS." >&2
        if [ "$fails" -ge "$MAX_FAILS" ]; then
            echo "Giving up. Read the scrcpy error above." >&2
            diagnose
            exit 1
        fi
        sleep 2
    else
        fails=0
        echo "Stream ended. Waiting for the next phone..."
    fi
done
