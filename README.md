# Tetherview

**Use your iPhone as a full-screen, landscape monitor for a Fujifilm X camera, with just a USB-C cable.**
There's no Fujifilm app, no capture card, no computer and nothing to buy.

> Status: **experimental (v0.1).** The protocol logic is unit-tested against a simulated camera. It has **not yet been confirmed on a real X-T50.**
> If you try it, please open an issue and include the in-app connection log (Log › Copy).

## Why this exists

- iPhones don't give apps access to USB webcams (UVC). That's why the X-T50's webcam mode shows nothing in "USB camera" apps on iPhone.
- iPhones *do* let apps talk **PTP** to a camera plugged into USB-C. PTP is the protocol cameras use for tethered shooting.
- In tether mode, Fujifilm bodies stream live-view JPEG frames over PTP. Tetherview fetches those frames and shows them full-screen in landscape.

## Features

- Landscape-only, full-screen live view that fits a landscape phone mount.
- Rule-of-thirds grid, flip 180° (for upside-down mounting), mirror.
- Pinch to zoom, and double-tap for 3× to check focus.
- Keeps the screen awake while it's open.
- A connection log you can copy and paste into bug reports.

## Camera setup (X-T50 and other recent X bodies)

1. **MENU › NETWORK/USB SETTING › USB SETTING › USB TETHER SHOOTING AUTO.** On some bodies the menu path is *CONNECTION SETTING › PC CONNECTION MODE*.
2. Plug the camera into the iPhone with a USB-C cable **that carries data**, such as the one that came with the camera.
3. Open Tetherview and allow access if iOS asks.

### "Allow the app to take control?"

Tetherview first tries to stream **without** taking control, so the camera's dials and buttons keep working.
Some bodies only stream once the app takes control ("PC priority"). While that's on, the camera's dials and buttons are locked; the lens focus ring still works.
Tetherview asks before doing this, and it hands control back when you unplug or leave the app.
If a camera ever stays locked, turn it off and on.

### First connection is slow?

iOS may hold the first command for up to about a minute while it indexes the camera. This happens only once per plug-in.

## Install on your iPhone (no Mac needed)

GitHub builds the app for you, and you install it from a Windows or Mac computer with a free Apple ID.

1. **Get the .ipa.** Fork this repo, or push it to your own GitHub. The **Build** workflow runs automatically.
   Open the **Actions** tab, then the latest run, and download **Tetherview-ipa** under Artifacts. Unzip it to get `Tetherview.ipa`.
   Tagged releases (`v0.1.0` and so on) also attach the .ipa to the GitHub release.
2. **Install [Sideloadly](https://sideloadly.io)** on Windows or Mac.
   On Windows, also install iTunes and iCloud from Apple's website (not the Microsoft Store versions).
3. Connect the iPhone to the computer, drag `Tetherview.ipa` into Sideloadly, enter your Apple ID and press **Start**.
4. **On the iPhone:**
   - Turn on **Settings › Privacy & Security › Developer Mode** and restart when prompted.
   - Trust your Apple ID under **Settings › General › VPN & Device Management**.

With a free Apple ID, the app has to be re-signed every 7 days (just run Sideloadly again). Sideloadly's auto-refresh can do this for you.
A paid Apple Developer account removes that limit.

Building with Xcode on a Mac also works: `brew install xcodegen && xcodegen generate && open Tetherview.xcodeproj`.

## How it works

```
iPhone (ImageCaptureCore)                       Camera (USB tether mode)
  GetDeviceInfo                      ───────▶   model, supported operations
  InitiateOpenCapture(0,0)           ───────▶   start live view
  loop:
    GetObjectHandles(0x10000002)     ───────▶   preview frames waiting
    GetObject(newest)                ◀───────   JPEG
    DeleteObject(each)               ───────▶   free the buffer
  TerminateOpenCapture(0)            ───────▶   stop
  SetDevicePropValue(0xD207 = 1)     ───────▶   hand control back (only if taken)
```

- `Sources/TetherviewCore/` is pure Swift: PTP containers, DeviceInfo parsing and the Fujifilm live-view loop. It's unit-tested with `swift test`, which runs on macOS or Linux.
- `App/` is the iPhone app: an ImageCaptureCore transport and a SwiftUI monitor.

## Contributing

The most useful contribution right now is **a test report from a real camera**. Include the model, firmware, the iOS version and the copied log.
Other good first issues:

- A frame-rate / quality setting (live-view size prop `0xD174`)
- Focus peaking and zebras, computed on-device from the JPEG
- Live histogram (Fujifilm exposes it as the `0xD22F` blob property)
- Wi-Fi mode (needs the Bluetooth pairing handshake worked out)

## Credits

- Fujifilm USB live-view sequence and property codes: documented by [mikefsq/ptp](https://github.com/mikefsq/ptp) (MIT), tested on an X-T5.
- Fujifilm PTP research: [fudge / camlib](https://codeberg.org/p/fudge) by Daniel C., and [fuji-cam-wifi-tool](https://github.com/hkr/fuji-cam-wifi-tool).
- iOS ImageCaptureCore field notes: [che / nikon_ptp_flutter](https://github.com/Rabbit95/che).

No code was copied from GPL projects. This project re-implements the documented behaviour.

Not affiliated with or endorsed by FUJIFILM Corporation. "Fujifilm" and "X-T50" are trademarks of their owners and are used only to describe compatibility.

## License

MIT. See [LICENSE](LICENSE).
