# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Traccar back-end server: a Java 21 GPS tracking server supporting 200+ device protocols, with a REST/WebSocket API, served via Jetty. The web UI lives in the `traccar-web` git submodule (see **Web UI** below). It has its own `traccar-web/CLAUDE.md`, so read that file before working on the UI.

## Commands

```shell
./gradlew build                      # compile, checkstyle, tests (what CI runs)
./gradlew assemble                   # builds target/tracker-server.jar + target/lib/ dependencies
./gradlew test --tests org.traccar.protocol.Gt06ProtocolDecoderTest            # single test class
./gradlew test --tests 'org.traccar.protocol.Gt06ProtocolDecoderTest.testDecode' # single method
./gradlew checkstyleMain checkstyleTest  # style only (config: gradle/checkstyle.xml)
```

Run locally: main class `org.traccar.Main`; with no args it loads `./debug.xml` (H2 DB in `./target/database`, web on port 8082, console logging). Otherwise the last argument is the config file path (production template: `setup/traccar.xml`).

## Running API and UI together locally

1. Get the submodule if it's missing: `git submodule update --init traccar-web`. Then run `npm install` in `traccar-web/`.
2. Start the back end from the repo root: `./gradlew assemble && java -jar target/tracker-server.jar`. With no arguments it loads `./debug.xml` and serves the API and WebSocket on `http://localhost:8082`. You can also run `org.traccar.Main` from the IDE, with the working directory set to the repo root.
3. Start the UI: `cd traccar-web && npm start`. The Vite dev server runs on `http://localhost:3000` with hot reload, and it proxies `/api` and `/api/socket` to `localhost:8082`. Open port 3000, not 8082.
4. On a fresh H2 database the first account you register becomes the administrator.

Notes:
- With `debug.xml`, port 8082 serves `traccar-web/simple`, a minimal standalone client, not the React app. To have Jetty serve the real UI, run `npm run build` and point `web.path` at `./traccar-web/build`. Use a local copy of the config rather than editing `debug.xml`.
- `web.localizationPath` in `debug.xml` reads `traccar-web/src/resources/l10n`, so the server uses the same translation files (for example in notifications) as the UI.
- Without the Java server, `cd traccar-web && npm run demo` runs the UI against a fake read-only API.

Code style: 4-space indent, 120-char line limit, no wildcard imports, import order `*`, then `jakarta.*`/`java.*`/`javax.*`, then static imports (see `.editorconfig`). Checkstyle failures break the build.

## Architecture

**Startup / DI.** `Main` builds a Guice injector from `MainModule` (config, managers, handlers, external services), `storage.DatabaseModule`, and `web.WebModule`, then starts lifecycle services (`ScheduleManager`, `ServerManager`, `WebServer`, `BroadcastService`). Most classes get dependencies via `@Inject` constructors; optional components return `null` from providers when not configured.

**Configuration.** All config keys are typed constants in `config/Keys.java` (`ConfigKey`/`ConfigSuffix`), read from the XML properties file via `Config`. Protocol-scoped keys use suffixes like `Keys.PROTOCOL_PORT.withPrefix("gt06")` → `gt06.port`.

**Protocols (`org.traccar.protocol`).** Each protocol `Foo` is typically:
- `FooProtocol extends BaseProtocol` — declares supported commands and adds a `TrackerServer` (TCP/UDP) whose `addProtocolHandlers` installs the Netty handlers below.
- `FooFrameDecoder` (optional) — splits the byte stream into frames (`BaseFrameDecoder` or Netty built-ins).
- `FooProtocolDecoder extends BaseProtocolDecoder` — implements `decode(...)`, resolves the device with `getDeviceSession(channel, remoteAddress, uniqueId)`, returns `Position`(s); sends acks back on the channel. Use `helper.Parser`/`PatternBuilder` for text protocols and `BitUtil`/`BufferUtil` for binary.
- `FooProtocolEncoder extends BaseProtocolEncoder` (optional) — encodes `Command`s to the device.

New protocols must be registered with a default port in the static block of `config/ProtocolConfig.java` (`put(FooProtocol.class, port)`); the protocol name is derived from the class name. `ServerManager` syncs these into `ProtocolSettings` rows in the DB and starts connectors for enabled ones.

