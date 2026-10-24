# Android Phone Webcam (scrcpy + v4l2loopback module)

A bash script that turns an Android phone into a virtual webcam on Linux. It streams the phone's camera over USB with `scrcpy` into a `v4l2loopback` virtual device, by default `/dev/video0`, so apps like Chrome, Firefox, Zoom, OBS, and Discord see it as a normal camera.

It is built for swapping between several phones: it detects which phone is plugged in, reads that phone's camera capabilities, and picks the resolution, frame rate, and bitrate automatically.

## Requirements

### Phone

- **Android 12 or newer.** scrcpy's camera mirroring doesn't work on older versions. The script checks this and exits with a message if the phone is too old.
- **Developer options and USB debugging enabled** (see below).
- A USB cable that carries data, not a charge-only cable.

### Computer (Arch Linux)

| Package | Provides | Required? |
|---|---|---|
| `scrcpy` | the camera streaming (needs 3.x for the flags used) | yes |
| `android-tools` | `adb` | yes |
| `v4l2loopback-dkms` | the virtual camera kernel module | yes |
| `dkms` | builds the module for your kernel (pulled in as a dependency) | yes |
| `linux-headers` | kernel headers DKMS needs to build the module | yes |
| `sudo` | the script uses it for `modprobe` | yes |
| `procps-ng` | `pkill` / `pgrep` | yes (already installed on most systems) |
| `gawk` | `awk` | yes (already installed on most systems) |
| `fzf` | phone picker menu when two phones are plugged in | optional |
| `v4l-utils` | `v4l2-ctl` for inspecting the virtual camera | optional |
| `ffmpeg` or `mpv` | quick preview/testing (`ffplay`, `mpv`) | optional |

Install everything:

```bash
sudo pacman -S --needed scrcpy android-tools v4l2loopback-dkms dkms linux-headers fzf v4l-utils ffmpeg
```

**Kernel headers must match your running kernel.** `linux-headers` is for the stock `linux` kernel. If you run something else, install the matching headers package instead:

| Kernel | Headers package |
|---|---|
| `linux` | `linux-headers` |
| `linux-lts` | `linux-lts-headers` |
| `linux-zen` | `linux-zen-headers` |
| `linux-hardened` | `linux-hardened-headers` |
| custom-built kernel | the `-headers` package built alongside it |

Check your running kernel with `uname -r`. After a kernel update, reboot so the running kernel matches the headers DKMS built against.

**Secure Boot:** if it's enabled, the unsigned `v4l2loopback` module will refuse to load. Either disable Secure Boot or sign the module.

## Setup

### 1. Enable USB debugging on each phone

1. **Settings → About phone**, then tap **Build number** 7 times to unlock Developer options.
2. **Settings → System → Developer options**, then turn on **USB debugging**.
3. Plug the phone in over USB.
4. Accept the **"Allow USB debugging?"** prompt on the phone. Tick "Always allow from this computer" so it doesn't ask again.

Repeat this once for every phone you want to use. Verify with:

```bash
adb devices
```

The phone should be listed with the state `device`. If it says `unauthorized`, accept the prompt on the phone. If it says `offline`, unplug it, replug it, and run `adb kill-server && adb start-server`.

### 2. git clone and Install the script

```bash
git clone https://github.com/Lightcode-Dev/android-webcam.git 
mkdir -p ~/.local/bin
cp android-webcam.sh ~/.local/bin/android-webcam
chmod +x ~/.local/bin/android-webcam
```

Make sure `~/.local/bin` is in your `PATH`. Or just run it from wherever you saved it with `./webcam.sh`.

## Usage

```bash
android-webcam                      # auto-pick the phone, back camera
android-webcam <serial>             # use a specific phone (skips the menu)
PREFER_FACING=front android-webcam  # use the selfie camera
AUDIO=off android-webcam            # camera only, no microphone
```

What happens when you run it:

