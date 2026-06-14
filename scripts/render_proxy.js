// Tiny front proxy for the Elemental Rescue dedicated server on Render.
//
// Render web services detect/route a service by HTTP port scanning, but Godot's
// WebSocketMultiplayerPeer only speaks the WebSocket handshake and rejects a plain
// GET. So this proxy owns the public $PORT and:
//   - answers non-WebSocket HTTP requests (Render's port scan / health checks) with 200,
//   - transparently pipes WebSocket connections through to the Godot server, which
//     listens on GAME_PORT (default 8910) inside the same container.
//
// Zero npm dependencies — just the built-in `net` module.

const net = require("net");

const PUBLIC_PORT = parseInt(process.env.PORT || "10000", 10);
const GAME_PORT = parseInt(process.env.GAME_PORT || "8910", 10);
const GAME_HOST = "127.0.0.1";

const server = net.createServer((client) => {
  client.once("data", (buf) => {
    const head = buf.toString("latin1", 0, Math.min(buf.length, 1024)).toLowerCase();
    const isWebSocket = head.includes("upgrade:") && head.includes("websocket");
    if (isWebSocket) {
      // game client → splice straight through to Godot, replaying the first bytes
      const upstream = net.connect(GAME_PORT, GAME_HOST, () => {
        upstream.write(buf);
        client.pipe(upstream);
        upstream.pipe(client);
      });
      upstream.on("error", () => client.destroy());
      client.on("error", () => upstream.destroy());
    } else {
      // Render's HTTP port scan / health check → a minimal 200 so the port is detected
      const body = "elemental-rescue server: ok";
      client.end(
        "HTTP/1.1 200 OK\r\n" +
        "Content-Type: text/plain\r\n" +
        "Content-Length: " + Buffer.byteLength(body) + "\r\n" +
        "Connection: close\r\n\r\n" +
        body
      );
    }
  });
  client.on("error", () => {});
});

server.listen(PUBLIC_PORT, "0.0.0.0", () => {
  console.log("[proxy] listening on " + PUBLIC_PORT + " -> godot " + GAME_HOST + ":" + GAME_PORT);
});
