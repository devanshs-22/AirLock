# AirLock

<img src="docs/menu-bar.png" alt="AirLock in the macOS menu bar: an open padlock and a live heart rate of 90" width="110">

A macOS menu bar app that uses a **Google Fitbit Air** as a proximity key, like Apple Watch Auto Unlock, but for a $99 screenless band.

- **Locks the Mac when you walk away**: the band's signal gets weak, or it goes out of range.
- **Unlocks when you come back and touch the trackpad or a key**, but only if the band is close **and on your wrist**.
- **Locks when you take the band off**: off a wrist, the band keeps repeating its last heart-rate reading, so a frozen number means "not worn".
- **Sleeps the Mac** after you've been away for a while.
- **Shows your live heart rate** in the menu bar (`🔓 ♥ 72`).

Everything stays on your Mac. AirLock reads the band's standard Bluetooth heart-rate broadcast and never touches Google's encrypted channel or cloud.

## Requirements

- macOS 13 or later, with Xcode or the Command Line Tools (for `swiftc`)
- A Fitbit Air with **Share heart rate → Always visible** turned on in the Google Health app (this uses more band battery)

## Build and install

```bash
./build.sh
open ~/Applications/AirLock.app
```

`build.sh` signs with your Apple Development certificate if you have one. That keeps macOS permissions across rebuilds; without it, the app is signed ad hoc and Accessibility has to be re-granted after every build.

## First run

1. Allow Bluetooth when asked.
2. Padlock menu → **Save Mac Password…** The password is checked against your account, then stored in your login keychain.
3. Turn on AirLock in System Settings → Privacy & Security → **Accessibility**. AirLock unlocks by typing your password at the lock screen.
4. Run **Test: Lock Now**, then touch the trackpad.
5. Turn on **Open at Login**.

## Tuning

Signal strength is a negative number; closer to 0 means closer to the Mac. All of these are in the menu.

| Setting | Default | Closer to 0 / shorter | Further from 0 / longer |
|---|---|---|---|
| Lock when signal drops to | −64 | locks when you're only a step away; may lock while seated | must go further before it locks |
| Unlock when signal reaches | −58 | must be right at the Mac | unlocks from further away |
| Lock delay when signal drops | 5 s | locks faster, more false locks | fewer false locks |
| Lock when band goes silent for | 4 s | locks faster when out of range | survives Bluetooth hiccups |
| Off wrist after no change for | 75 s | notices removal sooner | fewer mistakes |
| Sleep Mac after away | 15 min | saves battery | faster unlock on return |

Keep the unlock level closer to 0 than the lock level. The decisions are logged to `~/Library/Logs/AirLock.log`.

## Limits

- After a restart or power-on, macOS (FileVault) always asks for the password.
- There's no secure handshake with the band, so this is meant for home use, not shared offices.
- If the band is removed from your phone, it forgets its pairing with the Mac. Fix: System Settings → Bluetooth → Google Fitbit Air ⓘ → **Forget This Device**, and AirLock re-pairs on its own.

## Tools

Small command-line helpers used while building this. Run them from a terminal that has Bluetooth permission.

```bash
cd tools
swiftc -swift-version 5 fitbit-scan.swift -o fitbit-scan -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
./fitbit-scan        # live heart rate, skin contact and signal strength
./fitbit-scan ids    # check whether the band's Bluetooth ID stays the same
```

`gatt-dump.swift` (built the same way) lists every Bluetooth service the band exposes.
