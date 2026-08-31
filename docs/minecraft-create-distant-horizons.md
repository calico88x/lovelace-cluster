# Distant Horizons — Create Minecraft Server

This document records the Distant Horizons configuration and operating practices for the CalicoNet Create Minecraft server running in the `minecraft-create` Kubernetes namespace.

The goal is to provide rich server-generated LODs without allowing background generation, client synchronization, or modded world generation to overwhelm the Minecraft server.

> **Configuration snapshot:** 2026-08-31  
> **Distant Horizons:** 3.2.0-b  
> **Minecraft:** 1.21.1  
> **Mod loader:** NeoForge  
> **Deployment:** `statefulset/minecraft-create`  
> **Pod:** `minecraft-create-0`  
> **Container:** `minecraft-create`

## Current operating profile

The server currently uses the following high-level profile:

- Distant generation is enabled.
- Generation mode is `FEATURES`.
- DH is limited to one generation thread.
- That thread may run continuously while work is queued.
- Real-time LOD updates are enabled.
- Join-time LOD synchronization is disabled.
- No explicit pregeneration job is running.
- Generation bounds are disabled, so client render distance determines the requested area.

This profile was chosen after testing showed that two DH generation threads caused heavy CPU activity, slow chunk delivery, and player timeouts. Reducing DH to one thread significantly improved server behavior while preserving background LOD generation.

## How this configuration behaves

When a DH-enabled player connects, the client requests distant terrain around its position. The server checks its persistent LOD database and generates missing data according to `generation.mode`.

With the current `FEATURES` mode, DH generates terrain and world features but does not guarantee complete Minecraft structures. It does not save fully generated Minecraft chunks to region files. Normal Minecraft chunks remain authoritative when a player approaches an area.

Automatic distant generation is primarily driven by connected clients. After the last player disconnects, DH may finish queued generation, LOD building, propagation, and database writes, but it does not inherently crawl the entire world forever. An explicit `/dh pregen` job is the mechanism for unattended generation across a defined area.

## Generation settings

| Command setting | Config-file setting | Value | Operational meaning |
| --- | --- | ---: | --- |
| `generation.enable` | `enableDistantGeneration` | `true` | Allows DH to import or generate missing LOD data outside vanilla render distance. |
| `generation.mode` | `distantGeneratorMode` | `FEATURES` | Generates terrain and features, but not guaranteed complete structures. Does not save full Minecraft chunks. |
| `generation.logInterval` | `generationProgressDisplayIntervalInSeconds` | `2` | Reports generation progress every two seconds while active. |
| `generation.bounds.centerChunk.x` | `generationCenterChunkX` | `0` | X-coordinate of the optional generation-bounds center, measured in chunks. |
| `generation.bounds.centerChunk.z` | `generationCenterChunkZ` | `0` | Z-coordinate of the optional generation-bounds center, measured in chunks. |
| `generation.bounds.radiusInChunks` | `generationMaxChunkRadius` | `0` | Disables fixed generation bounds; requested render distance is used instead. |
| `generation.requestRateLimit` | `generationRequestRateLimit` | `20` | Each client may submit up to 20 generation requests per second; this also limits its queued requests. |
| `generation.maxRequestDistance` | `maxGenerationRequestDistance` | `4096` | Server accepts generation requests up to 4,096 chunks, or 65,536 blocks, from a player. |
| `generation.nSized` | `enableNSizedGeneration` | `false` | Experimental lower-detail generation is disabled. |

### Generation modes

| Mode | Behavior | Suitability for this server |
| --- | --- | --- |
| `PRE_EXISTING_ONLY` | Creates LODs only from chunks that already exist. | Too limited for the desired background world discovery. |
| `SURFACE` | Generates terrain surface without trees or structures. | Best performance, but visually too sparse for this modpack. |
| `FEATURES` | Generates terrain and features, excluding guaranteed structures. | **Current choice.** Richer distant terrain with acceptable load at one thread. |
| `INTERNAL_SERVER` | Asks Minecraft to generate and save complete chunks. | Most compatible but considerably heavier; not currently appropriate during normal play. |

## Threading and CPU limits

| Command setting | Config-file setting | Value | Operational meaning |
| --- | --- | ---: | --- |
| `threading.numberOfThreads` | `numberOfThreads` | `1` | DH has one primary worker for its background task pools. |
| `threading.threadRunTimeRatio` | `threadRunTimeRatio` | `1.0` | The worker is not deliberately paused while work is queued. |
| `common.threadPreset` | N/A | Query error | `dh config common.threadPreset` returns an unexpected error in DH 3.2.0-b. Manual thread settings remain valid and authoritative. |

