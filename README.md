# ykcam

A personal iPhone app that turns a spare iPhone into a local door camera. Everything stays on the phone: there is no server, account or network code.

- **Intrusion:** when the chosen door area changes, it takes photos and records video with sound.
- **Picked up:** it takes photos with both cameras, starts recording from the front camera and saves the front photos to Photos right away.
- **Carried away:** if the motion sensors show the phone is still being carried, it sounds an alarm, speaks a warning and saves each 30-second clip to Photos.
- **Owner only:** stopping the alarm, stopping monitoring and viewing records need Face ID or the device passcode.

Built with SwiftUI and XcodeGen for iOS 17+. The UI is in Chinese. It is distributed through TestFlight for personal use and is not on the App Store.

## Building

`xcodegen generate`, then open `YKCam.xcodeproj`. Pushes to `feature/**` run an unsigned simulator build and the unit tests.

`Upload to TestFlight` is started by hand on `main` by the repository owner. Signing material is kept in a separate private repository; the key, password and certificate id are GitHub secrets and are never stored here.