**Netty pipeline.** `BasePipelineFactory` wraps protocol handlers with common ones (logging, acknowledgement, network forwarding) and ends with `RemoteAddressHandler` → `ProcessingHandler` → `MainEventHandler`. `ProcessingHandler` queues positions per device and runs an ordered chain of `BasePositionHandler`s (time/filter/geocoder/geofence/distance/motion/computed attributes/… → `DatabaseHandler`), then `BaseEventHandler`s that generate `Event`s (overspeed, geofence, alarm, ignition, maintenance…), which feed `NotificationManager`. Order in that list matters.

**Persistence.** `storage.Storage` abstraction (`DatabaseStorage` over JDBC/HikariCP, `MemoryStorage`) with a small query DSL in `storage/query` (`Request`, `Columns`, `Condition`, `Order`). Models in `org.traccar.model` map to tables via `@StorageName("tc_...")`. Schema is managed by Liquibase: add a new `schema/changelog-<version>.xml` and include it from `schema/changelog-master.xml` — never edit existing changelogs.

**State caching.** `session/cache/CacheManager` keeps an in-memory graph of objects (devices, groups, users, geofences, notifications…) linked by permissions for connected devices; `session/ConnectionManager` tracks device sessions and pushes updates. `broadcast/` propagates cache invalidations across clustered instances.

**API (`org.traccar.api`).** Jersey JAX-RS resources in `api/resource`, built on `BaseObjectResource`/`ExtendedObjectResource`/`SimpleObjectResource`; auth and permission checks in `api/security` (`PermissionsService`). The OpenAPI spec is `openapi.yaml` at the repo root — keep it in sync with resource changes. `web/` contains Jetty setup, WebSocket (`AsyncSocket`), and an MCP server (`McpToolRegistry`).

**Web UI (`traccar-web/`).** This is a separate git repo, checked out as a submodule with `ignore = all`, so changes inside it don't show up in this repo's `git status`. Commit and push them from inside `traccar-web/`, then bump the submodule pointer here if needed. It is a React 19 + Material UI + MapLibre + Redux Toolkit app built with Vite, written in plain JS/JSX. Its checks are `npm run lint` (zero warnings allowed) and `npm run build`. There is no test suite.
- The UI only uses this server's REST API (`api/...`, relative URLs) and the `api/session` cookie session. Live updates come from the `api/socket` WebSocket (`web/AsyncSocket`), which pushes `devices`, `positions`, `events` and `logs` JSON. When you change models, API resources or socket payloads, check the UI callers as well as `openapi.yaml`.
- UI feature toggles and preferences are stored as `attributes` on the server and user models (for example `ui.disable*`, `forceSettings`), so the back end needs no schema change for them.
- `index.html` contains `${title}`, `${description}`, `${colorPrimary}` and `${customHead}` placeholders, which `web/OverrideTextFilter` fills in when it serves the page. Branding overrides come from `web.override`.
- UI strings: add new keys only to `traccar-web/src/resources/l10n/en.json`. The other languages come from Transifex.

**Other subsystems** each in their own package with pluggable implementations chosen by config: `geocoder`, `geolocation`, `mapmatcher`, `speedlimit`, `forward` (position/event forwarding: HTTP, Kafka, MQTT, AMQP, Redis…), `notificators` (mail, SMS, push, Telegram…), `sms`, `reports` (Excel via JXLS templates in `templates/export`), `notification` (Velocity templates in `templates/notifications`), `command`, `schedule`.

## Tests

JUnit 5 + Mockito under `src/test/java`. Protocol tests extend `ProtocolTest`: decoder/frame tests call `verifyDecode(decoder, input, expectations...)` with inputs built by `binary("hex...")`, `text(...)`, `buffer(...)` or `request(...)`, and expectations like `position(Checks.ATTRIBUTES).attribute(Position.KEY_..., value)`; encoder tests use `verifyEncode`. When adding/changing a decoder, add a sample message from the real device to the corresponding `*ProtocolDecoderTest`.

`tools/` has Python helper scripts (integration test against a running server, test data generators, config doc generation).