One DH thread does not impose a strict one-core limit on the entire Java process. DH may invoke Minecraft or modded-world-generation code that uses other worker pools. It does, however, prevent DH from issuing multiple primary generation jobs concurrently and has proven to be the most important stability control for this server.

If one thread still becomes disruptive, reduce its duty cycle rather than adding or removing fractional threads:

```text
dh config threading.threadRunTimeRatio 0.5
```

The current `1.0` value is performing well and should remain unchanged unless monitoring shows renewed generation pressure.

## Level identity

| Command setting | Config-file setting | Value | Operational meaning |
| --- | --- | --- | --- |
| `levelKeys.send` | `sendLevelKeys` | `true` | Sends a stable level key for each dimension to DH clients. |
| `levelKeys.serverKey` | `serverKey` | Empty | Clients choose the local server LOD folder identity. This is acceptable because the endpoint is stable. |
| `levelKeys.prefix` | `levelKeyPrefix` | Empty | Level identity falls back to the server seed hash. No backend proxy prefix is required. |

Changing `serverKey` requires players to reconnect before the new identity takes effect. Changing either identity value may cause clients to begin using a different local LOD cache.

## Client updates and synchronization

| Command setting | Config-file setting | Value | Operational meaning |
| --- | --- | ---: | --- |
| `realTimeUpdates.enable` | `enableRealTimeUpdates` | `true` | Sends LOD changes for modified distant chunks to connected clients. |
| `realTimeUpdates.playerDistance` | `realTimeUpdateDistanceRadiusInChunks` | `256` | Real-time updates are sent within 256 chunks, or 4,096 blocks, of each player. |
| `syncOnLoad.enable` | `synchronizeOnLoad` | `false` | Prevents bulk synchronization when a player joins or loads an LOD area. |
| `syncOnLoad.rateLimit` | `syncOnLoadRateLimit` | `50` | Would permit 50 synchronization requests per second if synchronization were enabled. |
| `syncOnLoad.maxRequestDistance` | `maxSyncOnLoadRequestDistance` | `4096` | Would allow synchronization within 4,096 chunks if synchronization were enabled. |

`syncOnLoad.enable=false` is intentional. With synchronization enabled, joining players experienced timeouts while the server attempted to supply a large amount of existing LOD data. Disabling it removed that join-time burst.

Clients may still:

- render LODs already stored in their local cache;
- request and receive newly generated LODs during normal play;
- receive real-time changes while connected.

## Network limits

| Command setting | Config-file setting | Value | Operational meaning |
| --- | --- | ---: | --- |
| `common.playerBandwidthLimit` | `playerBandwidthLimit` | `500` | Limits each player to 500 KB/s of server-to-client LOD traffic. |
| `common.globalBandwidthLimit` | `globalBandwidthLimit` | `0` | No separate global DH bandwidth cap is configured. |

The per-player cap remains effective even though the global cap is unlimited. If several DH clients connect simultaneously, their combined traffic can exceed 500 KB/s because the cap applies separately to each player.

## Logging

| Command setting | Config-file setting | Value |
| --- | --- | ---: |
| `logging.globalFileMaxLevel` | `globalFileMaxLevel` | `INFO` |
| `logging.globalChatMaxLevel` | `globalChatMaxLevel` | `ERROR` |
| `logging.logWorldGenEvent` | `logWorldGenEventToFile` | `INFO` |
| `logging.logWorldGenLoadEvent` | `logWorldGenChunkLoadEventToFile` | `INFO` |
| `logging.logNetworkEvent` | `logNetworkEventToFile` | `INFO` |
| `logging.logConnectionConfigChanges` | `logConnectionConfigChangesToFile` | `WARN` |

This profile keeps useful diagnostic information in files while restricting in-game chat output to errors.

## Operational snapshot

At capture time, pregeneration was not running and all queues were idle:

```text
Pregen is not running
Chunk Update Queues: 0/3
```

DH reported three loaded levels:

- `minecraft:overworld`
- `minecraft:the_nether`
- `minecraft:the_end`

### Cumulative task statistics

These counters are cumulative for the current server process and reset when the Minecraft process restarts.

