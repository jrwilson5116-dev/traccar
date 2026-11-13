# Traccar Dev Container Sandbox: Setup & Safe Agent Use

This directory holds a Docker-based development sandbox for working on the Traccar server (and the `traccar-web` UI) with AI coding agents such as Claude Code and OpenCode. The agents run **inside the container**, so the files and host resources they can touch are limited to what the container is given.

---

## 1. Files in `dev_test_env/`

| File | Purpose |
|---|---|
| `Dockerfile` | Image built on `python:3.12-slim`. Installs `git`, `curl`, `nano`, `procps`, `nodejs`/`npm`, **`openjdk-21-jdk`** and `gradle` (for Traccar), the Python packages in `requirements.txt`, the **Claude Code CLI** (`@anthropic-ai/claude-code`), **OpenCode** (`opencode-ai`) and **ngrok**. Copies `settings.json` and `statusline.sh` into `/root/.claude/`, adds shell aliases, and sets `docker-entrypoint.sh` as the `ENTRYPOINT` (default `CMD` is `/bin/bash`). |
| `docker-compose.yml` | Defines the `traccar-dev` service: builds from the `Dockerfile`, tags it `traccar-dev:latest`, names the container `traccar-dev`, publishes port `8080:8080`, mounts the project at `/workspace`, keeps the container alive with `sleep infinity`, enables an interactive TTY, and uses `restart: unless-stopped`. |
| `docker-entrypoint.sh` | Runs on every container start. If a saved Claude credential exists in `/claude-auth`, it restores it and marks onboarding done. A background loop copies the live credential back to `/claude-auth` whenever it changes. It then `exec`s the command so it runs as PID 1. |
| `settings.json` / `statusline.sh` | Default Claude Code settings: a status line showing the model, directory, context %, token use and cost. |
| `start-dev-env.sh` | First start / normal start (see below). |
| `restart-dev-env.sh` | Full stop + rebuild + start (see below). |
| `requirements.txt` | Python packages baked into the image (anthropic, streamlit, fastapi, flask, etc.). |

> `README.md` and `CLAUDE.md` in this folder come from the original course template. They describe port `8501`/Streamlit usage, not the Traccar setup described here.

---

## 2. Build & Run

### Mounted path

| Host | Container |
|---|---|
| `$HOME/sgdev/traccar` (the Traccar project checkout, including the `traccar-web` submodule) | `/workspace` (also the working directory) |

### Network mode

No `network_mode` is set, so the container uses Docker's **default `bridge` network**. It has outbound internet access (needed for Gradle/npm dependencies and the Claude API). The only inbound path from the host is the published port **`8080:8080`**.

### Option A: start / restart scripts (recommended)

Run them from the host. Each script `cd`s to its own directory, so it can be launched from anywhere.

```bash
./dev_test_env/start-dev-env.sh     # first start, or start after a host reboot
./dev_test_env/restart-dev-env.sh   # tear down, rebuild image, start fresh
```

| Step | `start-dev-env.sh` | `restart-dev-env.sh` |
|---|---|---|
| 1 | `docker compose config` (validate the compose file) | `docker compose down` (stop & remove the container) |
| 2 | `docker compose up -d --build` | `docker compose up -d --build` |
| 3 | `docker compose ps` (show it is running) | `docker compose ps` |
| 4 | `docker compose exec traccar-dev bash` (open a shell inside) | `docker compose exec traccar-dev bash` |

Both scripts use `set -e`, so they stop at the first failing step.

### Option B: Docker Compose manually

```bash
cd dev_test_env
docker compose up -d --build          # build the image and start the container
docker compose exec traccar-dev bash  # open a shell inside
docker compose down                   # stop and remove the container
```

### Option C: plain Docker (equivalent to the compose file)

**Build:**

```bash
docker build -t traccar-dev:latest dev_test_env
# force a clean rebuild:
docker build --no-cache -t traccar-dev:latest dev_test_env
```

**Run:**

