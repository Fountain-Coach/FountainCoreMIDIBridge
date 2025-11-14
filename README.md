# FountainCoreMIDIBridge (Sidecar)

CoreMIDI/AudioKit-powered BLE/RTP MIDI 1.0 bridge for external hosts (e.g., AUM). Provides a tiny local HTTP surface so CoreMIDI stays out of the primary FountainKit repo.

Status: scaffold — HTTP control runs; wire AudioKit/MIDIKit in this repo after publish.

## Why
- Many hosts only accept MIDI 1.0 over BLE/RTP (AUM, DAWs). FountainKit is CoreMIDI-free by policy. This sidecar keeps CoreMIDI usage out of FountainKit by running separately.

## Protocol
- `GET /health` → 200 ok
- `POST /midi1/send` with JSON `{ "messages": [[int,...]] }`
  - Each message is a byte array like `[0x90, 60, 100]`
  - The sidecar forwards messages to the selected BLE Peripheral/RTP session (to be implemented with AudioKit/MIDIKit).

## Build (scaffold)
```
cd Sidecar/FountainCoreMIDIBridge
swift build -c release
BRIDGE_PORT=18090 .build/release/FountainCoreMIDIBridge
```

## AudioKit/MIDIKit integration (to be added here after publish)
- Add AudioKit and MIDIKit packages.
- Wire CoreMIDI BLE Peripheral/RTP session selection.
- Route messages from `/midi1/send` to the selected endpoint.

## Publish to GitHub (Fountain-Coach)
Ensure `gh` is logged into the org and you have repo create permissions.

```
cd Sidecar/FountainCoreMIDIBridge
git init
git add .
git commit -m "feat: scaffold FountainCoreMIDIBridge sidecar (HTTP control)"
# Create org repo
gh repo create Fountain-Coach/FountainCoreMIDIBridge --public --source=. --remote=origin --push
```

If you prefer HTTPS without gh:
```
# Create the repo in the org via Browser or REST, then:
git remote add origin https://github.com/Fountain-Coach/FountainCoreMIDIBridge.git
git push -u origin main
```

## Run with FountainKit
- Start sidecar:
```
BRIDGE_PORT=18090 /path/to/FountainCoreMIDIBridge
```
- In FountainKit’s MPE Pad app, choose `Sidecar` transport (default port 18090).

## License
MIT or org default (choose at repo creation).

