# Dedicated authoritative game server for Elemental Rescue (online multiplayer).
#
# Runs a headless copy of the Godot game (`-- server`) which listens for browser
# clients over WebSocket. Render terminates TLS at the edge, so clients connect
# with wss:// while this process speaks plain ws:// on $PORT.
#
# We run the stock Godot Linux binary against a pre-exported server pack
# (build/server.pck). Export it before building the image:
#   godot --headless --path . --export-pack "Server" build/server.pck
#
# Health check: Render's default probe is a TCP connection to $PORT — a listening
# WebSocket server satisfies it. Do NOT set healthCheckPath (Godot won't answer a
# plain HTTP GET).
FROM ubuntu:24.04

ARG GODOT_VERSION=4.6.3
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip libfontconfig1 libfreetype6 nodejs \
    && rm -rf /var/lib/apt/lists/*

# Stock Godot Linux binary (runs headless via --headless; no editor needed).
RUN curl -fsSL -o /tmp/godot.zip \
        "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
    && unzip /tmp/godot.zip -d /tmp/godot \
    && mv /tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm -rf /tmp/godot /tmp/godot.zip

WORKDIR /app
COPY build/server.pck /app/server.pck
COPY scripts/render_proxy.js /app/render_proxy.js

# The Godot server binds GAME_PORT internally; the Node proxy owns the public $PORT
# (answers Render's HTTP port scan, pipes WebSocket traffic through to Godot).
ENV PORT=10000
ENV GAME_PORT=8910
EXPOSE 10000

# Run the headless Godot server in the background, then the proxy in the foreground.
CMD ["sh", "-c", "godot --headless --main-pack /app/server.pck -- server & exec node /app/render_proxy.js"]