1. It waits until a phone in the `device` (authorized) state appears.
2. If more than one phone is connected, an `fzf` menu lets you choose (serial plus model name). Without `fzf` it uses the first one.
3. It checks the phone is on Android 12+.
4. It runs `scrcpy --list-camera-sizes` (which lists each camera's supported sizes and frame rates) and picks the camera matching `PREFER_FACING` (`back`, `front`, or `external`), falling back to the first camera.
5. It picks the best settings that camera supports: 1080p60, then 1080p30, then 720p30, then scrcpy's defaults.
6. It makes sure `/dev/video0` (configurable, see below) is there and writable. If it's missing and nothing is loaded, it loads `v4l2loopback` with `sudo`. If `v4l2loopback` is already loaded for something else (e.g. Droidcam on another device number) it adds `/dev/video0` to the running module instead, using `v4l2loopback-ctl`, which never disturbs the existing device. A device that's already there and writable is used exactly as it is.
7. It starts streaming. When the phone is unplugged the stream ends and the script goes back to step 1 to wait for the next phone.

Press **Ctrl+C** to quit.

### Swapping phones

Leave the script running, unplug the current phone, and plug in the other one. The script notices, waits for the new phone, and starts streaming from it automatically. Press **Ctrl+C** only when you want to quit.

The virtual camera stays loaded throughout, so swapping doesn't need `sudo` and doesn't disturb apps that already have the camera selected. You may need to re select the camera in the app if it doesn't pick up the new stream.

### Finding your phones' serials

```bash
adb devices -l
```

Serials are in the first column. `-l` also shows the model name.

## Testing

With the script running, in another terminal:

```bash
ffplay /dev/video0
# or
mpv av://v4l2:/dev/video0
```

Inspect the virtual camera:

```bash
v4l2-ctl --list-devices
```

## Load the virtual camera at boot (optional)

If you'd rather not have the script load the module (it then needs no `sudo` at all), make it load at boot. The script detects a module that is already loaded and uses it as it is. Edit these with vim:

```bash
sudoedit /etc/modules-load.d/v4l2loopback.conf
```

```
# Load the v4l2loopback module at boot
v4l2loopback
```

```bash
sudoedit /etc/modprobe.d/v4l2loopback.conf
```

```
# Create the virtual camera: /dev/video0.
# exclusive_caps=1 makes it show up as a capture-only camera, which
# Chrome, Zoom, and most browsers need in order to list it.
options v4l2loopback video_nr=0 card_label="AndroidWebcam" exclusive_caps=1 max_buffers=2
```

If `sudoedit` opens the wrong editor, run it as `SUDO_EDITOR=vim sudoedit <file>`.

The script always targets one fixed device, `/dev/video0` by default, whatever it's named. Override it with one of these:

| Variable | Description |
|---|---|
| `VIDEO_NR` | Use `/dev/video<N>` instead of `/dev/video0`, e.g. `VIDEO_NR=10 android-webcam`. |
| `WEBCAM_DEV` | Use exactly this path, e.g. `WEBCAM_DEV=/dev/video3 android-webcam`. Overrides `VIDEO_NR`. |
| `LOOPBACK_LABEL` | Name to give the device if the script has to create it (default `AndroidWebcam`). Only matters the first time; it doesn't rename an existing device. |
| `PREFER_FACING` | `back` (default), `front`, or `external`. |
| `AUDIO` | `mic` (default, the phone's microphone), `playback` (the phone's internal audio, Android 11+), or `off`. |
| `VIRTUAL_MIC` | `on` (default) routes the phone's audio to a virtual microphone other apps can select, instead of your speakers. `off` plays it through your normal output like any other app. No effect when `AUDIO=off`. |

List the names of your video devices with:

```bash
for d in /sys/class/video4linux/*; do echo "${d##*/}: $(cat $d/name)"; done
```

A device created at boot is owned by `root:video` with mode 0660. Your user can normally write to it through a session ACL, but if scrcpy says it can't open the device, check `ls -l /dev/video0` and `id`, and add yourself to the `video` group if needed (`sudo usermod -aG video $USER`, then log out and back in).

### Running alongside another virtual camera (e.g. Droidcam)

If you already have a `v4l2loopback` device for something else, you have two options.

**Share it (simplest, nothing to install).** If that device is `/dev/video0`, you don't need to do anything; the script uses it by default and the two programs just take turns using it (don't run both at once). If it's some other number, point the script there:

