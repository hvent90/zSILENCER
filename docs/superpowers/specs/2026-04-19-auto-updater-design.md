# Cross-platform auto-updater — design

**Date:** 2026-04-19
**Scope:** Client-only auto-updater for macOS (arm64) and Windows (x64).
Server deploys are already handled by the existing tag-push CI pipeline
(`.github/workflows/deploy.yml`) and are out of scope.

## Motivation

Version strings are a hard wire-compat gate: `src/game.cpp:31` sets
`world.SetVersion("00023")`, and the lobby at `src/lobby.cpp:293`
rejects mismatched clients. Today a rejected client has no recovery
path — it simply can't play online. As release cadence increases, this
friction grows. We want the same version-mismatch event to trigger a
self-contained update flow that ends with the user back in the lobby
running the correct version, with no manual download.

## Non-goals

- Linux auto-update (Linux users build from source).
- Delta updates / binary diffing.
- Staged or gradual rollouts.
- Updates mid-game (the updater is strictly pre-game).
- Auto-update for dedicated-server processes spawned outside the
  lobby (the lobby spawns its own via `server/proc.go` and they
  inherit the lobby's binary version).

## Architecture overview

Three moving pieces, all triggered by the existing `MSG_VERSION`
reject path:

1. **Lobby (`server/`).** Loads `update.json` from disk at startup.
   When a client handshakes with a mismatched version string, the
   `MSG_VERSION` reject reply is extended to carry the platform-
   specific download URL and sha256 for the currently-deployed
   version.
2. **Client, normal mode (`src/`).** On receiving a reject-with-
   update-info, transitions to a new `UPDATING` top-level state:
   shows a modal, gates on user consent, downloads the zip over
   HTTPS, verifies sha256, copies itself to a temp path, `exec`s
   that temp copy with `--self-update-stage2`, and exits.
3. **Client, stage-2 mode.** Same binary, different entry path at
   the very top of `main()` — never touches SDL. Waits for the
   original PID to exit, extracts the zip to a sibling temp dir,
   `rename`s it over the install dir, relaunches the new binary,
   and exits.

## User experience

### Consent gate

On `MSG_VERSION` reject-with-update, the lobby browser is replaced
by a centered SDL modal in the existing interface style:

```
  ┌────────────────────────────────────┐
  │   Update required                  │
  │                                    │
  │   Your version: 00023              │
  │   Server version: 00024            │
  │                                    │
  │   An update is required to play    │
  │   online.                          │
  │                                    │
  │   [ Update ]       [ Cancel ]      │
  └────────────────────────────────────┘
```

**Update** kicks off the download. **Cancel** quits the game — the
user can't play with a mismatched version, so there is no "skip and
keep playing" branch.

### Download + swap

After Update is clicked, the modal transitions to a progress bar:

```
  ┌────────────────────────────────────┐
  │   Downloading update…              │
  │   [████████░░░░░░░░░░] 42%         │
  │   [ Cancel ]                       │
  └────────────────────────────────────┘
```

On completion and sha256 verification, the modal briefly shows
"Update ready. Restarting…" and the window closes. For 1–3 seconds
nothing is on screen (stage-2 is waiting for the original process to
exit and extracting the zip). The new binary relaunches, shows the
main menu, and the user reconnects normally.

### Failure modes visible to the user

- **Network error / HTTP non-200:** `"Update failed: could not reach
  <host>."` with `[ Retry ] [ Quit ]`. After 3 retries the Retry
  button becomes `[ Open download page ]` and opens the GitHub
  release URL in the OS browser.
- **sha256 mismatch:** `"Update failed: downloaded file was
  corrupted."` Same retry/escape-hatch flow.
- **Install dir not writable (stage-2):** Stage-2 can't show SDL
  UI, so it logs to a file (`%TEMP%\zsilencer-update.log` /
  `~/Library/Logs/zSILENCER/update.log`), relaunches the *old*
  install (untouched — see atomic-swap guarantee below), and the
  old binary detects a stage-2 failure marker on startup and shows
  the error modal with the download-page escape hatch.
- **Cancel during download:** Cancels the libcurl transfer, deletes
  the partial file, quits the game.

## Wire protocol change

`MSG_VERSION` today carries a version string in the request and a
single success byte in the reply (`src/lobby.cpp:293`,
`src/lobby.cpp:382`, mirrored in `server/protocol.go`).

### New request format

```
MSG_VERSION request:
  cstring  version          // existing, e.g. "00023"
  u8       platform         // NEW: 0=unknown, 1=macos_arm64, 2=windows_x64
```

### New reply format

```
MSG_VERSION reply:
  u8       success
  if !success AND client sent known platform AND manifest is loaded
                 AND manifest version == lobby -version:
    u16    url_len
    u8     url[url_len]     // https URL to the platform zip
    u8     sha256[32]       // raw bytes, NOT hex
```

### Backwards compatibility

- **Old client, new lobby:** the lobby reads a short request, treats
  `platform` as 0 (unknown), replies with a bare single-byte reject.
  Exactly the current behavior.
- **New client, old lobby:** the old lobby's short reply is detected
  (no trailing bytes after the success byte) and the updater silently
  no-ops. The client shows a plain "version mismatch" error with the
  download-page escape hatch.

## Delivery: update manifest

Server learns URLs + sha256s from a JSON file on disk:

```json
{
  "version":        "00024",
  "macos_url":      "https://github.com/.../zsilencer-macos-arm64.zip",
  "macos_sha256":   "<64-char hex>",
  "windows_url":    "https://github.com/.../zsilencer-windows-x64.zip",
  "windows_sha256": "<64-char hex>"
}
```

New CLI flag: `-update-manifest /path/to/update.json` (default
`./update.json`). Loaded once at lobby startup. If missing or
malformed, the lobby logs a warning and runs with no manifest;
mismatched clients get a bare reject (graceful degradation). No
reload-at-runtime — operators restart the lobby to pick up new
manifests.

**Sanity check:** the lobby only advertises update info if
`manifest.version == lobby -version`. Prevents serving stale URLs
after a botched deploy where the manifest lags the binary.

## CI changes: `.github/workflows/deploy.yml`

After the lobby binary uploads, add a step that:

1. Waits for the sibling `release.yml` run to finish via a
   `gh release view $TAG --json assets` retry loop (5 attempts,
   30 s apart).
2. Downloads each release zip, computes sha256 locally.
3. Writes `update.json` with `{tag version, asset URLs, sha256s}`.
4. `scp`s it to the lobby box into the path the lobby reads.
5. Restarts `zsilencer-lobby` via systemctl (already done today).

The race between `deploy.yml` and `release.yml` is new fragility;
the retry loop is the mitigation.

## Client code structure

### New files

- **`src/updater.h` / `src/updater.cpp`** — ~300-500 line self-
  contained module. Public surface:

  ```cpp
  class Updater {
    enum State { IDLE, PROMPTING, DOWNLOADING, VERIFYING,
                 STAGING, FAILED };
    void Start(std::string url, std::array<uint8_t,32> sha256);
    void Tick();                    // pump from main loop
    State GetState() const;
    float GetProgress() const;
    std::string GetErrorMessage() const;
    void Cancel();
  };
  ```

  Owns: HTTPS download (libcurl), SHA-256 (vendored public-domain
  impl, ~200 lines — avoids an OpenSSL dep), zip extraction
  (minizip adapter over the already-linked zlib), and the
  exec-stage-2 handoff.

- **`src/updateinterface.h` / `src/updateinterface.cpp`** — SDL
  modal, following the pattern of `interface.cpp` /
  `gamecreateinterface.cpp`. Renders consent / progress / error
  layouts driven by `Updater::GetState()`.

### Changes to existing files

- **`src/main.cpp`** — at the very top of `main()`, before
  `SDL_Init`, branch on `--self-update-stage2` into
  `RunStage2(argv)` and exit. Never opens a window. Parallels the
  existing `-s` dedicated-mode branch.
- **`src/game.cpp`** — add `UPDATING` top-level state. When
  `Lobby` receives a reject-with-update-info, push the update
  info into `Game`, which transitions state and instantiates
  `updateinterface`.
- **`src/game.cpp:31`** — version string becomes
  `world.SetVersion(ZSILENCER_VERSION)` with the macro defaulting
  to `"00023"`. New `CMakeLists.txt` define
  `-DZSILENCER_VERSION=...` parallels the existing
  `ZSILENCER_LOBBY_HOST`/`ZSILENCER_LOBBY_PORT` defines at
  `CMakeLists.txt:48`.
- **`src/lobby.cpp:293`** — extend `MSG_VERSION` reply parser to
  read the optional `url_len` + url + sha256 and push to `Game`.
- **`src/lobby.cpp:382`** — extend `MSG_VERSION` request sender
  to append the platform byte. Platform constant is set at
  compile time per-build.
- **`CMakeLists.txt`** — add libcurl dep; macOS uses system; Windows
  adds it to `vcpkg.json`.

### Not changed

- `world.cpp`, `renderer.cpp`, simulation code. The updater lives
  entirely in the pre-game state machine.
- Dedicated server mode (`-s`) — skips the updater entirely.

## Server code structure

### New files

- **`server/update.go`** — manifest loading:

  ```go
  type UpdateManifest struct {
      Version       string `json:"version"`
      MacOSURL      string `json:"macos_url"`
      MacOSSHA256   string `json:"macos_sha256"`
      WindowsURL    string `json:"windows_url"`
      WindowsSHA256 string `json:"windows_sha256"`
  }

  func LoadManifest(path string) (*UpdateManifest, error)
  ```

- **`server/update_test.go`** — fixture-driven tests for
  `LoadManifest` (valid / malformed / missing fields / wrong type).

### Changes to existing files

- **`server/protocol.go`** — extend `MSG_VERSION` encode/decode for
  the new request and reply shapes; include a round-trip test.
- **`server/client.go`** — version-check handler consults the
  manifest: if client's version mismatches *and* manifest is loaded
  *and* manifest version == lobby `-version` *and* client's platform
  is known, include the update fields in the reject. Otherwise send
  a bare reject.
- **`server/main.go`** — register `-update-manifest` flag; call
  `LoadManifest`; hand result to the hub.

### Not changed

- `hub.go`, `udp.go`, `store.go`, `proc.go` — none touch the version
  handshake.

## Atomic swap guarantee

Stage-2 never modifies the live install dir in place. It extracts
the zip to a *sibling* temp directory first (e.g.
`<install-dir>.new`), validates the extraction succeeded, then
performs a directory `rename` to atomically replace the old install
(e.g. `<install-dir>` → `<install-dir>.old`, `<install-dir>.new` →
`<install-dir>`). Stage-2 then launches the new binary and exits.
The newly-launched binary deletes `<install-dir>.old` on startup if
it exists; this also serves as the signal that a successful update
just happened (for the optional "Updated to vXXX" toast).

This means any failure before the final `rename` leaves the original
install fully intact and relaunchable. Disk-full, truncated zip,
permission denied — all recover cleanly to the old version.

## Logging

Every decision point in the update flow logs to stdout (and on the
client-stage-2 path additionally to the log file mentioned above):

- **Client** prefix: `[updater]` via `fprintf(stderr, ...)`.
- **Lobby** prefix: `[lobby-update]` via `log.Printf(...)`.

Events to log on the client: version mismatch detected, update info
received from lobby (URL, sha256 hex), consent granted, download
started, periodic progress ticks, download finished (bytes,
duration), sha256 computed vs expected, stage-2 exec args, extract
start/finish, atomic rename, relaunch target PID. Errors include
errno / libcurl code / HTTP status where applicable.

Events to log on the lobby: manifest load success/failure at
startup, manifest version vs lobby version, `MSG_VERSION` request
parsed (client version, platform), reject decision (bare vs with
update payload) with reason.

Goal: a stdout capture from a broken install is enough to diagnose
without attaching a debugger.

## Security posture

- **Downloads use HTTPS** with the system cert store (libcurl default).
- **Loopback exception:** the downloader accepts `http://` URLs only
  when the host resolves to `127.0.0.1` or `::1`. Needed for the
  local dev harness (below); safe because loopback traffic doesn't
  leave the machine.
- **sha256 from lobby** is the integrity boundary. Anyone able to
  compromise the lobby can serve arbitrary binaries — the lobby is
  already the trust root for gameplay, so this does not expand the
  attack surface.
- **macOS** gets the extra notarization check from the OS on every
  launch of the replaced binary (Gatekeeper verifies the Developer
  ID signature). Sanity: both old and new are signed with the same
  identity by `release.yml`, so Gatekeeper is silent.
- **Windows** builds are unsigned today. SmartScreen's first-run
  warning is already a known wart (see `release.yml`'s README body).
  An auto-updated binary delivered by an already-trusted running
  process should not re-warn, but this needs explicit testing on a
  clean VM — documented in the testing checklist.

## Error handling

### Download-time

| Failure | Detection | UX | Recovery |
|---|---|---|---|
| Network error / TLS fail | libcurl return code | Error modal | Retry × 3 → escape hatch |
| HTTP non-200 | libcurl | Error modal | Retry × 3 → escape hatch |
| sha256 mismatch | post-download compare | Error modal | Retry × 3 → escape hatch |

Escape hatch = `[ Open download page ]` launches the OS browser to
the release URL and quits the game.

### Stage-2

| Failure | Detection | Recovery |
|---|---|---|
| Install dir not writable | fails at `rename`, before touching old install | Write error log; relaunch old install; old binary detects stage-2 failure marker on startup and shows error modal |
| Extract fails mid-way | zip lib return code | Same — old install untouched due to atomic-swap guarantee |
| New binary fails to launch post-swap | stage-2 waits 5 s, checks PID liveness | Write error log; no auto-revert (too risky — new version may have migrated user state); user must reinstall manually |

### Cancel

`[ Cancel ]` during download: abort libcurl transfer, delete partial
file, quit game.

## Bootstrap problem

The updater code only exists in releases *from the one it ships in
forward*. Users on pre-updater versions (everything up to and
including 00023) will hit the version mismatch and see a plain
"can't connect" with no auto-update path. They need to download
once manually; from then on, auto-update works.

The deploy notes for the first updater-bearing release should call
this out to existing players.

## Local dev testing harness

End-to-end verification on a developer's machine, no GitHub push
required.

### Design prerequisites that make this work

1. **Version is compile-time overridable** (see `game.cpp:31` change
   above) — lets the harness build "old" and "new" versions from
   the same tree.
2. **Updater accepts HTTP on loopback.** The downloader rejects
   `http://` URLs unless the host resolves to `127.0.0.1` / `::1`.
3. **Stage-2 supports raw-binary install layout**, not just
   `.app`-bundled. Detects layout at runtime: if `install-dir`
   points into a `.app/Contents/MacOS/`, treats the `.app` as the
   unit; otherwise treats the directory containing the binary as
   the unit. Needed for the harness, but also useful for Linux-
   from-source users in the future.

### `scripts/test-updater.sh` (macOS / Linux)

```bash
#!/usr/bin/env bash
set -euo pipefail

OLD_VER=00023
NEW_VER=00024

cmake -B build-new -S . -DZSILENCER_VERSION=$NEW_VER -DZSILENCER_LOBBY_HOST=127.0.0.1
cmake --build build-new -j
mkdir -p test-update-host
(cd build-new && zip -r ../test-update-host/zsilencer-macos-arm64.zip zsilencer ../data)
SHA=$(shasum -a 256 test-update-host/zsilencer-macos-arm64.zip | awk '{print $1}')

cmake -B build-old -S . -DZSILENCER_VERSION=$OLD_VER -DZSILENCER_LOBBY_HOST=127.0.0.1
cmake --build build-old -j

cat > update.json <<EOF
{ "version": "$NEW_VER",
  "macos_url": "http://127.0.0.1:8000/zsilencer-macos-arm64.zip",
  "macos_sha256": "$SHA",
  "windows_url": "http://127.0.0.1:8000/zsilencer-windows-x64.zip",
  "windows_sha256": "$SHA" }
EOF

( cd test-update-host && python3 -m http.server 8000 ) &
HTTP_PID=$!

cd server && go build
./zsilencer-lobby -addr :15170 -version $NEW_VER -update-manifest ../update.json &
LOBBY_PID=$!

trap "kill $HTTP_PID $LOBBY_PID 2>/dev/null" EXIT

echo "Launching old client — expect update modal…"
./build-old/zsilencer
```

### `scripts/test-updater.ps1` (Windows)

PowerShell companion with the same structure. Worth having from day
one — the Windows file-lock behavior is the riskiest part of the
whole design and macOS-only testing will miss Windows bugs.

### Failure-case dev recipes

- **Corrupt sha:** edit `update.json`, flip a hex digit, relaunch old
  client.
- **Network drop:** kill the python server mid-download.
- **HTTP 404:** rename the zip in `test-update-host/`.
- **Read-only install dir:** `chmod -w build-old/` before launching.
- **Old client / new lobby:** temporarily revert the lobby-side
  platform-byte parser and re-run.

## Testing

### Unit tests

**C++** (new `tests/updater_test.cpp` + vendored doctest single-
header harness, since the repo has no test infrastructure today):

- SHA-256: FIPS 180-4 vectors.
- Zip extraction: checked-in fixture zip.
- `MSG_VERSION` request/response encoding: round-trip plus
  "short message from old lobby" fixture confirms graceful no-op.
- Stage-2 argv parsing: crafted argv → parsed struct assertions.

**Go** (`server/update_test.go`, standard `testing` package):

- `LoadManifest` with valid / malformed / missing-field /
  wrong-type fixtures.
- `MSG_VERSION` encode/decode round-trip + "version matches, no
  update payload" + "old client, short request" cases.

Unit tests run in a new `test` CI job that blocks both `deploy.yml`
and `release.yml`.

### Integration tests (manual, pre-release checklist)

1. **Happy path, macOS.** Build v_OLD, publish v_NEW test release,
   run lobby with v_NEW manifest. Launch v_OLD → consent modal →
   Update → swap → v_NEW launches and connects.
2. **Happy path, Windows.** Same but on a clean Windows VM — not a
   dev box. Install to `C:\Program Files\zSILENCER` to exercise
   the permission model.
3. **Cancel during download.** Partway through progress, cancel;
   confirm no partial file left; relaunch v_OLD; still runs.
4. **sha256 mismatch.** Mangle the sha; confirm 3-retry-then-
   escape-hatch flow.
5. **Network drop mid-download.** Kill server; confirm error
   message.
6. **Read-only install dir, macOS.** Move `.app` to `/Applications`
   as admin; run client non-admin; confirm graceful failure with
   old version still functional.
7. **Old client + new lobby.** Pre-updater binary against new
   lobby; confirms old `MSG_VERSION` reject behavior preserved.
8. **New client + old lobby.** Client gets single-byte reject, no
   URL info, falls through to manual-download error modal.
