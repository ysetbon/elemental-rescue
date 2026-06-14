# Deploying online multiplayer

Online play uses **host authority over a dumb relay** (the same idea as AniRacers):

- One player clicks **HOST** — their browser becomes the authority and runs the whole
  game (spawns the world, moves everyone, decides catches/rescue) and streams
  snapshots out.
- Everyone else **JOINS** with the 4-letter code — their browser just sends input and
  renders the snapshots it gets back.
- The **relay** (`server.js`) is a tiny Node WebSocket process that only shuttles
  messages between the host and the guests. There is **no game engine on the server**,
  no Docker, no headless Godot.

```
guest browsers ── ws ──▶ [relay: server.js] ◀── ws ── HOST browser (runs the game)
```

If the **host** closes their tab the match ends for everyone; if a **guest** leaves,
the game keeps going (their character is left behind as an AI filler).

## 1. Deploy the relay (one-time)

The relay must be reachable at `wss://elemental-rescue-server.onrender.com` — that's
what the client looks for (`PROD_SERVER_URL` in `src/game.gd`). Name the Render
service `elemental-rescue-server` and that URL is automatic.

In the Render dashboard:

1. **New → Web Service** → connect the `elemental-rescue` GitHub repo.
2. Settings:
   - **Name:** `elemental-rescue-server`  ← must match for auto-discovery
   - **Runtime:** Node
   - **Build command:** `npm install --omit=dev`
   - **Start command:** `node server.js`
   - **Instance type:** Starter ($7/mo)
3. **Create Web Service.**

> Or let Render read `render.yaml` as a **Blueprint** (New → Blueprint) — it defines
> both the static site and this relay.

**Plan:** `render.yaml` uses the paid **Starter** plan so the relay is always-on (no
15-min sleep / cold start) on a steady CPU — the lowest, most consistent latency for the
guests, whose traffic all flows through it. The relay itself is tiny, so the **Free**
plan also works fine; it just sleeps after 15 min idle and takes ~30–60s to wake on the
first connect.

> Note: the relay only forwards messages. The biggest lag levers for your friends are
> (1) the relay's **region** — set it close to most players, and (2) the **host's**
> machine + upload, since the host runs the game for everyone.

(If you name the service something else, set `PROD_SERVER_URL` in `src/game.gd` to
`wss://<your-service>.onrender.com` and re-export the client.)

## 2. Publish the client

Re-export the web client whenever `src/` changes (the build is committed in `web/`):

```sh
godot --headless --path . --export-release "Web" web/index.html
```

Then commit `web/` and push to your deploy branch — the static site redeploys
automatically.

## 3. Play with friends

1. Open the site, click **🌐 PLAY ONLINE WITH FRIENDS**.
2. Click **HOST NEW GAME** → you get a 4-letter room code. Share it (or **Copy invite
   link**).
3. Friends open the site → **PLAY ONLINE** → type the code → **JOIN GAME**
   (up to 6 friends, 7 total). An invite link auto-fills the code.
4. Everyone picks an element (repeats allowed — NPCs fill the other teams to keep it
   fair). The host clicks **START GAME**.

On phones (and for everyone in an online match) the on-screen **joystick + SPRINT
button** appear automatically; on desktop you can also play with WASD + mouse-look.

## Local testing

```sh
node server.js                  # relay on ws://127.0.0.1:8910 (PORT to override)
```

Run two browser tabs against a locally-served `web/` build (see `scripts/serve_web.js`,
which sets the required COOP/COEP headers), or in the editor the native build connects
to `ws://127.0.0.1:8910` automatically. Open a tab with `?server=ws://127.0.0.1:8910`
to point a web build at your local relay.

## What's networked

- **Networked:** lobby + room codes, element pick + NPC fill, every player moving in
  sync, host-authoritative catches/respawns, and the full rescue (key → free twin →
  escort home → team wins → end screen).
- **Single-player only (not networked):** clan/training/disguise mechanics — online play
  uses the core rescue loop.
