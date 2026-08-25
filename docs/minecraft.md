# Minecraft

## Overview

Minecraft Paper is a stateful GitOps-managed workload in the `minecraft` namespace. The deployment preserves an existing world while making scheduling, configuration, secrets, logging, metrics, and public connectivity declarative.

## Components

| Resource | Purpose |
| --- | --- |
| `StatefulSet/minecraft` | Runs Paper and the metrics sidecars |
| `Service/minecraft-headless` | Stable StatefulSet network identity |
| `Service/minecraft` | Minecraft and metrics endpoints |
| `Deployment/playit` | Public TCP tunnel agent |
| `Deployment/alloy-minecraft-logs` | Sends Paper logs to central Loki |
| `PersistentVolume/minecraft-data` | Static retained local storage |
| `PersistentVolumeClaim/minecraft-data` | Binds the StatefulSet to the data volume |
| `StorageClass/minecraft-local` | No-provisioner local storage class |

## Placement and resources

The StatefulSet selects nodes labeled:

```text
workload=minecraft
```

The staging overlay requests two CPU cores and 4 GiB of memory, with a 6 GiB memory limit. The Minecraft JVM is configured for a 4 GiB working allocation.

Verify placement:

```bash
kubectl get pods -n minecraft -o wide
kubectl get node k8s-worker-01 -o jsonpath='{.metadata.labels.workload}{"\n"}'
```

## Persistent world data

The world is stored at `/srv/minecraft/data` on `k8s-worker-01`. Kubernetes mounts that directory at `/data` in the pod.

Protection layers:

- PV reclaim policy `Retain`
- Flux prune disabled on PV and PVC
- PV node affinity for `k8s-worker-01`
- StatefulSet termination grace period of 120 seconds
- Pre-stop commands announce restart and flush the world save

These controls reduce accidental data loss but do not replace backups.

## Configuration and secrets

Non-sensitive server settings are stored in ConfigMaps and staging patches. Sensitive settings are supplied by:

- `minecraft-private`
- `playit-secret`

Both are committed only as SOPS-encrypted manifests.

## Public connectivity

Playit authenticates using `playit-secret` and forwards public traffic to the stable Kubernetes Service address:

```text
minecraft:25565
```

Do not configure the tunnel with a ClusterIP. Service DNS remains stable when the Service is recreated.

Inspect connectivity:

```bash
kubectl logs -n minecraft deployment/playit --tail=100
kubectl get service,endpointslice -n minecraft
```

Repeated local-server timeouts in the Playit log usually mean the tunnel origin points to an obsolete address or the Minecraft Service has no ready endpoint.

## Health checks

```bash
kubectl get pods -n minecraft -o wide
kubectl rollout status statefulset/minecraft -n minecraft
kubectl logs -n minecraft minecraft-0 -c minecraft --tail=200
kubectl get service,endpointslice -n minecraft
```

Expected pod readiness is `3/3` for `minecraft-0`.

## Metrics endpoints

Internally, Prometheus scrapes named Service ports. External central Prometheus uses worker host ports:

| Metrics | Container port | Worker host port |
| --- | ---: | ---: |
| Paper exporter | 9940 | 9940 |
| Network/storage exporter | 9100 | 9101 |

## Planned maintenance

Before host or storage maintenance:

1. Notify players.
2. Confirm a recent backup.
3. Scale the StatefulSet to zero through Git or perform a deliberate controlled stop.
4. Verify the pod has terminated and the world save completed.
5. Perform host maintenance.
6. Restore the declared replica count and monitor startup.

Operational manifest for manual maintenance tasks is stored under `operations/minecraft` when present in the active branch.

## Recovery outline

1. Restore the filesystem containing `/srv/minecraft/data` on `k8s-worker-01`.
2. Confirm ownership is UID/GID `1000:1000`.
3. Confirm the node hostname and `workload=minecraft` label.
4. Allow Flux to recreate the StorageClass, PV, PVC, StatefulSet, Services, Playit, and Alloy resources.
5. Verify the PVC is `Bound` before expecting the pod to start.
6. Confirm the Paper log reports a completed startup.
7. Test internal metrics and public Playit connectivity.

Do not delete or reinitialize `/srv/minecraft/data` as part of routine Kubernetes recovery.