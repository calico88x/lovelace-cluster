# Operations and Recovery

## Routine health checks

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
flux get sources git -A
flux get kustomizations -A
flux get helmreleases -A
```

All nodes should report `Ready`, Flux objects should report `Ready=True`, and workloads should be running on their intended nodes.

## Inspect a reconciliation failure

```bash
flux get kustomizations -A
flux logs --level=error --since=30m
kubectl describe kustomization <name> -n flux-system
```

For a Helm deployment:

```bash
flux get helmreleases -A
kubectl describe helmrelease <name> -n <namespace>
kubectl logs -n flux-system deployment/helm-controller --since=30m
```

## Force reconciliation

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization <name> --with-source
```

For a HelmRelease:

```bash
flux reconcile helmrelease <name> -n <namespace> --with-source
```

## Workload troubleshooting

```bash
kubectl get pods -n <namespace> -o wide
kubectl describe pod -n <namespace> <pod>
kubectl logs -n <namespace> <pod> -c <container> --tail=200
kubectl get events -n <namespace> --sort-by=.lastTimestamp
```

For a Deployment or StatefulSet rollout:

```bash
kubectl rollout status deployment/<name> -n <namespace>
kubectl rollout status statefulset/<name> -n <namespace>
```

## Node operations

Confirm labels before diagnosing scheduling:

```bash
kubectl get nodes --show-labels
```
The logical scheduling pools currently require these node labels:

```text
lovelace        novalabs.io/node-pool=core
k8s-worker-01   novalabs.io/node-pool=worker
```

These labels are consumed by stateless workload scheduling patches. Node-local stateful workloads such as Minecraft, Minecraft Create, Liquidsoap, and radio-library-sync use explicit `kubernetes.io/hostname` placement instead.

If a node is rebuilt or rejoined to the cluster, restore its logical pool label before allowing Flux-managed workloads to reconcile onto it.

Minecraft and Minecraft Create are explicitly pinned to `k8s-worker-01` using `kubernetes.io/hostname`. Their static local PersistentVolumes also have node affinity for that hostname. Relocating either workload therefore requires coordinated changes to workload placement, storage, and data.

Before planned node maintenance:

```bash
kubectl cordon <node>
```

Do not drain `k8s-worker-01` expecting Minecraft to move automatically; its local PV is not portable. Stop or scale the workload deliberately and preserve the data first.

After maintenance:

```bash
kubectl uncordon <node>
```

## Storage checks

```bash
kubectl get pv,pvc -A
kubectl describe pv minecraft-data
kubectl describe pvc minecraft-data -n minecraft
```

On the worker:

```bash
findmnt -T /srv/minecraft/data
df -hT /srv/minecraft/data
stat -c '%U:%G %u:%g %a %n' /srv/minecraft/data
```

Minecraft data should remain owned by UID/GID `1000:1000` unless the container configuration is intentionally changed.

## Backup priorities

At minimum, back up:

- `/srv/minecraft/data` from `k8s-worker-01`
- Age private-key recovery material
- Forgejo repository and database
- Application PVC data for Audiobookshelf and Linkding
- External monitoring configuration maintained on the Docker LXC

Git protects desired state, not runtime data.

## Safe rollback

Prefer reverting the offending commit through Forgejo:

```bash
git revert <commit>
git push
```

After the revert reaches `main`, Flux returns the cluster to the previous declared state. Avoid destructive Git operations and avoid deleting retained storage as part of an application rollback.

## Decommissioning a workload

1. Identify all namespaced and cluster-scoped resources.
2. Back up persistent data.
3. Review reclaim policies and Flux prune annotations.
4. Remove the workload from its parent Kustomization in a pull request.
5. Confirm the rendered deletion scope before merging.
6. Remove retained PVs or host data only through a separate, explicit operation.