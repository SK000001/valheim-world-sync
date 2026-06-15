# Valheim Sync

Share one Valheim world with friends — **no host needs to stay online**.
The world lives in **Backblaze B2** (cloud) between sessions. Whoever wants to
play **EXTRACTs** the latest world, hosts in-game as normal, then **UPLOADs** it
back when finished. The next person does the same.

A "lock" stored in the cloud tracks whose turn it is, so two people don't host
from stale copies and split the world into two diverging timelines.

![The Valheim Sync app](docs/screenshot.png)

## Download

Grab the latest zip from the [**Releases**](../../releases/latest) page, unzip
it anywhere, and double-click `Valheim Sync.vbs`. On the first run the **Setup**
window opens by itself — paste your Backblaze bucket + key and you're done.
`rclone` downloads itself automatically. (No `config.json` ships in the
download — you create yours in Setup.)

## How to use it — just one file

Double-click **`Valheim Sync.vbs`**. That opens the app — a window with
everything you need:

- **PLAY** (big green bar) — one click: downloads the latest world, launches
  Valheim via Steam, then asks to upload when you close the game
- **EXTRACT** (green) — download the latest world before you play
- **UPLOAD** (blue) — save the world back to the cloud when you're done
- **World dropdown** (top-right) — switch which world the group syncs, if you
  keep more than one going
- **Setup** — opens by itself on the first run; paste your Backblaze bucket +
  key, pick your world from a dropdown of the worlds found on your PC, and
  optionally set a Discord webhook (with a **Test** button). Also adds a
  Desktop shortcut