| Task pool | Queued | Completed | Active | Average time |
| --- | ---: | ---: | ---: | ---: |
| World Gen/Import | 0 | 11,017 | 0/1 | 789 ms |
| Render Load | 0 | 29,594 | 0/1 | 1 ms |
| File Handler | 0 | 0 | 0/1 | <1 ms |
| Update Propagator | 0 | 131,334 | 0/1 | 43 ms |
| LOD Builder | 0 | 852,440 | 0/1 | 4 ms |
| Networking | 0 | 18,561 | 0/1 | 2 ms |

The important state is that every pool was at `0` queued and `0/1` active. DH had completed its currently requested work and was idle.

## Persistent files and storage

### Installed mod

```text
/data/mods/DistantHorizons-3.2.0-b-1.21.1-fabric-neoforge.jar
```

Installed JAR size: approximately 29 MiB.

### Configuration

```text
/data/config/DistantHorizons.toml
```

Configuration size at capture time: approximately 36 KiB.

Commands executed through `dh config` update DH's runtime configuration. Because the configuration resides under `/data`, it is retained by the Minecraft persistent volume across pod replacement and restart. Flux does not independently detect or reconcile these in-volume changes.

### LOD databases

| Dimension | Primary database | Captured size |
| --- | --- | ---: |
| Overworld | `/data/world/data/DistantHorizons.sqlite` | 2.7 GiB |
| Nether | `/data/world/DIM-1/data/DistantHorizons.sqlite` | 747 MiB |
| End | `/data/world/DIM1/data/DistantHorizons.sqlite` | 56 KiB |

Total primary LOD database usage was approximately 3.4 GiB, excluding small SQLite sidecar files.

SQLite may maintain these companion files:

```text
DistantHorizons.sqlite-wal
DistantHorizons.sqlite-shm
```

The main database, write-ahead log, and shared-memory file form one consistent database state. Backups should be taken after a clean Minecraft shutdown whenever possible. If files are copied from a live server, the database and its `-wal` and `-shm` companions must remain together.

Deleting a DH database removes generated LOD data for that dimension. It does not delete the corresponding Minecraft world, but DH would need to rebuild or re-import its visual data.

## Known visual limitations

### Partial modded structures

Some modded structures appear partly constructed in distant LODs and become complete when their real Minecraft chunks load. This is expected with `FEATURES` mode.

Modded world generation may divide a structure across:

- configured features;
- structure templates and pieces;
- post-processing stages;
- block entities;
- entities;
- mod-specific callbacks performed during full chunk generation.

DH's lightweight feature generation may observe only part of that pipeline. When Minecraft loads the real chunk, it performs the authoritative generation process and the complete structure appears. The partial version exists in the LOD cache and does not mean that the saved world is damaged.

### Create machinery and dynamic blocks

LOD geometry is simplified and is not a complete simulation of:

- moving Create contraptions;
- animated machinery;
- entities and mobs;
- block-entity state;
- redstone or kinetic simulation.

Nearby vanilla chunks remain responsible for accurate rendering and interaction.

## Java memory and garbage collection

DH detected the G1 garbage collector at startup. G1 is Java's default general-purpose collector and reclaims temporary world-generation and LOD-building objects after they become unreachable.

High DH concurrency previously caused a high allocation rate. Even when total memory was below the container limit, frequent allocation and collection could delay chunk processing and contribute to player timeouts. Limiting DH to one thread reduced that pressure.

The server may legitimately show a sawtooth heap pattern:

1. generation allocates temporary objects;
2. heap usage rises;
3. garbage collection reclaims unreachable objects;
4. heap usage falls.

This differs from a true leak, where retained memory continues growing and does not fall after generation becomes idle. AllTheLeaks reports should be evaluated over time and after DH queues are idle; a single `Memory Leaks detected` message is not sufficient evidence of unbounded growth.

DH recommends a concurrent collector such as ZGC for Java 21 when GC pauses cause stuttering. G1 remains in use because the one-thread configuration has already restored stable behavior. A collector change should be tested through GitOps and compared against measured pause time rather than made solely because DH prints a startup warning.

## Operator commands

Commands sent through RCON do not include the leading `/` used in Minecraft chat.

### Show current DH activity

```bash
kubectl -n minecraft-create exec minecraft-create-0 \
  -c minecraft-create -- \
  rcon-cli "dh debug"
```

### Check pregeneration

```bash
kubectl -n minecraft-create exec minecraft-create-0 \
  -c minecraft-create -- \
  rcon-cli "dh pregen status"
```

### Query a setting

```bash
kubectl -n minecraft-create exec minecraft-create-0 \
  -c minecraft-create -- \
  rcon-cli "dh config generation.mode"
```

