# Tater-Net

Online co-op for [Brotato](https://store.steampowered.com/app/1942280/Brotato/) over Steam, for up to 4 players (Mac and PC).

- **Host-authoritative:** the host runs Brotato's own local co-op; remote friends join as virtual gamepads and see a live mirror of the host's screen, rebuilt from their own copy of the game's sprites, fonts and sounds.
- **Per-player achievements:** at the end of a run each player's own game records their character's result and unlocks achievements on their own Steam account.
- **Separate saves:** while hosting, the single-player run is parked and an online run slot is used; it is restored on leaving (or on next launch after a crash).

Written in GDScript for Godot 3 and loaded by [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader).

## Layout

```
mods-unpacked/TaterNet-OnlineCoop/
  manifest.json            mod info for the mod loader
  mod_main.gd              entry point: script extensions, crash recovery for saves
  core/online_coop.gd      Steam lobby, P2P transport, host and client logic, achievements
  core/mirror_capture.gd   host: encodes the screen into compact snapshots
  core/save_slots.gd       single-player / online run file swapping
  core/protocol.gd         shared constants
  client/mirror_view.gd    client: draws the host's screen, sends input
  ui/online_menu.gd        host / invite / join panel
  extensions/              hooks into game scripts (movement, sounds, main menu)
tests/netsim.py            timing and network simulator
```

## Install for testing

Zip the `mods-unpacked` folder so the zip contains `mods-unpacked/TaterNet-OnlineCoop/...`, name it `TaterNet-OnlineCoop.zip`, and put it in a `mods` folder inside the Brotato install folder.

```bash
zip -r TaterNet-OnlineCoop.zip mods-unpacked
```

Logs: `%APPDATA%\Brotato\logs\modloader.log` (Windows), `~/Library/Application Support/Brotato/logs/modloader.log` (Mac).

## Simulator

`tests/netsim.py` re-implements the mod's input sampling, host input handling and snapshot chunking, and runs them against Mac and Windows frame-rate profiles (120 Hz ProMotion, 60 Hz, 144 Hz, uncapped, stuttering low-end PCs) and network conditions (LAN to bad Wi-Fi, with lag, jitter, loss and reordering). It tests the mod's logic, not Brotato or Godot. Needs Python 3, no packages.

```bash
python3 tests/netsim.py          # current protocol; exits 1 if any scenario fails
python3 tests/netsim.py --v1     # also run the original (0.1.0) input protocol for comparison
```

Current results: 0 missed or extra button presses across 72 client/host/network combinations (0.1.0 missed about 12% of quick taps); screen updates arrive 100% on a normal connection, 99% far away, 84% on bad Wi-Fi.

## Status

Not yet tested in-game. Expect fixes after the first real sessions.
