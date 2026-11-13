# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Traccar back-end server: a Java 21 GPS tracking server supporting 200+ device protocols, with a REST/WebSocket API, served via Jetty. The web UI lives in the separate `traccar-web` git submodule (often not checked out); `debug.xml` expects it at `./traccar-web`.

## Commands

```shell
./gradlew build                      # compile, checkstyle, tests (what CI runs)
./gradlew assemble                   # builds target/tracker-server.jar + target/lib/ dependencies
./gradlew test --tests org.traccar.protocol.Gt06ProtocolDecoderTest            # single test class
./gradlew test --tests 'org.traccar.protocol.Gt06ProtocolDecoderTest.testDecode' # single method
./gradlew checkstyleMain checkstyleTest  # style only (config: gradle/checkstyle.xml)
```

Run locally: main class `org.traccar.Main`; with no args it loads `./debug.xml` (H2 DB in `./target/database`, web on port 8082, console logging). Otherwise the last argument is the config file path (production template: `setup/traccar.xml`).

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

**Other subsystems** each in their own package with pluggable implementations chosen by config: `geocoder`, `geolocation`, `mapmatcher`, `speedlimit`, `forward` (position/event forwarding: HTTP, Kafka, MQTT, AMQP, Redis…), `notificators` (mail, SMS, push, Telegram…), `sms`, `reports` (Excel via JXLS templates in `templates/export`), `notification` (Velocity templates in `templates/notifications`), `command`, `schedule`.

## Tests

JUnit 5 + Mockito under `src/test/java`. Protocol tests extend `ProtocolTest`: decoder/frame tests call `verifyDecode(decoder, input, expectations...)` with inputs built by `binary("hex...")`, `text(...)`, `buffer(...)` or `request(...)`, and expectations like `position(Checks.ATTRIBUTES).attribute(Position.KEY_..., value)`; encoder tests use `verifyEncode`. When adding/changing a decoder, add a sample message from the real device to the corresponding `*ProtocolDecoderTest`.

`tools/` has Python helper scripts (integration test against a running server, test data generators, config doc generation).