```bash
docker run -dit \
  --name traccar-dev \
  -p 8080:8080 \
  -v "$HOME/sgdev/traccar":/workspace \
  -w /workspace \
  --restart unless-stopped \
  traccar-dev:latest sleep infinity

docker exec -it traccar-dev bash
```

### Building and running Traccar inside the container

```bash
cd /workspace
./gradlew assemble                                    # -> target/tracker-server.jar + target/lib/
./gradlew test                                        # unit tests
java -jar target/tracker-server.jar target/local.xml  # serves on port 8080
```

`target/local.xml` is a local copy of `debug.xml` with `web.port` set to `8080` (the published port) and `web.path` set to `./traccar-web/build` (the built React UI, produced by `cd traccar-web && npm install && npm run build`).

You can then reach the app from the **host machine**:

```bash
curl http://localhost:8080/api/server
# or open http://localhost:8080 in a browser
```

---

## 3. Security Decisions

- **Only the project directory is mounted.** I mounted only `$HOME/sgdev/traccar`, the directory with my project's application code. Agents running in the sandbox cannot access or modify anything else on my machine: no home directory, SSH keys, cloud credentials, other repos, or the Docker socket.
- **Port 8080 is bound to the host.** I publish `8080:8080` so I can run the application in the sandbox and test it from my local machine in the browser or with `curl`. This is a potential entry point to my machine from the sandbox, but I think it is a necessary risk to make development work possible. It is the only published port.
- **Default bridge network.** The container is not on the host network (`network_mode: host` is *not* used), so it cannot bind host ports or see host-only services beyond what Docker's bridge allows.
- **Claude login persistence.** `docker-entrypoint.sh` can persist the Claude credential through a `/claude-auth` volume, but `docker-compose.yml` does **not** currently mount one. Each new container therefore needs a fresh `claude` login, and no credential is stored outside the container. To persist the login, add `-v claude-auth:/claude-auth` (or a compose `volumes:` entry). That stores only the credential in a named Docker volume.

---

## 4. Safe Use of Agents in the Sandbox

1. **Run agents only inside the container** (`docker compose exec traccar-dev bash`, then `claude`). Never run them against the host directly.
2. **Don't widen the mounts.** Do not add mounts for `~`, `~/.ssh`, `~/.aws`, `~/.config`, or `/var/run/docker.sock`. A Docker socket mount would give the agent effective root on the host.
3. **Keep secrets out of `/workspace`.** Anything in the mounted folder is readable by the agent. Keep `.env`, `credentials.json`, `token.json` and similar files out of the project or at least in `.gitignore`.
4. **Remember that the mount is two-way.** Edits made by an agent land directly on the host copy of the repo. Review `git status` / `git diff` before committing, and be aware that `traccar-web` is a submodule with `ignore = all`, so check its changes from inside `traccar-web/`.
5. **No outward-facing actions without review.** Don't let agents `git push`, publish packages, deploy, or send data to external services unattended. Use Claude Code permission prompts or plan mode for these.
6. **Be careful with ngrok.** It is installed in the image, but running it would expose port 8080 to the public internet. Use it only on purpose.
7. **Only bind what you need.** If another port is ever needed, publish it explicitly and preferably to localhost only (`127.0.0.1:PORT:PORT`).
8. **Reset when in doubt.** `./dev_test_env/restart-dev-env.sh` throws away the container and rebuilds it from the image. Only `/workspace` (your repo) persists.

---

## 5. Smoke Test

All commands below were run inside the sandbox container from `/workspace`.

### 5.1 Created CLAUDE.md for the project (root)

```text
$ ls -l CLAUDE.md && head -5 CLAUDE.md
-rw-r--r-- 1 root root 8521 Nov 13 17:47 CLAUDE.md
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project
```

### 5.2 Created CLAUDE.md for the web submodule (`traccar-web`)

```text
$ ls -l traccar-web/CLAUDE.md && head -5 traccar-web/CLAUDE.md
-rw-r--r-- 1 root root 6047 Nov 13 17:44 traccar-web/CLAUDE.md
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project
```

