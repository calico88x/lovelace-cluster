# Minecraft Create server

This deployment provides a second Minecraft server running **All of Create 1.21.1** on NeoForge.

Paper and Create use separate workloads and storage volumes. Only one server may run at a time, while both share the existing Playit agent, public tunnel, and player-facing address.

## Current GitOps mode

The staging overlays declare Create as the active server:

| Workload            | Desired replicas |
| ------------------- | ---------------: |
| Paper StatefulSet   |                0 |
| Paper Alloy logger  |                0 |
| Create StatefulSet  |                1 |
| Create Alloy logger |                1 |
| Shared Playit agent |                1 |

`Service/minecraft-active` currently points to:

`minecraft-create.minecraft-create.svc.cluster.local`

## Deployment details

| Item                              | Value                          |
| --------------------------------- | ------------------------------ |
| Namespace                         | `minecraft-create`             |
| StatefulSet                       | `minecraft-create`             |
| Container image                   | `itzg/minecraft-server:java21` |
| Modpack platform                  | `AUTO_CURSEFORGE`              |
| CurseForge slug                   | `aoc`                          |
| Manifest file                     | `8609966`                      |
| Mod loader                        | NeoForge for Minecraft 1.21.1  |
| Initial heap                      | 4 GiB                          |
| Maximum heap                      | 6 GiB                          |
| Pod CPU request                   | 2 cores                        |
| Pod memory request                | 8 GiB                          |
| Pod memory limit                  | 9 GiB                          |
| Persistent storage                | `/srv/minecraft-create/data`   |
| PV/PVC capacity                   | 90 GiB                         |
| Minecraft metrics host port       | `9941`                         |
| Network/storage metrics host port | `9102`                         |

The deployment uses CurseForge client manifest file `8609966` rather than server-pack file `8609968`. `AUTO_CURSEFORGE` uses the client manifest to resolve the declared mod loader and mod collection.

The NeoForge Prometheus Exporter is installed through CurseForge file `5657655`.

## Shared Playit tunnel

Paper and Create share the existing public Playit tunnel so players retain the same public address and saved favorite.

The existing Playit tunnel is configured with:

* Local address: `minecraft-active.minecraft.svc.cluster.local`
* Local port: `25565`

`Service/minecraft-active` is an `ExternalName` alias controlled through GitOps.

Create mode uses:

`minecraft-create.minecraft-create.svc.cluster.local`

Paper mode uses:

`minecraft.minecraft.svc.cluster.local`

The Playit agent, Secret, public allocation, and tunnel are not recreated or scaled during a server switch.

## Secrets

Create has its own namespace-scoped Secret:

`minecraft-create/minecraft-create-private`

Its SOPS-encrypted manifest is:

`apps/staging/minecraft-create/minecraft-private.sops.yaml`

The Secret was cloned from the existing Paper configuration and safely updated using the age identity held by Lovelace.

The deployed Secret contains four keys:

* `OPS`
* `RCON_PASSWORD`
* `SEED`
* `WHITELIST`

`CF_API_KEY` is not currently stored in this Secret.

The Flux `apps` Kustomization decrypts the file using `Secret/flux-system/sops-age`. No plaintext values are stored in Git.

Create does not have a separate Playit Secret.

## Storage

Create uses a dedicated 100 GiB ext4 volume mounted at:

`/srv/minecraft-create`

The Kubernetes local PersistentVolume exposes:

`/srv/minecraft-create/data`

The PersistentVolume advertises 90 GiB and is pinned to `k8s-worker-01`.

The data directory uses UID/GID `1000:1000` with mode `2775`, matching the Minecraft container and existing Paper storage.

The PersistentVolume uses the `Retain` reclaim policy. Both the PersistentVolume and PersistentVolumeClaim are protected from Flux pruning.

The StorageClass uses `WaitForFirstConsumer`. While Create is dormant, the PVC may remain `Pending` and the PV `Available`. When Create is activated, scheduling the pod binds the claim to the retained local volume.

## Mutual-exclusion safeguards

Create has required pod anti-affinity against Paper:

* Label: `app=minecraft`
* Namespace: `minecraft`
* Topology: `kubernetes.io/hostname`

Paper has the reciprocal required pod anti-affinity against Create:

* Label: `app=minecraft-create`
* Namespace: `minecraft-create`
* Topology: `kubernetes.io/hostname`

These rules prevent both servers from scheduling concurrently on `k8s-worker-01`, even if replica counts are accidentally configured incorrectly.

Replica counts and the `minecraft-active` alias must still be changed together through GitOps.

## Switching to Create

The Create-mode GitOps change declares the following state:

1. Scale the Paper StatefulSet and Paper Alloy logger to zero.
2. Retain the shared Playit agent at one replica.
3. Apply Paper’s reciprocal anti-affinity guard.
4. Redirect `Service/minecraft-active` to the Create service.
5. Scale the Create StatefulSet and Create Alloy logger to one.

A temporary offline period is expected while Paper shuts down and the modpack downloads and initializes.

Do not use live `kubectl scale` commands against these Flux-managed workloads.

## Switching back to Paper

The reverse GitOps change must:

1. Scale the Create StatefulSet and Create Alloy logger to zero.
2. Redirect `Service/minecraft-active` to the Paper service.
3. Scale the Paper StatefulSet and Paper Alloy logger to one.
4. Keep the shared Playit agent running.

The public Playit address remains unchanged in both modes.

## Validation

Validate the Paper overlay:

`kubectl kustomize .\apps\staging\minecraft`

Validate the Create overlay:

`kubectl kustomize .\apps\staging\minecraft-create`

Validate the complete Flux application tree:

`flux build kustomization apps --path .\apps\staging`

Check repository formatting:

`git diff --check`

## References

* [itzg AUTO_CURSEFORGE documentation](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/auto-curseforge/)
* [All of Create manifest file 8609966](https://www.curseforge.com/minecraft/modpacks/aoc/files/8609966)
* [Prometheus Exporter file 5657655](https://www.curseforge.com/minecraft/mc-mods/prometheus-exporter/files/5657655)
