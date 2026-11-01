# RelayAEC

Relay's local C bridge to WebRTC Audio Processing 2.1 (AEC3), distributed as a
static macOS XCFramework for arm64 and x86_64. The SwiftPM product and module are
both `RelayAEC`. The Swift wrapper reexports the C declarations and links libc++,
Foundation and CoreFoundation.

The processor receives an explicit speaker reference and microphone signal in
memory. It does not record audio files, access the network or upload samples.
Audio-processing debug dumps are disabled in the selected upstream build.

## Configuration and ownership

The bridge enables AEC3 and the high-pass filter. Both automatic gain controllers
and noise suppression are disabled. One caller-owned serial queue must perform
all operations on a handle, including reset and destruction.

`Bridge/RelayAEC.h` defines the C ABI. Samples are mono normalized Float32,
exactly 10 ms per call, at 16, 32 or 48 kHz. Reverse frames precede capture frames
containing their acoustic echo. Capture processing receives the measured
render/capture buffer delay in milliseconds, from 0 through 500. The adaptive
processor estimates the acoustic path; the application's intentional hold time
is separate from that path. The API returns zero on success, a negative WebRTC
processing error, `-10000` for invalid arguments or `-10001` for unexpected C++
failure. No C++ exceptions cross the ABI.

Acoustic integration checks must cover speaker playback, simultaneous microphone
speech, pause/resume and source changes. Synthetic convergence alone does not
establish suppression or near-end speech quality in a particular room, route or
speaker configuration. The processor has filter delay; callers must account for
it when comparing waveform alignment.

The same pinned WebRTC sources also supply an independent classic voice activity
detector through `relay_vad_create`, `relay_vad_process`, `relay_vad_reset` and
`relay_vad_destroy`. It classifies 10 ms, 16 kHz mono Float32 frames as speech or
non-speech, converting to Int16 locally for the upstream detector. It returns
metadata only and never modifies, filters or removes input audio. Each source
needs its own caller-serialized handle. Modes 0 through 3 are supported; more
restrictive modes can miss quiet speech. A negative result is an error, not
silence. Reset clears its history and retains the selected mode. The detector
does not share state with AEC3 or introduce another dependency.

## Source and licenses

`Vendor/Archives` contains the unmodified upstream source archives, including
Abseil and its Meson build overlay. `Vendor/SourceManifest.json` records their
official download URLs, byte sizes and SHA-256 checksums. No remote SwiftPM
dependency is required to consume this package.

`Third-Party Notices.txt` contains the complete selected upstream license and
patent notices for inclusion in the app distribution. Individual copies are in
`Licenses`. WebRTC/APM and its bundled DSP components have permissive notices;
Abseil is Apache-2.0. The Google WebRTC patent grant is included separately.

## Rebuilding

Use Xcode 26 or newer, Python 3.12 or newer, Meson 1.9.0 and Ninja 1.13.0 on
macOS. Install the Python build tools into a disposable environment outside the
Relay project using the hash-pinned requirements, for example:

```sh
python3 -m venv '/path/outside/Relay/aec-tools'
'/path/outside/Relay/aec-tools/bin/python' -m pip install --require-hashes \
  -r Scripts/ToolRequirements.txt
python3 Scripts/build-xcframework.py \
  --work-dir '/path/outside/Relay/aec-build' \
  --meson '/path/outside/Relay/aec-tools/bin/meson' \
  --ninja '/path/outside/Relay/aec-tools/bin/ninja'
```

The build directory must not already exist and must be outside the Relay project.
The script verifies all source hashes, uses only the vendored sources, builds
static APM and Abseil for both architectures, compiles the bridge, folds the
transitive archives into a universal library and creates a new XCFramework there.
It does not modify the packaged binary. Review the rebuilt artifact before
replacing `RelayAEC.xcframework`. Builds retain their logs in the chosen work
directory; no build caches, extracted trees or object files are stored in this
package. The process is reproducible from pinned inputs, without asserting
byte-for-byte identity across Xcode or SDK versions.
