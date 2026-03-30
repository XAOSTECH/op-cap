
## [0.1.0] - 2026-03-30 (re-release)

### Added
- add sobs/cobs host aliases and Makefile targets

### Fixed
- fix(readme)

### Changed
- chore(dc-init): load workflows,actions
- Improve --no-device isolation and preserve OBS settings
- chore(dc-init): update workflows,actions
- Harden --no-device mode with process-level isolation
- chore: update CHANGELOG for v0.1.0
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

