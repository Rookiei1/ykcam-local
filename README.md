# ykcam

A personal iPhone app that turns a spare iPhone into a door camera. It supports both local-only recording and connecting to a self-hosted `ykcam` server for push alerts, live video/audio streaming, and off-device event backup.

- **Intrusion:** when the chosen door area changes, it takes photos, records video with sound locally, and uploads them when paired with a server.
- **Picked up:** it takes photos with both cameras, starts front-camera video recording (saved locally and streamed in 4s segments when paired), and saves the front photos to Photos right away.
- **Carried away:** if the motion sensors show the phone is still being carried, it sends a high-priority theft alert (when paired), sounds an alarm, speaks a warning, and saves each 30-second clip to Photos.
- **Live view & audio:** when paired, the main viewer can watch live video, request snapshots, listen to live 16 kHz audio, and arm/disarm or update detection settings remotely.
- **Owner only:** stopping the alarm, stopping monitoring, managing pairing, and viewing local records need Face ID or the device passcode.

Built with SwiftUI and XcodeGen for iOS 17+. The UI is in Chinese. It is distributed through TestFlight for personal use and is not on the App Store.

## Building

`xcodegen generate`, then open `YKCam.xcodeproj`. Pushes to `feature/**` run an unsigned simulator build and the unit tests.

`Upload to TestFlight` is started by hand on `main` by the repository owner. Signing material and any default server address are kept as GitHub secrets and are never stored in this repository.
