# HAP Player

An unofficial Mac app for the **Sony HAP-Z1ES** HDD audio player: browse your music, play it,
copy music to the player and tidy up its drive. Made because Sony's own apps (HAP Music
Transfer, HDD Audio Remote) no longer get updates.

Not made, endorsed or supported by Sony. Sony, HAP-Z1ES and other names are trademarks of their
owners.

## What it does

- **Browse** albums (with covers), artists, genres, tracks, and the player's folders; search.
- **Covers** for albums the player has none for: the picture from the album's folder on your
  Mac (cover.jpg, folder.jpg, …) when you copy it, otherwise looked up online by itself after
  each library refresh (or with **Find Missing Covers**). Shown in the app only.
- **Play** on the player: play/pause, next/previous, jump within a track, play whole albums,
  folders and playlists (the app plays them song by song), shuffle and repeat.
- **Playlists** of your own, kept on the Mac: hand-picked, or automatic (by year, quality,
  plays, newest additions, genres, artists). Export as .m3u.
- **Copy music** to the player by drag and drop, checked file by file.
- **Albums in one file + .cue** (FLAC or WAV) are split into one FLAC per song, losslessly,
  checked sample by sample before copying, with tags from the .cue and the album's cover built
  in. Albums like this already on the player can be split there too.
- **Delete** songs, albums or folders from the player (asks first), and **tidy up** the hidden
  files a Mac leaves behind.
- **Artists** with "feat." guests appear on the guest's page too; spelling variants are merged.
- A **hi-fi rack look**: a big blue "screen" in a silver player front, with an amplifier below
  whose buttons switch sections. The dial skips tracks; the volume knob scrolls the screen.

## Tested with

- HAP-Z1ES, firmware 19404R, on macOS 26 (Apple silicon).
- **HAP-S1: untested** (it uses the same software, so it may work). Reports welcome.

## Setup

1. **Network:** the player and the Mac must be on the same network (a cable straight from the
   player to the Mac with Internet Sharing also works).
2. **Drive setting (needed for copying and deleting).** The player's file sharing only works
   reliably with the old SMB1 protocol; newer versions hang or lose data when writing. Open
   Terminal and paste this (it adds a setting for the player only; replace `HAP-Z1ES` with the
   player's name if you renamed it):

   ```bash
   cat >> ~/Library/Preferences/nsmb.conf <<'EOF'
   [HAP-Z1ES]
   protocol_vers_map=1
   soft=yes
   EOF
   ```

   If the app reaches the player by its address instead, add the same three lines once more
   with `[192.168.x.y]` (the address shown at the bottom of the app) instead of `[HAP-Z1ES]`.
   See `docs/nsmb.conf.example`.
3. **Install:** download `HAP.zip` from the Releases page, unzip it, and move **HAP** to
   Applications.
4. **First start:** the app isn't signed by Apple yet, so macOS warns about an "unidentified
   developer". **Right-click HAP → Open → Open** (only the first time). If macOS says the app
   is damaged, run `xattr -dr com.apple.quarantine /Applications/HAP.app` in Terminal.
5. Allow **Local Network** access when asked (the app needs it to find the player).

## Good to know

- **Deleting is permanent.** The player has no Trash. The app asks before deleting and warns
  when the files aren't on your Mac.
- After copying, the player adds new music to its library by itself (seconds to minutes; some
  things only when it goes into standby). If a file shows a clock icon for a long time, copy it
  again under a slightly different name: the player ignores files it saw half-copied.
- Don't play music from an album while it's being copied.
- **Privacy:** the app talks to your player on your network. Covers it can't find on the player
  are looked up at the iTunes Search API, Deezer and MusicBrainz / Cover Art Archive (only the
  album or artist name is sent). Nothing else leaves your Mac.

## Build from source

Needs macOS 15+ and Xcode (or the Swift 6 toolchain).

```bash
cd App && ./make-app.sh            # builds App/build/HAP.app
cd App && ./make-app.sh --install  # and copies it to /Applications
swift test                         # in App/ or HAPKit/ (tests never contact a player)
```

- `HAPKit/` — a Swift package that talks to the player (discovery, JSON API, library, drive,
  uploads). Includes a small command-line tool: `swift run hap info`, `hap now`, `hap albums`…
- `App/` — the SwiftUI app.
- `PROTOCOL.md` — what is known about the player's network interface.

## Thanks

- **[HAP-Revival](https://github.com/Guillain-RDCDE/HAP-Revival)**, whose research into the
  player's API (including how Sony's app seeks within a track) made this possible.
- **[HAPxFer](https://github.com/danielrweber/HAPxFer)**, another Mac transfer tool for the HAP.

## Licence

MIT — see `LICENSE`. No warranty: use at your own risk, keep a backup of music that exists
only on the player.
