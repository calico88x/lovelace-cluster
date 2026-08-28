# Minecraft Create server

This deployment provides a second Minecraft server running **All of Create 1.21.1** on NeoForge.

It shares the existing Paper server's public Playit tunnel and address, but Paper and Create must never run concurrently.

## Deployment details

| Item | Value |
| --- | --- |
| Namespace | `minecraft-create` |
| StatefulSet | `minecraft-create` |
| Container image | `itzg/minecraft-server:java21` |
| Modpack platform | `AUTO_CURSEFORGE` |
| CurseForge slug | `aoc` |
| Manifest file | `8609966` |
| Mod loader | NeoForge for Minecraft 1.21.1 |
| Initial heap | 4 GiB |
| Maximum heap | 6 GiB |
| Pod CPU request | 2 cores |
| Pod memory request | 8 GiB |
| Pod memory limit | 9 GiB |
| Persistent storage | `/srv/minecraft-create/data` |
| PV/PVC capacity | 90 GiB |
| Minecraft metrics host port | `9941` |
| Network/storage metrics host port | `9102` |

The deployment uses CurseForge client manifest file `8609966` rather than server-pack file `8609968`. `AUTO_CURSEFORGE` uses the client manifest to resolve the declared mod loader and mod collection.

The NeoForge Prometheus Exporter is installed through CurseForge file `5657655`.

## Initial GitOps state

Flux automatically discovers the `apps/staging/minecraft-create` overlay beneath its configured `./apps/staging` path.

The initial scaffold renders these workloads with zero replicas:

- `StatefulSet/minecraft-create`
- `Deployment/alloy-minecraft-create-logs`

Merging the scaffold creates the namespace, configuration, services, storage resources, encrypted Secret, and dormant controllers. It does not start Create.

Paper remains active. Its StatefulSet, Alloy logger, Playit agent, Playit Secret, and public tunnel are not modified by the initial scaffold.

## Shared Playit tunnel

Paper and Create share the existing public Playit tunnel so players retain the same public address and saved favorite.

The existing Playit agent remains in the `minecraft` namespace. Its stable internal destination is:

`minecraft-active.minecraft.svc.cluster.local:25565`

`Service/minecraft-active` is an `ExternalName` alias. Initially it points to Paper:

`minecraft.minecraft.svc.cluster.local`

When Create becomes active, GitOps changes the alias to:

`minecraft-create.minecraft-create.svc.cluster.local`

The Playit agent, Secret, tunnel, and public address are never recreated or scaled during a server switch.

After the scaffold is merged and Flux creates `Service/minecraft-active`, update the existing Playit tunnel's local destination once:

- Local address: `minecraft-active.minecraft.svc.cluster.local`
- Local port: `25565`

The public Playit address must remain unchanged.

## Secrets

Create has its own namespace-scoped Secret:

`minecraft-create/minecraft-create-private`

Its encrypted manifest is:

`apps/staging/minecraft-create/minecraft-private.sops.yaml`

It was cloned from the existing Paper Secret and updated using the Lovelace cluster's SOPS age identity.

The encrypted values include:

- `OPS`
- `WHITELIST`
- `RCON_PASSWORD`
- `SEED`
- `CF_API_KEY`

The Flux `apps` Kustomization decrypts the file using `Secret/flux-system/sops-age`.

Create does not have a separate Playit Secret.

## Storage

The local PersistentVolume uses `/srv/minecraft-create/data` and is pinned to `k8s-worker-01`.

The PersistentVolume uses the `Retain` reclaim policy. Both the PersistentVolume and PersistentVolumeClaim are protected from Flux pruning.

The StorageClass uses `WaitForFirstConsumer`, so the PVC may remain `Pending` while the Create StatefulSet has zero replicas. That is expected.

Before the first start, verify that `/srv/minecraft-create/data` exists on `k8s-worker-01`, has sufficient free space, and is writable by the Minecraft container.

## Mutual-exclusion safeguards

The Create pod has required pod anti-affinity against the Paper pod. Create cannot schedule on `k8s-worker-01` while Paper is present.

During the first switch, Paper will receive a reciprocal required anti-affinity rule while its replica count is zero. This prevents Paper from later scheduling while Create is active without restarting Paper during the initial scaffold deployment.

Replica counts, anti-affinity, and the active-service alias must always be changed together through GitOps.

## First switch to Create

The first switch will be a separate GitOps change after the dormant scaffold is merged and verified.

That change will:

1. Scale the Paper StatefulSet and Paper Alloy logger to zero.
2. Add Paper's reciprocal anti-affinity rule while Paper is stopped.
3. Change `Service/minecraft-active` to the Create service hostname.
4. Scale the Create StatefulSet and Create Alloy logger to one.
5. Keep the existing Playit agent running.
6. Validate both overlays and the complete Flux staging build before merge.

A temporary offline period is expected while Paper shuts down and the modded server initializes.

Do not use live `kubectl scale` commands against Flux-managed workloads.

## Switching back to Paper

The reverse GitOps change will:

1. Scale the Create StatefulSet and Create Alloy logger to zero.
2. Change `Service/minecraft-active` back to the Paper service hostname.
3. Scale the Paper StatefulSet and Paper Alloy logger to one.
4. Keep the shared Playit agent running.

The public Playit address remains unchanged in both modes.

## Validation

Validate the Create overlay:

`kubectl kustomize .\apps\staging\minecraft-create`

Validate the complete Flux application tree:

`flux build kustomization apps --path .\apps\staging`

Check repository formatting:

`git diff --check`

## References

- [itzg AUTO_CURSEFORGE documentation](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/auto-curseforge/)
- [All of Create manifest file 8609966](https://www.curseforge.com/minecraft/modpacks/aoc/files/8609966)
- [Prometheus Exporter file 5657655](https://www.curseforge.com/minecraft/mc-mods/prometheus-exporter/files/5657655)