```bash
VIDEO_NR=5 android-webcam          # or: WEBCAM_DEV=/dev/video5 android-webcam
```

To make that permanent, add it to your shell config (`vim ~/.bashrc` or `~/.zshrc`):

```bash
export VIDEO_NR=5
```

**Add a second device instead**, if you'd rather keep them separate. With `v4l2loopback-utils` installed (`sudo pacman -S v4l2loopback-utils`), the script does this on its own with no setup: point `VIDEO_NR`/`WEBCAM_DEV` at an unused number and it creates that device on the running module the first time, then reuses it.

Without `v4l2loopback-utils`, add the second device at boot instead. Edit `/etc/modprobe.d/v4l2loopback.conf` with vim:

```bash
sudoedit /etc/modprobe.d/v4l2loopback.conf
```

```
# Two virtual cameras: keep the existing one (e.g. Droidcam) on video0,
# and add AndroidWebcam on video10 for this script.
options v4l2loopback devices=2 video_nr=0,10 \
        card_label="Droidcam,AndroidWebcam" exclusive_caps=1,1
```

Match the existing device's number and label to what's already in your config or to what `scrcpy` (or `v4l2-ctl --list-devices`) shows, then set `VIDEO_NR=10` for this script and reboot.

## Troubleshooting

| Problem | Fix |
|---|---|
| Script waits forever at "Searching for Android devices" | Run `adb devices`. If the phone is `unauthorized`, accept the prompt on the phone. If it isn't listed at all, try another cable or port. |
| `modprobe: FATAL: Module v4l2loopback not found` | The module isn't built for your running kernel. Install the matching headers package, run `sudo dkms autoinstall`, or reboot after a kernel update. |
| `Key was rejected by service` when loading the module | Secure Boot is blocking the unsigned module. Disable it or sign the module. |
| `Couldn't parse any cameras` | Run `scrcpy -s <serial> --list-camera-sizes` and check the output. The script expects lines like `--camera-id=0    (back, 4000x3000, fps=[15, 30, 60])` followed by ` - 1920x1080` size lines. |
| `No 1080p/720p listed; letting scrcpy pick defaults` | The camera's size list couldn't be read or has neither size. Check `scrcpy -s <serial> --list-camera-sizes`; scrcpy then falls back to its own default size and 30 fps. |
| `Camera options are only available with --video-source=camera` | Use the latest `webcam.sh`; an earlier version dropped that flag from the launch command. |
| `unknown option` from scrcpy | Your scrcpy is too old. `--video-source=camera` needs 2.2+, and `--no-playback` / `--video-buffer` are 3.x names. |
| scrcpy errors right after "Launching" | The phone may not support 60 fps at 1080p on that camera even though it lists 60 fps. Edit the script to use `--camera-fps=30` for that phone. |
| App doesn't list the camera | Make sure the stream is running and `exclusive_caps=1` is set. If you changed module options, unload with `sudo modprobe -r v4l2loopback` (close apps using the camera first) and reload it with the new options (or reboot if it loads at boot); the script never reloads a module that is already loaded. |
| App doesn't list "AndroidMic" | Check `pactl list short sources \| grep AndroidMic`. If it's missing, confirm `pactl info` works (PipeWire running) and that `VIRTUAL_MIC` isn't set to `off`. Some apps hide audio devices until you open their settings while the stream is running. |
| I can still hear the phone's mic through my speakers | The stream wasn't moved to `AndroidMic` in time, likely because something else started playing audio at the same moment the phone connected. Stop and re-run; if it keeps happening, check `pactl list sink-inputs` while it's running to see what's attached to the default sink. |
| Audio is silent in the app I'm using | Confirm the app's input device is set to `AndroidMic`, not your physical mic. Check the level with `pavucontrol` (Recording tab) while the phone is making sound. |
| `ERROR: Failed to open output device: /dev/video0` | scrcpy can't write to the virtual camera. The script checks that the target device exists and is writable by your user; if not, it says what's wrong and prints diagnostics (all video device names, the target's permissions and ACL, your groups, which processes have it open). It never reloads a module that is already loaded. Common causes: your user can't write to the device (see the permissions note above); another program (OBS, a browser, a leftover scrcpy) has it open; or the module wasn't built for the running kernel (after a kernel change, install its headers and run `sudo dkms autoinstall`). |
| `Couldn't create /dev/video0 on the running v4l2loopback module` | The module is loaded for something else and the device the script wants doesn't exist yet. If `v4l2loopback-utils` is installed, the script creates it automatically (`v4l2loopback-ctl add`); if that still fails, or the package isn't installed, either point the script at your existing device instead (`VIDEO_NR=<N>`), or add a second device in your boot config and reboot (see above). |
| A blank scrcpy window appears | Older flag behavior. With scrcpy 4+, `--no-playback` still opens a window; the script picks `--no-window` automatically when your scrcpy supports it. |
| Frame rate stays at 30 | The script only sets `--camera-fps` when it can read the camera's supported rates from `scrcpy -s <serial> --list-camera-sizes`. scrcpy's default is 30 fps. |
| `modprobe -r` says the module is in use | A browser, OBS, or another app has the camera open. Close it first. |
| Stuttering or dropped frames | Use a direct USB port (no hub) and a good cable. Lower the bitrate or fps in the script. |
| Wrong lens | Run `scrcpy -s <serial> --list-camera-sizes` and edit the script to force a specific `--camera-id`. |

## Notes

- By default the phone's microphone is captured too (`AUDIO=mic`). `v4l2loopback` is video-only, so the audio doesn't go through the virtual camera; it's a separate audio stream, picked separately from the camera in whatever app you're using. Set `AUDIO=off` for video only, or `AUDIO=playback` to capture the phone's internal audio instead (Android 11+; apps can opt out, so it may not catch everything).

### Using the phone's mic as a real microphone

With `VIRTUAL_MIC=on` (the default), the script creates a virtual microphone called **AndroidMic** and routes the phone's audio into it instead of your speakers or headphones, so you won't hear it live, and other apps can select it as an input device the same way they'd select any other mic.

Requirements: PipeWire with `pipewire-pulse` (the default audio stack on current Arch; check with `pactl info`). Nothing else to install.

```bash
android-webcam                 # mic routed to the AndroidMic virtual device
AUDIO=off android-webcam       # camera only, no audio, no virtual mic
VIRTUAL_MIC=off android-webcam # mic plays through your normal speakers instead, as before
```

How it works:
1. The script creates a null sink named `AndroidMic` (audio goes in, nothing plays out loud) and a matching source of the same name, so it shows up as a normal microphone rather than a hidden "monitor". This only happens once; later runs reuse it.
2. Each time scrcpy starts, the script watches for its new audio stream and moves it onto `AndroidMic` as soon as it appears, usually within a second.
3. In your other app (Discord, OBS, a browser's mic picker, `pavucontrol`), select **AndroidMic** as the input device.

Notes and caveats:
- The script matches scrcpy's stream by recognizing it's the one that just appeared, not by its name, since scrcpy doesn't label it distinctly. If something else happens to start playing audio in that same instant, the wrong stream could get moved. This is rare in practice; if it happens, re-run the script.
- The virtual devices persist after the script exits, so `AndroidMic` stays selectable (silent) until you log out or run `pactl unload-module module-null-sink` (and `module-remap-source`) to remove them.
- If `pactl` isn't found, the script says so and falls back to playing the audio through your normal output, same as `VIRTUAL_MIC=off`.
- The phone screen isn't mirrored (`--no-playback` disables the local scrcpy window as well). The phone can stay locked, but some phones throttle the camera when the screen is off. If the picture freezes, keep the screen on.
- Keep the phone cool and plugged in. Running the camera at 1080p60 drains and heats it quickly.