### Set the approved generation profile

```bash
kubectl -n minecraft-create exec minecraft-create-0 \
  -c minecraft-create -- \
  rcon-cli "dh config generation.mode FEATURES"
```

```bash
kubectl -n minecraft-create exec minecraft-create-0 \
  -c minecraft-create -- \
  rcon-cli "dh config threading.numberOfThreads 1"
```

```bash
kubectl -n minecraft-create exec minecraft-create-0 \
  -c minecraft-create -- \
  rcon-cli "dh config threading.threadRunTimeRatio 1.0"
```

### Temporarily stop automatic distant generation

```bash
kubectl -n minecraft-create exec minecraft-create-0 \
  -c minecraft-create -- \
  rcon-cli "dh config generation.enable false"
```

Re-enable it with the same command using `true`. A server restart is not required for these DH configuration changes.

## Pregeneration safety

No explicit pregen job is currently running.

Before starting pregeneration:

1. Define and verify the intended dimension, center, and radius.
2. Confirm adequate free storage on the Create server volume.
3. Confirm no players are online, or notify them of possible generation lag.
4. Keep DH at one thread unless deliberately performing a monitored maintenance run.
5. Monitor `dh debug`, pod CPU, heap usage, and server logs.

The current `generation.bounds.radiusInChunks=0` means fixed bounds are disabled. Do not start an unattended pregeneration job until its scope and command syntax have been explicitly reviewed.

## Troubleshooting indicators

Investigate DH if any of the following return:

- players repeatedly time out while joining or exploring;
- `Can't keep up` or watchdog warnings appear;
- `dh debug` shows a growing generation or update queue;
- heap usage rises continuously after all DH work becomes idle;
- CPU remains saturated while no players are connected;
- `DH-World Gen Thread` errors begin repeating rapidly;
- LOD database growth unexpectedly consumes the persistent volume.

First-response actions should be conservative:

1. Check `dh debug`.
2. Confirm `threading.numberOfThreads` remains `1`.
3. Confirm `syncOnLoad.enable` remains `false`.
4. Temporarily set `generation.enable=false` if DH is actively destabilizing the server.
5. Preserve logs and metrics before restarting.

## Configuration rationale and history

| Configuration | Result |
| --- | --- |
| `FEATURES`, two threads | Rich LODs, but excessive generation activity, delayed chunks, and client timeouts. |
| `SURFACE`, reduced concurrency | Better performance, but missing desired terrain features. |
| `PRE_EXISTING_ONLY` | Did not meet the requirement to generate LOD terrain ahead of exploration. |
| `FEATURES`, one thread | **Current configuration.** Richer LODs with substantially cleaner logs and improved gameplay. |
| `syncOnLoad=true` | Large join/load synchronization contributed to player timeouts. |
| `syncOnLoad=false` | Reliable joins while retaining ongoing generation and real-time updates. |

## Re-auditing the configuration

The following settings should be captured after a DH upgrade or major performance change:

```text
generation.enable
generation.mode
generation.logInterval
generation.bounds.centerChunk.x
generation.bounds.centerChunk.z
generation.bounds.radiusInChunks
generation.requestRateLimit
generation.maxRequestDistance
generation.nSized
threading.numberOfThreads
threading.threadRunTimeRatio
levelKeys.send
levelKeys.serverKey
levelKeys.prefix
realTimeUpdates.enable
realTimeUpdates.playerDistance
syncOnLoad.enable
syncOnLoad.rateLimit
syncOnLoad.maxRequestDistance
common.playerBandwidthLimit
common.globalBandwidthLimit
logging.globalFileMaxLevel
logging.globalChatMaxLevel
logging.logWorldGenEvent
logging.logWorldGenLoadEvent
logging.logNetworkEvent
logging.logConnectionConfigChanges
```

Also record:

```text
dh pregen status
dh debug
```

## References

- [Distant Horizons project and multiplayer FAQ](https://modrinth.com/mod/distanthorizons)
- [Distant Horizons server-owner documentation](https://gitlab.com/distant-horizons-team/distant-horizons/-/wikis/1-user-guide/1-frequently-asked-questions/5-server-owners/Server-Owners)
- [Oracle Java 21 G1 documentation](https://docs.oracle.com/en/java/javase/21/gctuning/garbage-first-g1-garbage-collector1.html)
- [Oracle Java 21 garbage-collector overview](https://docs.oracle.com/en/java/javase/21/gctuning/available-collectors.html)