### 5.3 Ran unit tests

Re-run for this document with `--rerun` so Gradle actually executes the suite instead of reporting it `UP-TO-DATE`:

```text
$ ./gradlew test --rerun --console=plain
...
> Task :compileTestJava UP-TO-DATE
> Task :processTestResources NO-SOURCE
> Task :testClasses UP-TO-DATE
> Task :test
BUILD SUCCESSFUL in 38s
11 actionable tasks: 1 executed, 10 up-to-date
```

Summary aggregated from the JUnit XML reports in `build/test-results/test/` (timestamped `2026-11-13 18:27`, i.e. this run):

```text
test classes: 429  tests: 615  failures: 0  errors: 0  skipped: 27
```

### 5.4 Built and ran the application

**Build output** (`./gradlew assemble`):

```text
$ ls -l target/tracker-server.jar && ls target/lib | wc -l
-rw-r--r-- 1 root root 4257395 Nov 13 17:22 target/tracker-server.jar
334
```

**Run** (`java -jar target/tracker-server.jar target/local.xml > target/server.log`). Startup excerpt from `target/server.log`:

```text
2026-11-13 17:54:47  INFO: Version: 6.17.0
2026-11-13 17:54:47  INFO: Starting server...
2026-11-13 17:54:48  INFO: HikariPool-1 - Added connection conn0: url=jdbc:h2:./target/database user=SA
2026-11-13 17:54:48  INFO: HikariPool-1 - Start completed.
Database is up to date, no changesets to execute
2026-11-13 17:54:56  INFO: jetty-12.1.14; built: 2026-10-02T05:48:05.032Z; git: 15cecbd757a2f6b0fdc6a8944f4c6d0020b17da0; jvm 21.0.13+9-1-deb13u2-Debian
2026-11-13 17:54:56  INFO: Started oeje10s.ServletContextHandler@3e0855b0{ROOT,/,b=file:///workspace/traccar-web/build/,a=AVAILABLE,h=oeje10s.SessionHandler@484b5a21{STARTED}}
2026-11-13 17:54:57  INFO: Started oejs.ServerConnector@4d9cf71d{HTTP/1.1, (http/1.1)}{0.0.0.0:8080}
2026-11-13 17:54:57  INFO: Started oejs.Server@5c43cb12{STARTING}[12.1.14,sto=0] @1576ms
```

Device positions received while running (OsmAnd protocol test device, truncated):

```text
2026-11-13 18:01:30  INFO: [Tf06d1d48: osmand < 0:0:0:0:0:0:0:1] GET ?id=123456789012345&timestamp=1794592889&lat=48.85378&lon=2.344347&altitude=50&bearing=34.23865107654347&speed=0&batt=64&alarm=sos&...
2026-11-13 18:01:30  INFO: [Tf06d1d48: osmand > 0:0:0:0:0:0:0:1] HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n
2026-11-13 18:01:31  INFO: [Tf06d1d48: osmand < 0:0:0:0:0:0:0:1] GET ?id=123456789012345&timestamp=1794592891&lat=48.854265&lon=2.3448486666666666&altitude=50&bearing=34.238392891102826&speed=40&batt=...
2026-11-13 18:01:31  INFO: [Tf06d1d48: osmand > 0:0:0:0:0:0:0:1] HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n
```

Live check against the running server on port 8080:

```text
$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080/api/server
HTTP 200
$ curl -s http://localhost:8080/api/server | head -c 300
{"id":1,"attributes":{},"registration":false,"readonly":false,"deviceReadonly":false,"map":null,"bingKey":null,"mapUrl":null,"overlayUrl":null,"latitude":0.0,"longitude":0.0,"zoom":0,"forceSettings":false,"coordinateFormat":null,"limitCommands":false,"disableReports":false,"fixedEmail":false,"poiLay
$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080/
HTTP 200
```
