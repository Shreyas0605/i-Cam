# PortraitCam

A native iPhone camera app (Swift + SwiftUI + Vision + Core Image + Metal) that
applies a **real-time, DSLR-style portrait blur at any zoom level** — including
digital zoom — directly in the live preview. What you see is what you capture:
no post-processing, no waiting.

- Bundle identifier: `com.test.portraitcam`
- Deployment target: iOS 15.0 (iPhone), portrait
- No third-party dependencies (all Apple system frameworks)

## Why this works where native Portrait mode doesn't

Apple's Portrait mode relies on the hardware **depth sensor**, which is why it's
restricted to certain lenses and focal lengths. PortraitCam instead runs Apple's
Vision **person segmentation** (`VNGeneratePersonSegmentationRequest`) on every
frame. Because it segments the *image* rather than depth data, the effect works
identically at 1×, 2×, 5×, 10×, and any digital zoom.

### Per-frame pipeline

1. `AVCaptureVideoDataOutput` delivers each camera frame (BGRA, already rotated
   to portrait).
2. Vision produces a person mask for that frame.
3. Core Image composites the **sharp subject over a gaussian-blurred background**
   using the mask (`CIBlendWithMask`), with the background clamped so edges don't
   darken.
4. The composite is rendered live to a `MTKView` (Metal) via `CIContext`.
5. **Shutter** saves the exact on-screen composite → capture matches preview.
6. **Video** feeds the same processed frames through `AVAssetWriter` (with audio).

## Controls

- **Pinch or 1× / 2× / 5× pills** — zoom (digital zoom off the main wide lens).
- **Aperture slider** — background blur strength.
- **Quality menu** (Fast / Balanced / Accurate) — Vision segmentation quality;
  Accurate gives the cleanest hair/edges but costs the most per frame.
- **Photo / Video** toggle, shutter, front/back camera flip.

## Project layout

```
PortraitCam/
├─ .github/workflows/build-ipa.yml   # CI: build + package unsigned IPA
├─ PortraitCam.xcodeproj/            # project, shared scheme, workspace
└─ PortraitCam/
   ├─ PortraitCamApp.swift           # @main entry point
   ├─ ContentView.swift             # SwiftUI camera UI
   ├─ CameraController.swift        # capture session, zoom, photo + video
   ├─ FrameProcessor.swift          # Vision segmentation + CI compositing
   ├─ MetalCameraView.swift         # Metal renderer for CIImage frames
   ├─ CameraPreview.swift           # SwiftUI ⇄ MTKView bridge
   ├─ Info.plist                    # camera/mic/photo usage strings
   └─ Assets.xcassets/              # app icon + accent color
```

## Build the unsigned IPA (GitHub Actions)

1. Create a repo on your GitHub account and push the contents of this folder to
   the repo **root** (so `.github/` and `PortraitCam.xcodeproj` are top-level).
2. It runs on push to `main`, or run it manually:
   **Actions → Build Unsigned IPA → Run workflow**.
3. Download the artifact **`PortraitCam-unsigned-ipa`** and unzip to get
   `PortraitCam.ipa`.

The build uses `CODE_SIGNING_ALLOWED=NO`, so the `.ipa` is **unsigned** —
Sideloadly signs it for you.

## Sign and install with Sideloadly

1. Install [Sideloadly](https://sideloadly.io/) and connect your iPhone.
2. Drag `PortraitCam.ipa` in, enter your Apple ID (free account is fine), start.
3. On the iPhone: **Settings → General → VPN & Device Management** → trust your
   developer profile, then launch.
4. On first launch, allow **Camera** (and **Microphone** for video). Saving a
   shot prompts for **Add to Photos**.

> Free Apple accounts sign for 7 days; re-run Sideloadly to renew.

## v1 scope (deliberate, and where to go next)

- **Main wide lens + digital zoom.** 1× = the main lens, so labels are intuitive.
  *Next:* use the virtual multi-cam device so 2×/5× switch to the optical tele
  lens automatically for sharper high-zoom quality.
- **Capture at preview resolution (1080p)** so capture is instant and matches the
  preview exactly. *Next:* re-run segmentation on a full-resolution still at
  shutter time for higher-megapixel output.
- **Segmentation runs per frame at the chosen quality.** On older devices,
  `Fast` keeps the preview smoothest; `Accurate` is best for hair detail.

## Note on performance

Per-frame Vision segmentation + Core Image + Metal is real work. On recent
devices it runs smoothly at 1080p; on older hardware the preview may drop frames
(late frames are discarded to stay responsive). Start on **Balanced**.
