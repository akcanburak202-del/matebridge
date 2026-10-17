# obs-cam-probe (T-351, decision 0040)

Standalone probe: can another process feed frames into the OBS Studio camera
extension's sink stream (CoreMediaIO)? No dependencies, no windows, never
requests camera access (it only talks to the CMIO sink).

```bash
cd tools/obs-cam-probe && swift build -c release
.build/release/obs-cam-probe --list
.build/release/obs-cam-probe --pattern --seconds 60            # 1920x1080 @ 30
.build/release/obs-cam-probe --pattern --size 1280x720 --fps 30
```

Notes: the OBS extension's stream format is fixed at 1920x1080 BGRA 30 fps
(OBS 32.2.2), so that is the default; other sizes are for experiments.
Device UUID is read from the installed OBS plug-in Info.plist
(`OBSCameraDeviceUUID`); fallback is matching the name "OBS Virtual Camera".
Visual check: the user opens FaceTime/Photo Booth and selects
"OBS Virtual Camera" while the probe runs; with OBS open and closed.
