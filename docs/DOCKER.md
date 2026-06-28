# Learning Docker with Elemental Rescue

This repo didn't originally use Docker — and that's a useful starting point. This
guide adds a small, real Docker setup for the multiplayer **relay** (`server.js`)
and explains every concept as it appears, so you can learn Docker hands-on with
code you already understand.

> **Heads-up:** the game itself (the Godot client) is **not** containerized here,
> and doesn't need to be — it's exported to static files in `web/` and served by a
> CDN. The relay (a tiny Node WebSocket server) is the one piece that's a natural
> fit for a container, which makes it a perfect teaching example.

---

## 1. Why Docker at all?

Imagine sending `server.js` to a friend. They need the *right* Node version, they
need to run `npm install`, and if their OS differs, something might subtly break.
That's the classic **"works on my machine"** problem.

A Docker **image** solves this by packaging *everything the program needs to run* —
a minimal Linux, the Node runtime, your code, its dependencies — into one portable
artifact. Anyone with Docker can run that exact environment, identically, anywhere.

It's like shipping the whole kitchen, not just the recipe.

### Why didn't this project already use it?

Because it deploys on **Render**, which offers a "native Node runtime" —
Render *itself* provides the clean Linux-with-Node environment (see `render.yaml`).
That's Docker's job, done for you by the platform. The moment you move off such a
platform — a bare VM, AWS ECS, Kubernetes, or just wanting identical local and prod
environments — **Docker is the standard answer.** This guide shows you that path.

---

## 2. The three words you must not mix up

| Term | What it is | Analogy | You make it with |
|------|------------|---------|------------------|
| **Dockerfile** | A text recipe of build steps | The recipe card | you write it |
| **Image** | The built, frozen, read-only result | The baked cake | `docker build` |
| **Container** | A running instance of an image | A slice being eaten | `docker run` |

You can run **many containers** from **one image**. Containers are disposable: stop
one and (unless you set up storage) its internal changes vanish — the image is
untouched.

---

## 3. The files we added

```
Dockerfile            # the recipe: how to build the relay image
.dockerignore         # what NOT to copy into the build (keeps it small & safe)
docker-compose.yml    # a convenient launcher: settings instead of long CLI flags
docs/DOCKER.md        # this guide
```

Each file is **heavily commented** — open them side by side with this guide; the
comments explain the *what*, this guide explains the *why* and the workflow.

---

## 4. Install Docker

Get **Docker Desktop** (Mac/Windows) or **Docker Engine** (Linux) from
<https://docs.docker.com/get-docker/>. Verify:

```sh
docker --version
docker run --rm hello-world      # prints a success message and exits
```

---

## 5. Build the image

From the repo root (where the `Dockerfile` lives):

```sh
docker build -t elemental-relay .
```

- `-t elemental-relay` — **tag** (name) the resulting image.
- `.` — the **build context**: the folder Docker sends to the builder. `.dockerignore`
  controls what's excluded from it.

Watch the output: Docker runs each `Dockerfile` instruction as a **layer** and
prints `CACHED` for any it can reuse. Run the build a second time without changing
anything — it's nearly instant, because every layer is cached.

See your image:

```sh
docker images        # look for "elemental-relay"
```

---

## 6. Run a container

```sh
docker run --rm -p 8910:8910 elemental-relay
```

- `--rm` — auto-delete the container when it stops (no clutter).
- `-p 8910:8910` — **publish** a port, `HOST:CONTAINER`. Left = the port on your
  machine; right = the port `server.js` listens on inside the container. Without
  this flag the relay would be running but unreachable from your browser.

Now open <http://localhost:8910> — you'll see `elemental-rescue relay: ok`. That's
the same HTTP response `server.js` gives Render's health check.

Stop it with `Ctrl-C`. Useful variants:

```sh
docker run --rm -p 9000:8910 elemental-relay     # reach it on localhost:9000 instead
docker run -d -p 8910:8910 elemental-relay       # -d = detached (background)
docker ps                                        # list running containers
docker logs <container-id>                        # view a detached container's output
docker stop <container-id>                         # stop it
```

---

## 7. The same thing, with Compose

Typing those flags every time is tedious. `docker-compose.yml` records them, so:

```sh
docker compose up --build     # build (if needed) + run, logs in the foreground
docker compose up -d          # ...in the background
docker compose logs -f        # follow logs
docker compose down           # stop & remove the container(s)
```

Compose’s real power is **multiple services** wired together (say, a web app + a
database + a cache) on a shared private network. We have only the relay, so here it
mainly serves as a clean launcher — but the file is structured so you can see how a
bigger stack would be described.

---

## 8. Connect the actual game to your containerized relay

The relay alone isn't a game — it shuttles messages between browsers. To see it
work end to end against your container:

1. Start the relay with Compose (`docker compose up`).
2. Serve the web client locally (it needs special COOP/COEP headers — see
   `scripts/serve_web.js` and `docs/DEPLOY_ONLINE.md`).
3. Open the client with `?server=ws://127.0.0.1:8910` to point it at your local
   container, click **HOST**, then join from a second tab.

You're now running the multiplayer backend exactly as it'd run in production — just
inside a container on your own machine.

---

## 9. Key concepts this setup demonstrates

- **Base images** (`FROM node:20-alpine`) — stand on a prebuilt OS+runtime; `-alpine`
  keeps it tiny.
- **Layer caching** — copy `package.json` and install deps *before* copying source,
  so code edits don't trigger a full reinstall. (See `Dockerfile` step 3.)
- **`.dockerignore`** — keep junk, secrets, and the big Godot files out of the image.
- **Reproducible installs** — `npm ci` uses exact `package-lock.json` versions.
- **Least privilege** — `USER node` runs the process as a non-root user.
- **Ports** — `EXPOSE` documents; `-p` actually publishes.
- **Config via env vars** — `PORT`, `RELAY_LATENCY_MS`, `RELAY_JITTER_MS` are read by
  `server.js`; Compose passes them in.
- **Signals & PID 1** — exec-form `CMD ["node","server.js"]` so `Ctrl-C`/`docker stop`
  reach Node cleanly.
- **Healthchecks** — Docker probes the HTTP endpoint to mark the container healthy.

---

## 10. Going further

- **Multi-stage builds** — for projects with a heavy *build* step (compilers,
  bundlers), use one stage to build and a slim second stage that copies only the
  finished artifact, shrinking the final image. Our relay has no build step, so a
  single stage is honest and simpler — but this is the next pattern to learn.
- **Push to a registry** — `docker tag` + `docker push` to Docker Hub / GHCR so
  others (or a server) can `docker pull` your image.
- **Orchestration** — Kubernetes / ECS run many containers across many machines.
  Compose is the friendly on-ramp to those ideas.

---

## Cheat sheet

```sh
docker build -t elemental-relay .          # build the image
docker run --rm -p 8910:8910 elemental-relay   # run it
docker compose up --build                  # build + run via Compose
docker compose down                        # stop + clean up
docker images                              # list images
docker ps            / docker ps -a        # running / all containers
docker logs <id>                           # container output
docker exec -it <id> sh                     # open a shell INSIDE a running container
docker system prune                         # reclaim space (removes stopped junk)
```
