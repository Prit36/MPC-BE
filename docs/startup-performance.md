# Video-open performance investigation

These changes target opening an actual video in a fresh MPC-BE process. They do
not introduce a resident process, background-ready mode, or a renderer change.
Closing the player terminates it normally.

## Measurement and result

Measured on the development machine (RTX 5060, MPC Video Renderer in D3D11 mode,
MPC Video Decoder with D3D11 native decoding) with an H.264 MP4. Each build was
launched 15 times, interleaved, on a hidden desktop (see Reproduction). Times are
medians from `CreateProcess`, so they include process loading.

| Build | First decoded sample | First frame presented |
| --- | ---: | ---: |
| Installed release (Sep 1) | — | ≈317 ms ¹ |
| Start of the second optimization pass | 266 ms | 267.7 ms |
| Current Release x64 | 238.0 ms | 239.5 ms |

¹ The old build only traces from its application constructor (301.9 ms to first
decoder delivery); about 15 ms of process start is added for comparison.

"First frame presented" is the first `IDXGISwapChain::Present`/`Present1` after
the first decoded sample, recorded by a trace-only hook (see Tracing). It is the
moment the renderer hands the frame to the compositor, not a photon measurement.

Each benchmark invocation discards one preliminary run. Interleaving builds
reduces cache and load bias, but GPU contention still affects results. These
are fresh processes with warm OS caches, not cold-boot measurements. Local CSVs
and traces are under the ignored `_bin/startup-analysis/` directory
(`s2-final-ab` for the table above).

Launching a file by double-click uses whatever is installed under
`C:\Program Files\MPC-BE`; the numbers above apply only once the new build is
installed there.

## Where the time goes now

| Stage | Approximate cost |
| --- | ---: |
| Process start to first CRT initializer | 12 ms |
| First D3D11 device in the process (GPU driver load) | 150–160 ms |
| MPC Video Renderer construction, D3D11 activation, window positioning | 40 ms |
| Decode and present of the first frame | 15 ms |

Everything else (window creation, graph building, splitter, audio) now runs in
parallel with the driver load. The driver load is the floor for a fresh process:
any further large gain needs a process that is already running, which was
rejected.

## Changes retained

### Second pass

- **Early driver warmup.** A `.CRT$XCB` initializer starts the D3D11 driver
  warmup thread about 12 ms after launch, before the application object and the
  other static initializers. It only starts when the case is unambiguous: a file
  argument, settings in the registry (no `.ini`), MPC Video Renderer with D3D11,
  and no running player that would receive the file. `InitInstance` covers the
  other cases as before.
- **Device handoff to the decoder.** The warmup device is created with the
  D3D11 decoder's adapter and flags and handed over through
  `CD3D11DeviceHandoff` (`src/DSUtil/D3D11DeviceHandoff.h`). The decoder takes it
  if the adapter LUID and creation flags match, instead of creating its own
  device on the critical path (about 11 ms). An unused device is released when
  the file opens or the player exits. Debug builds keep creating their own device
  so the debug layer stays available.
- **Hardware decoder prewarm (NVIDIA only).** The first video decoder on a
  device costs about 17 ms (creation plus the first `DecoderBeginFrame`); later
  decoders of any codec cost about 2 ms. The warmup thread runs a 256×256 H.264
  (or HEVC) decoder once on the handed-over device (about 9 ms saved). Other
  vendors were not measured and are skipped.
- **No window open animation for file launches.** The DWM open transition is
  disabled while a file launch shows the window and re-enabled once the file
  opens. This cannot be measured on a hidden desktop, but it removes the
  animation that hides the first frame on the real desktop.

### First pass

- Replace synchronous file writes at every startup checkpoint with opt-in,
  bounded in-memory tracing. Normal launches do not create a performance log.
- Avoid enumerating all audio-renderer devices just to determine the selected
  output's filter merit.
- Avoid constructing the Logitech LCD SDK when LCD support is disabled.
- Defer logo decoding for video launches; recover the logo for audio-only,
  failed, and closed-media views.
- Start the graph worker during control construction.
- Begin asynchronous MPC Video Renderer media opening before showing the frame.
- Create dockable bars lazily and defer disk checks.
- Label sample-delivery tracing accurately and include native DXVA2 delivery.

## Tried and reverted

- Positioning the renderer window before the graph connects (to take
  `SetWindowPosition` off the critical path) made things worse (273 ms vs 255 ms):
  the renderer holds its lock during resize and blocks the stream.
- Creating the real renderer early contended with the driver load.
- EVR, EVR Custom Presenter, and the newer bundled MPC Video Renderer were not
  faster defaults.
- A background-ready resident process was removed at the user's request.

## Known limits

- An audio-only file launched with MPC Video Renderer still runs the warmup on a
  worker thread; the unused device is released when the file opens.
- MPC Video Renderer allows one instance per process and creates its own D3D11
  device; that device benefits from the already-loaded driver (about 15 ms
  instead of about 150 ms) but cannot be shared from outside the renderer.

## Reproduction

Build Release x64 using the repository's normal dependencies, then run the
hidden-desktop benchmark. It creates a separate Win32 desktop, so no window
appears on screen:

```powershell
./contrib/benchmark-hidden-desktop.ps1 `
    -Executable _bin/mpc-be_x64/mpc-be64.exe,C:/path/to/other.exe `
    -Media C:/path/to/video.mp4 `
    -Runs 15 `
    -OutputDirectory _bin/startup-analysis/my-test
```

Several executables are interleaved. An entry may carry environment variables
for that variant (`mpc-be64.exe?NAME=1&OTHER=1`). `-LegacyLogPath` collects the
fixed-path log written by old builds; their times are then constructor-relative.

`contrib/benchmark-startup.ps1` is the older harness. It shows real windows on
the current desktop.

## Tracing

Set `MPCBE_STARTUP_TRACE` to an absolute output filename before launching the
player. The bounded trace is written once on normal exit and records the QPC
origin, so harnesses can convert times to launch-relative. Only when tracing is
on, a Detours hook on the swap chain's `Present`/`Present1` records the first
presented frame. Unset the variable for normal use.

`contrib/test-startup-trace.cpp` checks concurrent one-time markers, copied stage
names, the record limit, deferred file creation, idempotent flushing, and
disabled tracing.
