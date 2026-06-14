# Deploying online multiplayer

The online build adds a **dedicated game server** (a headless copy of the game)
that browser clients connect to over WebSocket. The existing static site keeps
serving the game; the server is a second, separate Render service.

Everything is already wired so the client finds the server automatically **if you
name the Render service `elemental-rescue-server`** (that makes its URL exactly
`wss://elemental-rescue-server.onrender.com`, which is what the client looks for —
see `PROD_SERVER_URL` in `src/game.gd`).

## 1. Deploy the server (one-time)

In the Render dashboard:

1. **New → Web Service** → connect the `elemental-rescue` GitHub repo.
2. Settings:
   - **Name:** `elemental-rescue-server`  ← must match for auto-discovery
   - **Runtime:** Docker (auto-detected from `Dockerfile`)
   - **Branch:** the branch you merged this into (e.g. `main`)
   - **Instance type:** Free
3. **Create Web Service.** Render builds the Docker image (downloads Godot, runs
   `build/server.pck`) and starts it. First build takes a few minutes.
4. When it's live you'll see a URL like `https://elemental-rescue-server.onrender.com`.
   Health: Render's default TCP check passes once the server is listening — there's
   intentionally **no** `healthCheckPath` (the server speaks WebSocket, not HTTP).

> Alternatively, Render can read `render.yaml` as a **Blueprint** (New → Blueprint)
> and create the service for you. It also contains the existing static site, so
> review what it proposes before applying if your static site was made manually.

**Free-tier note:** the server sleeps after 15 min idle and takes ~1 min to wake on
the first join (then it's smooth). Upgrade that service to Starter ($7/mo) for
always-on if you play often.

## 2. Publish the online client

The web client needs to be re-exported so the live site includes the online UI:

```sh
godot --headless --path . --export-release "Web" web/index.html
```

Then commit `web/` and push to your deploy branch — the static site redeploys
automatically.

(If you named the server something other than `elemental-rescue-server`, first set
`PROD_SERVER_URL` in `src/game.gd` to `wss://<your-service>.onrender.com`, then
re-export.)

## 3. Play with friends

1. Open the site, click **🌐 PLAY ONLINE WITH FRIENDS**.
2. Click **HOST NEW GAME** → you get a 4-letter room code. Share it.
3. Friends open the site → **PLAY ONLINE** → type the code → **JOIN GAME**
   (up to 6 friends, 7 total).
4. Everyone picks an element (repeats allowed — NPCs fill the other teams to keep
   it fair). The host clicks **START GAME**.

## Re-exporting the server after server-side code changes

The server pack is committed at `build/server.pck`. After changing any server-side
game logic, regenerate and commit it:

```sh
godot --headless --path . --export-pack "Server" build/server.pck
```

## What's verified vs. pending

- **Verified (headless):** lobby + room codes, element pick + NPC fill, two players
  moving in sync and seeing each other in real time, server-authoritative catches/
  respawns, and the full rescue (key → free twin → escort home → team wins → end
  screen).
- **Best confirmed in a browser with a friend:** visual smoothness (interpolation,
  camera) and feel over the real internet — tune snapshot rate / interpolation in
  `src/game.gd` (`SNAP_HZ`, `INTERP_DELAY`) if needed.
- **Deferred (not blocking play):** clan/training mechanics aren't networked yet —
  they work in single-player; online play uses the core rescue loop.
