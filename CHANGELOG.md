
## [0.1.2] - 2026-10-05

### Fixed
- threshold and proper restart on capture loss
- kill and restart OBS on capture source loss
- reliable disconnect detection and USB reset
- use stored best format FourCC in --no-loopback scene patch
- auto-install all required packages, never prompt the user
- handle reconnects in --no-loopback mode

### Changed
- Merge pull request #2 from XAOSTECH:anglicise/20261001-034544

## [0.1.1] - 2026-09-28

### Added
- route capture card audio through FFmpeg for A/V sync
- MJPG decode+re-encode for native MJPEG in loopback; fix loopback format wait poll
- MJPG native pass-through to loopback
- include MJPG so 4K@60fps is selected over NV12@30fps
- integrate deps and driver optimisation into make install; fix DKMS visibility; fix scene device path
- apply --safe-mode and --disable-missing-files-check on every launch
- auto-run make deps when v4l2loopback module is missing on install
- pre-build hide_v4l2.so and improve build verbosity

### Fixed
- release stale device holder in --no-loopback mode
- block physical device fallback in loopback mode
- revert queue to 8, remove broken timeout image, adjust audio delay
- reduce A/V offset, stop reset spam, hold frame on restart
- discard corrupt MJPEG packets, restart inline on freeze
- replace D-state freeze check with write_bytes stall detection
- audio setup for all feed paths, clean supervise_feed shutdown, freeze detection
- use module-virtual-source instead of null-sink monitor
- unload virtual sink on exit, auto-configure OBS audio profile
- suppress pactl module ID output; add 1s settle before OBS audio enumeration
- add pulseaudio-utils to deps; split audio routing condition with explicit warnings
- add audio source diagnostic log; add 1s framerate settle
- derive audio source from USB serial, no pactl needed
- fix pactl failing under sudo by passing XDG_RUNTIME_DIR; add runtime audio detection fallback
- stop loopback service in --no-loopback mode, restore on exit
- use exclusive_caps=0 for v4l2loopback service to prevent format-change EBUSY
- set yuvj422p chroma on MJPEG re-encode to fix BGR3/emulated artefacts
- re-patch scene device on every loopback launch, wait for loopback format
- revert MJPG passthrough, restore NV12 decode pipeline with -r fps With MJPG passthrough, malformed compressed frames hit OBS's avcodec decoder directly. avcodec_send_packet returns a hard error; OBS's v4l2 source treats this as permanent and stops retrying, breaking the recovery cycle. With the NV12 decode pipeline, FFmpeg's internal MJPEG decoder absorbs the corrupted input using error concealment and still produces valid raw pixel output. OBS reading NV12 from the loopback has no decode step at all, so a hard codec failure is not possible - it just renders whatever pixels arrive and handles timeouts cleanly when the writer is absent.
- lock loopback framerate via v4l2loopback-ctl to suppress 1000fps quirk
- declare loopback framerate for 60fps, fix scene patch under double-sudo
- patch scene to loopback device, restart service after config change
- stop spurious supervisor restarts after shutdown
- exclude loopback from device picker, remove stale modprobe check, fix unbound var
- use --list-formats filter and patch OBS scene on install
- point to make deps when v4l2loopback is missing
- fall back to direct device mode when v4l2loopback unavailable
- detect snap-confined OBS and warn shim is ineffective
- filter device picker to capture-only nodes
- mark script executable
- remove uvcdynctrl, filter cobs to capture-only nodes
- remove config isolation, use pre-built shim, add --disable-missing-files-check
- v4l2loopback DKMS rebuild, restart after stuck OBS, safe-mode on recovery

### Changed
- refactor(install,obs-safe-launch,Makefile): replace Python JSON scene patching with jq
- revert(feed): remove explicit pix_fmt from MJPEG re-encode
- revert(obs-safe-launch): remove v4l2loopback-ctl set-fps calls
- refactor(obs-safe-launch): embed safe flags in run_obs, fix feed device-busy, clean up log messages
- build(scripts): update usbreset binary from local make build

## [0.1.0] - 2026-03-06

### Added
- LD_PRELOAD shim to fix V4L2 loopback HDR colorspace

### Fixed
- fix(readme)
- scan for loopback device instead of assuming video_nr
- preserve NV12 and propagate HDR metadata through loopback

### Changed
- chore(dc-init): update workflows and actions
- Fix crash recovery limit logic: default unlimited, non-cumulative
- Remove unnecessary sudo from kill in cleanup
- Add sudoers rule for passwordless crash recovery
- Fix: handle crash recovery with proper error handling
- Update: document safety launcher with latest crash recovery features
- Fix: disable set -e for OBS execution to allow crash recovery
- Add explicit debug logging for crash recovery troubleshooting
- Fix recovery timeout and stream state detection
- Fix auto-resume to only restart stream after crash, not on first launch
- Add automatic stream resumption after crash recovery > > - Add --auto-stream flag to manually enable streaming on launch > - Detect streaming state before crash by monitoring OBS logs > - Auto-inject --startstreaming flag when restarting after crash > - Preserve STREAM_STATE_FILE across crash recovery cycles > - Resume streaming automatically if OBS was streaming before crash
- obs-safe-launch: add --no-device for manual OBS config without device requirement
- obs-safe-launch: add direct-device mode without loopback
- dc-init

### Documentation
- add P010 HDR format support details and accuracy data