- **Restore** — roll the world back to any earlier save (pick from a list)
- **Release lock** — free the world without uploading, for when a session is
  stuck (someone forgot to upload and isn't going to)
- **Share to friends** — builds a zip on your Desktop to send to friends
- **Refresh** / **Save folder** — check status, open the Valheim saves folder
- **View log** — open `vsync.log` to see what the background watcher did

Minimizing the window tucks it into the system tray (notification area) so it
keeps watching quietly; double-click the tray icon to bring it back.

The app **checks GitHub for updates** on launch and offers to update itself when
a new version is released, so you don't have to re-send the zip every time.

The status panel at the top shows who hosted last and whether anyone is
currently hosting. Pop-up warnings appear if something looks off — e.g. if the
cloud world is newer than yours (you'd overwrite someone), or if you'd take over
a session someone else still has.

(The `.ps1` files are the engine — you never click those. `Valheim Sync.vbs`
is the only thing you open.)

### Discord notifications (optional)
In **Setup**, paste a Discord webhook URL (Server Settings → Integrations →
Webhooks → New Webhook → Copy URL) and hit **Test** to confirm it works. The
group then gets a ping when someone **starts hosting** (🔴, with whose save
they picked up) and when the world is **free again** (🟢, with session length
and world size) — so nobody plays on top of someone else. The same URL is
shared in the friends zip, so everyone posts to the same channel. Notifications
arrive as colour-coded embeds; add a **Discord role ID** in Setup to @mention a
role (e.g. "@valheim") on each ping.

Not on Discord? Setup also takes an **ntfy topic URL** (e.g.
`https://ntfy.sh/my-valheim-group`) — the same start/free notices are pushed to
that topic, so phone notifications work without Discord.

### Upload automatically on close (optional)
Tick **"Upload automatically when I close the game"** in Setup and the watcher
uploads the world the instant you quit Valheim — no prompt — and frees the lock.
Handy for groups who always upload after every session.

### Abandoned sessions
If someone Extracts and never Uploads (crash, went to bed), their host lock is
treated as **abandoned after 6 hours** and anyone can take over without the
scary warning. Change the window via `LockStaleHours` in `config.json`.

While the game is actually running, the watcher **refreshes the lock every
15 minutes**, so a genuine marathon session is never mistaken for an
abandoned one — only a lock with no heartbeat for 6+ hours goes stale.

If you don't want to wait for the stale window, anyone can press **Release lock**
to free the world immediately (it posts a 🔓 notice to the group and does not
upload — use it only when the holder isn't going to upload).

---

## Got this from GitHub?

There's no `config.json` in the repo on purpose — it holds a private Backblaze
key and is git-ignored. To get started, either:

- **Just run Setup** — open `Valheim Sync.vbs`, click **Setup**, and it writes a
  fresh `config.json` for you, **or**
- **Copy the template** — rename `config.example.json` to `config.json` and fill
  in your own values.

`rclone` is downloaded automatically on first run, so there's nothing else to
install.

---

## One-time setup (do this once, by one person)

1. **Make the Backblaze bucket + key**
   - Sign up free at <https://www.backblaze.com/cloud-storage> (10 GB free).
   - **Buckets → Create a Bucket**, set it **Private**, copy the bucket name.
   - **Application Keys → Add a New Application Key** restricted to that bucket,
     and copy the **keyID** and **applicationKey** (the key shows only once).
2. **Open the app** (`Valheim Sync.vbs`) — Setup opens by itself the first
   time. Paste the bucket, keyID, and applicationKey; it downloads `rclone`
   and tests the connection.
3. **Seed the world** → click **UPLOAD** once to put your world in the cloud.
4. **Share** → click **Share to friends**, then send the
   `ValheimSync-for-friends.zip` from your Desktop to your friends. They unzip
   it and double-click `Valheim Sync.vbs` — no setup on their end.

> The `config.json` carries your B2 key, so only share the zip with people you
> trust to play on the world. Use a key restricted to just this bucket.

---

## Everyday use

Click **PLAY**. That's it — it downloads the latest world, launches Valheim,
and when you close the game a pop-up asks **"Upload now?"** — click Yes and
the world is saved and the lock freed.

Prefer the manual loop? Same as ever:

1. **Before you play:** click **EXTRACT** → start Valheim → host the world.
2. **When you're done:** fully close Valheim → click **UPLOAD**.

The status panel refreshes itself every few minutes; click **Refresh** any
time to see who's hosting right now.

## Golden rules (tell your friends)
1. **EXTRACT before you play, UPLOAD after you play.** Always both — or just
   press **PLAY**, which does both for you.
2. **Only one person hosts at a time.** The status panel shows the lock —
   coordinate on Discord; whoever holds it is "it".
3. **Close Valheim fully before UPLOAD/EXTRACT** (the save is locked while the
   game runs).
4. If someone forgets to UPLOAD, the next EXTRACT warns that the local copy
   looks newer — the person who actually played should UPLOAD first.

---

## Good to know
- The status panel shows the bucket's total size against B2's 10 GB free tier,
  and `vsync.log` (next to the app) records everything the background watcher
  did — handy if an upload prompt never appeared.
- **Restore** can also roll back from this PC's `local-backups/` ("From this
  PC..." button) — that replaces only your local world, the cloud is untouched.
- Uploads include Valheim's own `.db.old` / `.fwl.old` rollback copies, and every
  EXTRACT verifies the download against a SHA-256 checksum (both the `.db` and the
  `.fwl`) before it touches your local save — a corrupted transfer can never
  overwrite a good world.
- "Is the cloud newer than me?" is decided by a **version counter** in the cloud
  manifest, not by comparing timestamps across PCs — so a wrong clock on one
  machine can't cause a false "you'd overwrite newer progress" warning.
- Setup detects the worlds already on your PC and offers them in a dropdown, so
  there's no world name to type (or typo).
- If two people press EXTRACT at nearly the same time, the second one is stopped
  before taking the lock instead of silently splitting the world.
- Every UPLOAD keeps a timestamped copy under `valheim/<world>/history/` (use the
  **Restore** button to roll back). History is trimmed to the newest `HistoryKeep`
  saves (default 20) and old file versions are purged each upload, so the bucket
  stays small and well within B2's free tier.
- If the world you're about to UPLOAD is much smaller than the cloud copy, the app
  warns first — protection against uploading a wrong or corrupted world.
- A host lock older than `LockStaleHours` (default 6) is treated as abandoned, so a
  forgotten session never blocks the group.
- Each machine keeps its last 10 worlds in `local-backups/` here as a safety net.
- The shared world is set in `config.json` (`WorldName`) — or just use the **World**
  dropdown in the app.
- `rclone.exe` lives in `bin/` and is fetched automatically the first time
  (a pinned, known-good version).
- Your B2 application key is stored **encrypted at rest** (Windows DPAPI) in
  `config.json`, so a casual reader of the folder can't lift it. The
  "Share to friends" zip necessarily carries a usable (plaintext) key — only
  send it to people you trust, using a key restricted to this one bucket.
- App updates are **checksum-verified**: if a release publishes a `SHA256SUMS`
  (or `<zip>.sha256`) file, the download must match it before anything is
  overwritten.
- **Advanced:** the cloud backend isn't locked to Backblaze. Add a `Remote`
  block to `config.json` (`{ "Root": "myremote:path", "Env": { ... } }`) to point
  at any [rclone](https://rclone.org) backend — Google Drive, OneDrive, S3, etc.
  — instead of B2. To keep the bucket tidy automatically you can also set a B2
  lifecycle rule to expire old file versions, in place of the built-in per-upload
  cleanup.

## Developers
Pure logic (lock-staleness, freshness/version checks, history parsing, the
DPAPI round-trip) is covered by Pester tests. From the `valheim-sync` folder:

```powershell
Invoke-Pester .\Tests
```
