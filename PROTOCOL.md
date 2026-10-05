# The HAP-Z1ES network interface (what is known)

Findings from building this app, tested on a HAP-Z1ES with firmware 19404R. Much of the API
shape was first documented by [HAP-Revival](https://github.com/Guillain-RDCDE/HAP-Revival).
Addresses below are examples.

## Finding the player
- **SSDP:** send `M-SEARCH * HTTP/1.1` to `239.255.255.250:1900` with
  `ST: urn:schemas-upnp-org:device:Basic:1`. The player answers with
  `LOCATION: http://<player>:60100/hap.xml` (device description: friendlyName, modelName, UDN).
  Send it on every network interface (Wi-Fi and Ethernet may differ).
- **Bonjour:** `HAP-Z1ES._smb._tcp` (file sharing, port 445) and
  `HAP-Z1ES._spotify-connect._tcp` (port 60200).

## JSON API — port 60200
`POST http://<player>:60200/sony/<service>` with
`{"method": "...", "params": [...], "id": 1, "version": "x.y"}`. The player handles one request
at a time; send them one after another. Errors come back as `"error": [code, message]`
(1 = refused, 3 = bad value).

**Questions (safe):**
- `system`: `getPowerStatus` 1.1 `[]`, `getSystemInformation` 1.2 `[]`
- `avContent`: `getPlayingContentInfo` 1.2 `[]` (title, artist, album, `audio:track?id=N`,
  `positionMsec`, `durationMsec`, state PLAYING/PAUSED/STOPPED, format), `getSupportedFileType` 1.0 `[]`
- `audio`: `getVolumeInformation` 1.1 `[]` → `-1`: **the HAP-Z1ES has no volume control.**

**Commands (tested):**
- Play/pause **toggle**: `avContent` `pausePlayingContent` 1.0 `[{}]`
- Next / previous: `setPlayNextContent` / `setPlayPreviousContent` 1.0 `[{}]`
- Play one track: `createPlayingListAndQuickPlay` 1.0
  `[{"uri": "audio:track?id=N", "listIndex": 0, "listCount": 1, "playbackControlMode": "folder"}]`.
  Only one track can be queued this way, so apps play lists song by song.
- **Seek:** `setPlayContent` **1.1** `[{"positionSec": N + 0.01}]`. The decimal matters: a whole
  number (`60`) is accepted but **restarts the track**. Sony's app adds 0.01.
- A stopped player may refuse a seek with error 1.

**Never send:** `deleteContent` (deletes music). Avoid the front-panel key command on port
60100 (it once left a player offline until buttons were pressed on it).

## Library (read-only GETs)
- `GET /sony/contentdb/v100/audio/{albums,artists,genres,tracks,playlists}?offset=0&limit=500`,
  follow `paging.next`. Album tracks: `/audio/albums/<id>/tracks`; playlist tracks:
  `/audio/playlists/<id>/tracks`. Automatic playlists have negative ids (−1 Newly Added,
  −2 Most Played, −3 Least Played, −4 Recently Played). Slow when the player is "cold".
- Folder view: `GET /sony/contentdb/v100/services/directory/4100/…` (folders, and files with
  their `trackid`) — maps files on the drive to library tracks.
- Now playing / queue: `GET /sony/contentplayer/v100/{playinginfo,playqueue,playqueue/tracks}`.
- Cover art: `/sony/contentdb/v100/audio/albums/images/cover_art/<id>` (the links contain the
  player's own address; use the address you reached it on).

## Live updates
`POST /sony/notification/status` `{"status": "enable", "port": N}` → the player sends UDP
`NOTIFY` messages to that port (events `playqueueChanged`, `playingtrackChanged`,
`playinginfoChanged`, `volumeChanged`, `powerstateChanged`), each **three times** with the same
`SEQ`. Renew about every 240 s. **One listener per computer:** a second program on the same Mac
takes the messages away from the first.

## The drive (SMB)
- Share `HAP_Internal` (and `HAP_External` for a USB drive), guest login, no password.
- **Use SMB1** on the Mac (`~/Library/Preferences/nsmb.conf`, see `docs/nsmb.conf.example`).
  SMB 3.1.1 greetings make the player hang up; SMB2 runs out of credits on writes, drops the
  connection and can lose data. SMB1 reads ~15 MB/s.
- Closing a file can report an error (EBADF) although it worked; verify by reading back.
- Copy under a hidden temporary name and rename when complete: **if the player sees a file
  while it is empty or half-written, it ignores that file for good** (renaming doesn't help;
  a fresh copy does).
- The player updates its library by itself after copies, deletes, moves and tag changes
  (usually within a minute). Track ids survive moves and tag edits; changing an album's album
  artist gives the album a new id. Going into standby runs its "SensMe" analysis of new tracks.
- It reads ID3 tags in WAV files (not RIFF INFO) and a FLAC's own Vorbis comments.
- The volume and mute buttons on the player's infrared remote are not reported over the network.
