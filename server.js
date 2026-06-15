// Elemental Rescue — online multiplayer relay.
//
// A tiny, dumb message relay (no game engine on the server). One player's browser
// is the HOST and runs the whole game (the authority); everyone else is a GUEST.
// This process just shuttles messages between them and tracks room membership —
// the same idea as AniRacers' server.js.
//
//   guest browsers ── ws ──▶ [this relay] ◀── ws ── HOST browser (runs the game)
//
// Routing is by role, not by content:
//   • a message from the HOST  → broadcast to every guest in the room
//   • a message from a GUEST   → forwarded to the host (tagged with `from`)
//   • create / join / leave    → handled here (room bookkeeping)
//
// One HTTP server answers Render's port scan / health check AND carries the
// WebSocket upgrade, so there's no Docker image, no headless Godot, no proxy.
//
// Run locally:  npm install && node server.js   (PORT defaults to 8910)

const http = require("http");
const { WebSocketServer } = require("ws");

const PORT = parseInt(process.env.PORT || "8910", 10);
const MAX_PLAYERS = 7;                         // host + up to 6 guests

// QA only: inject one-way network latency + jitter so a local host+guest behaves like
// a real internet link (see scripts/nettest.* ). Unset in production → forwards are
// instant and this whole block is a no-op (LAT==0 && JIT==0 → synchronous send).
const LAT = parseInt(process.env.RELAY_LATENCY_MS || "0", 10);   // one-way delay, ms
const JIT = parseInt(process.env.RELAY_JITTER_MS || "0", 10);    // added 0..JIT ms, ms
function deliver(ws, payload, isBinary) {
  if (!ws || ws.readyState !== 1) return;
  if (LAT <= 0 && JIT <= 0) { ws.send(payload, { binary: isBinary }); return; }
  const d = LAT + (JIT > 0 ? Math.random() * JIT : 0);
  setTimeout(() => { if (ws.readyState === 1) ws.send(payload, { binary: isBinary }); }, d);
}

const httpServer = http.createServer((req, res) => {
  // Anything that isn't a WebSocket upgrade (Render's port scan, /healthz) → 200.
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("elemental-rescue relay: ok");
});

const wss = new WebSocketServer({ server: httpServer });

const rooms = new Map();   // CODE -> { code, hostWs, started, guests: Map(id -> ws) }
let nextId = 1;

const send = (ws, obj) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); };
const roomSize = (room) => 1 + room.guests.size;   // host + guests

function bcGuests(room, obj) {
  const s = JSON.stringify(obj);
  for (const g of room.guests.values()) deliver(g, s, false);
}

wss.on("connection", (ws) => {
  ws.id = nextId++;
  ws.room = null;       // CODE once in a room
  ws.isHost = false;

  ws.on("message", (data, isBinary) => {
    // Hot path: the HOST streams world snapshots as raw binary frames. Forward them to
    // every guest untouched (no JSON parse) — the relay never inspects snapshot bytes.
    if (isBinary) {
      const room = rooms.get(ws.room);
      if (room && ws.isHost)
        for (const g of room.guests.values())
          deliver(g, data, true);
      return;
    }
    let m;
    try { m = JSON.parse(data); } catch (_e) { return; }

    // ---- lobby handshake -------------------------------------------------
    if (m.t === "create") {
      if (ws.room) return;
      const code = String(m.code || "").toUpperCase().slice(0, 8) || ("R" + ws.id);
      if (rooms.has(code)) return send(ws, { t: "err", m: "A game already exists here. Ask the host for the code and tap Join." });
      const room = { code, hostWs: ws, started: false, guests: new Map() };
      rooms.set(code, room);
      ws.room = code; ws.isHost = true;
      return send(ws, { t: "room", you: ws.id, code, host: true });
    }

    if (m.t === "join") {
      if (ws.room) return;
      const room = rooms.get(String(m.code || "").toUpperCase());
      if (!room)        return send(ws, { t: "err", m: "No game with that code. Check it with the host." });
      if (room.started) return send(ws, { t: "err", m: "That game already started." });
      if (roomSize(room) >= MAX_PLAYERS) return send(ws, { t: "err", m: "Game is full (" + MAX_PLAYERS + " players)." });
      room.guests.set(ws.id, ws);
      ws.room = room.code; ws.isHost = false;
      send(ws, { t: "room", you: ws.id, code: room.code, host: false });
      send(room.hostWs, { t: "guest_join", id: ws.id, name: String(m.name || "Player").slice(0, 16) });
      return;
    }

    // ---- in-room routing -------------------------------------------------
    const room = rooms.get(ws.room);
    if (!room) return;

    if (ws.isHost) {
      if (m.t === "start") room.started = true;     // late joiners get rejected from now on
      bcGuests(room, m);                            // lobby / start / snap / end → all guests
    } else {
      m.from = ws.id;                               // host trusts the relay's id (no spoofing)
      deliver(room.hostWs, JSON.stringify(m), false);  // hello / el / in / dbg → the host
    }
  });

  ws.on("close", () => {
    const room = rooms.get(ws.room);
    if (!room) return;
    if (ws.isHost) {
      bcGuests(room, { t: "host_gone" });           // host left → the match is over for everyone
      rooms.delete(room.code);
    } else {
      room.guests.delete(ws.id);
      send(room.hostWs, { t: "guest_leave", id: ws.id });
    }
  });

  ws.on("error", () => {});
});

httpServer.listen(PORT, () => {
  console.log("[relay] elemental-rescue relay listening on " + PORT);
});
