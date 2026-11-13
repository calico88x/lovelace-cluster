# Lovelace Cluster

Lovelace is a two-node, heterogeneous [K3s](https://k3s.io/) Kubernetes cluster managed declaratively with [Flux](https://fluxcd.io/). A Raspberry Pi 5 provides the ARM64 control plane, and a Debian x86_64 worker runs application workloads and hosts node-local application data.

**Forgejo is the authoritative Git repository.** Changes go through pull requests, reach `main` after review, and are reconciled by Flux. GitHub is an external mirror, not a separate deployment source.

## Architecture

### 1. `flux-system` — GitOps control plane

Controllers and reconciliation boundaries; lines indicate declared controller relationships, not observed network flows.

```mermaid
flowchart TB
    forgejo["Forgejo main<br/>Authoritative GitOps source"]
    helmreleases["HelmReleases<br/>Monitoring and infrastructure"]
    deployed["Applications and platform resources<br/>Across the cluster"]

    subgraph fluxns["Namespace: flux-system · core node"]
        git["GitRepository / flux-system"]
        source["Deployment / source-controller<br/>1/1"]
        kustomize["Deployment / kustomize-controller<br/>1/1"]
        helm["Deployment / helm-controller<br/>1/1"]
        notify["Deployment / notification-controller<br/>1/1"]
        apps["Kustomization / apps"]
        infra["Kustomization / infrastructure-controllers"]
        monctl["Kustomization / monitoring-controllers"]
        moncfg["Kustomization / monitoring-configs"]
        git --> source
        source -.->|Source artifacts| kustomize
        kustomize --> apps
        kustomize --> infra
        kustomize --> monctl
        kustomize --> moncfg
        monctl -.->|Applies chart definitions| helmreleases
    end

    forgejo -->|Fetch revision| git
    apps --> deployed
    infra --> deployed
    monctl --> deployed
    moncfg --> deployed
    helm --> helmreleases

    classDef workload stroke:#16a34a,stroke-width:2px
    classDef external stroke:#64748b,stroke-dasharray:3 3
    class source,kustomize,helm,notify workload
    class forgejo,helmreleases,deployed external
```

### 2. `minecraft` — Paper (dormant) and shared Playit tunnel

Paper and its Alloy logger are scaled to zero; Playit remains active and points to the Create server through the ExternalName alias.

```mermaid
flowchart TB
    players["Minecraft players"] --> edge["Playit public edge"]
    createSvc["Service / minecraft-create<br/>Namespace: minecraft-create"]
    disk["Host directory<br/>k8s-worker-01 /srv/minecraft/data"]
    pv[("PV / minecraft-data<br/>60 GiB · Retain · local")]

    subgraph ns["Namespace: minecraft"]
        playit["Deployment / playit<br/>1/1 · core"]
        alias["Service / minecraft-active<br/>ExternalName to Create"]
        paperSvc["Services / minecraft + headless<br/>Paper endpoints inactive"]
        paper["StatefulSet / minecraft<br/>0 replicas · stopped"]
        alloy["Deployment / alloy-minecraft-logs<br/>0 replicas · stopped"]
        pvc["PVC / minecraft-data<br/>Static local storage"]
        config["ConfigMaps + SOPS Secrets<br/>Paper and Playit configuration"]
        playit --> alias
        paperSvc -.-> paper
        paper -.->|Mounts when active| pvc
        config -.-> paper
        config -.-> playit
        alloy -.->|Dormant log collection| paper
    end

    edge --> playit
    alias -->|DNS alias| createSvc
    pvc --> pv --> disk

    classDef workload stroke:#16a34a,stroke-width:2px
    classDef dormant stroke:#94a3b8,stroke-width:2px,stroke-dasharray:5 5
    classDef storage stroke:#2563eb,stroke-width:2px
    classDef external stroke:#64748b,stroke-dasharray:3 3
    class playit workload
    class paper,paperSvc,alloy dormant
    class pvc,pv,disk storage
    class players,edge,createSvc external
```

### 3. `minecraft-create` — Active NeoForge server, storage, and logging

The four application containers run in one StatefulSet Pod. Its PVC is namespaced, but its PV is cluster-scoped and physically anchored to k8s-worker-01.

```mermaid
flowchart TB
    alias["minecraft-active alias<br/>Namespace: minecraft"]
    loki["Docker LXC<br/>Loki :3100"]
    central["Docker LXC monitoring<br/>Exporter endpoints"]
    pv[("PV / minecraft-create-data<br/>90 GiB · Retain · local")]
    disk["Host directory<br/>k8s-worker-01 /srv/minecraft-create/data"]

    subgraph ns["Namespace: minecraft-create · worker"]
        svc["Services / minecraft-create<br/>+ headless"]
        sts["StatefulSet / minecraft-create<br/>1/1"]
        subgraph pod["Pod: minecraft-create-0 · 4/4 containers"]
            game["NeoForge / All of Create<br/>Game server"]
            scan["Storage metrics collector"]
            net["Network exporter"]
            dh["Distant Horizons metrics collector"]
        end
        pvc["PVC / minecraft-create-data<br/>Static local storage"]
        cfg["ConfigMaps + SOPS Secret<br/>Modpack, server, RCON"]
        alloy["Deployment / alloy-minecraft-create-logs<br/>1/1"]
        svc --> sts --> game
        game -->|World and mod data| pvc
        scan -.->|Read-only scan| pvc
        dh -.->|RCON metrics| game
        cfg -.-> game
        alloy -.->|Reads Pod logs| game
    end

    alias --> svc
    pvc --> pv --> disk
    alloy -->|Log delivery| loki
    game -.->|Application metrics| central
    net -.->|Network metrics| central

    classDef workload stroke:#16a34a,stroke-width:2px
    classDef storage stroke:#2563eb,stroke-width:2px
    classDef external stroke:#64748b,stroke-dasharray:3 3
    class sts,game,alloy workload
    class pvc,pv,disk storage
    class alias,loki,central external
```

### 4. `linkding` — Public tunnel, private ingress, and worker-local SQLite data

Public Cloudflare Tunnel traffic connects directly to the Linkding Service; private LAN traffic goes through Traefik and a separate Kubernetes Ingress.

```mermaid
flowchart TB
    public["Public web users"] --> cf["Cloudflare edge"]
    private["Private LAN clients"] --> traefik["Traefik ingress controller"]
    pv[("PV · dynamically provisioned<br/>local-path · 1 GiB")]
    disk["Worker host directory<br/>/var/lib/rancher/k3s/storage/..."]

    subgraph ns["Namespace: linkding · worker"]
        tunnel["Deployment / cloudflared<br/>1/1 · outbound tunnel"]
        ingress["Ingress / linkding<br/>Private lab hostname"]
        svc["Service / linkding<br/>ClusterIP :9090"]
        app["Deployment / linkding<br/>1/1"]
        pvc["PVC / linkding-data-worker-pvc<br/>1 GiB · local-path"]
        cfg["SOPS Secrets + ConfigMap<br/>App and tunnel settings"]
        tunnel --> svc
        ingress --> svc
        svc --> app
        app -->|/etc/linkding/data| pvc
        cfg -.-> app
        cfg -.-> tunnel
    end

    cf <-->|Outbound tunnel connection| tunnel
    traefik --> ingress
    pvc --> pv --> disk

    classDef workload stroke:#16a34a,stroke-width:2px
    classDef storage stroke:#2563eb,stroke-width:2px
    classDef external stroke:#64748b,stroke-dasharray:3 3
    class tunnel,app workload
    class pvc,pv,disk storage
    class public,cf,private,traefik external
```

### 5. `radio` — Streaming pipeline, library reconciliation, and dual ingress

The media PV is local to k8s-worker-01. The public ingress exposes only /radio.mp3; the internal ingress uses the lab hostname.

```mermaid
flowchart TB
    library["Forgejo / radio-library<br/>Git LFS"]
    registry["Forgejo OCI registry<br/>Pinned sync image"]
    listener["Public radio listeners"]
    lan["Private LAN listeners"]
    traefik["Traefik ingress controller"]
    issuer["ClusterIssuer / letsencrypt-production<br/>Cluster-scoped"]
    monitors["ServiceMonitors<br/>Namespace: monitoring"]
    pv[("PV / radio-music<br/>60 GiB · Retain · local")]
    disk["Host filesystem<br/>k8s-worker-01 /srv/radio/music"]

    subgraph ns["Namespace: radio"]
        sync["CronJob / radio-library-sync<br/>Every 5 minutes"]
        pvc["PVC / radio-music"]
        liquid["Deployment / liquidsoap<br/>1/1 · worker"]
        lsvc["Service / liquidsoap-metrics"]
        iceSvc["Service / icecast<br/>Stream :8000 + metrics"]
        ice["Deployment / icecast<br/>1/1 Pod · 2/2 · worker"]
        ingressPublic["Ingress / radio-public-stream<br/>Exact /radio.mp3"]
        ingressPrivate["Ingress / radio-stream<br/>Exact /radio.mp3"]
        cert["Certificate / radio-public<br/>TLS Secret: radio-public-tls"]
        config["ConfigMaps + SOPS Secrets<br/>Stream, library, registry"]
        sync -->|Publish versioned audio| pvc
        pvc -->|Read music| liquid
        liquid -->|Encoded audio source| iceSvc
        iceSvc --> ice
        liquid --> lsvc
        ingressPublic --> iceSvc
        ingressPrivate --> iceSvc
        cert -.->|TLS for public route| ingressPublic
        config -.-> sync
        config -.-> liquid
        config -.-> ice
    end

    library --> sync
    registry -.->|Image pull| sync
    pvc --> pv --> disk
    listener --> traefik --> ingressPublic
    lan --> traefik --> ingressPrivate
    issuer -.->|Issues public certificate| cert
    monitors -.->|Metric discovery| iceSvc
    monitors -.->|Metric discovery| lsvc

    classDef workload stroke:#16a34a,stroke-width:2px
    classDef storage stroke:#2563eb,stroke-width:2px
    classDef external stroke:#64748b,stroke-dasharray:3 3
    class sync,liquid,ice workload
    class pvc,pv,disk storage
    class library,registry,listener,lan,traefik,issuer,monitors external
```

### 6. `renovate` — Scheduled dependency automation

Renovate is an hourly CronJob, not a permanent application Pod. It opens pull requests against Forgejo, not the GitHub mirror.

```mermaid
flowchart TB
    schedule["Hourly schedule"]
    forgejo["Forgejo / NovaLabs/lovelace-cluster<br/>Branches and pull requests"]
    mirror["GitHub mirror<br/>Not Renovate target"]

    subgraph ns["Namespace: renovate · core node"]
        cron["CronJob / renovate<br/>concurrencyPolicy: Forbid"]
        jobs["Jobs / transient Pods<br/>Completed after scans"]
        config["ConfigMap / Renovate configuration"]
        creds["SOPS Secret<br/>Forgejo API credentials"]
        cron --> jobs
        config -.-> cron
        creds -.-> jobs
    end

    schedule --> cron
    jobs -->|Scan dependencies + propose PRs| forgejo
    forgejo -.->|Mirror only| mirror

    classDef workload stroke:#16a34a,stroke-width:2px
    classDef external stroke:#64748b,stroke-dasharray:3 3
    class cron workload
    class schedule,forgejo,mirror external
```

### 7. `cert-manager` — Certificate controllers and cluster-scoped issuers

ClusterIssuers are cluster-scoped, whereas the cert-manager controllers live in the cert-manager namespace and the radio Certificate lives in radio.

```mermaid
flowchart TB
    api["Kubernetes API / admission"]
    radioCert["Certificate / radio-public<br/>Namespace: radio"]
    radioTls["Secret / radio-public-tls<br/>Namespace: radio"]
    staging["ClusterIssuer / letsencrypt-staging<br/>Cluster-scoped"]
    prod["ClusterIssuer / letsencrypt-production<br/>Cluster-scoped"]
    cf["Cloudflare DNS-01<br/>DNS challenge"]
    acme["Let's Encrypt / ACME"]

    subgraph ns["Namespace: cert-manager · core node"]
        controller["Deployment / cert-manager<br/>1/1"]
        injector["Deployment / cainjector<br/>1/1"]
        webhook["Deployment / webhook<br/>1/1"]
        credentials["SOPS Secret<br/>Cloudflare DNS API token"]
        credentials -.-> controller
    end

    api -.->|Admission validation| webhook
    injector -.->|CA bundle injection| api
    controller -.->|Reconciles| radioCert
    radioCert -->|Issuer reference| prod
    controller -.-> staging
    prod -->|DNS-01 workflow| cf
    staging -.->|Staging validation| cf
    cf -.->|Challenge validation| acme
    radioCert -->|Stores certificate| radioTls

    classDef workload stroke:#16a34a,stroke-width:2px
    classDef external stroke:#64748b,stroke-dasharray:3 3
    class controller,injector,webhook workload
    class api,radioCert,radioTls,staging,prod,cf,acme external
```

### 8. `monitoring` — In-cluster Prometheus stack and external integrations

Prometheus and Alertmanager are operator-managed; Grafana is installed by the Helm chart. Radio ServiceMonitors discover radio namespace endpoints.

```mermaid
flowchart TB
    traefik["Traefik ingress<br/>Grafana private hostname"]
    radio["Radio Services<br/>Icecast + Liquidsoap exporters<br/>Namespace: radio"]
    nodes["Cluster nodes<br/>lovelace + k8s-worker-01"]
    central["Docker LXC<br/>Central Prometheus / remote write"]

    subgraph ns["Namespace: monitoring"]
        operator["Deployment / Prometheus Operator<br/>1/1 · core"]
        prom["Prometheus StatefulSet<br/>Pod 2/2 · core"]
        alerts["Alertmanager StatefulSet<br/>Pod 2/2 · core"]
        grafana["Grafana Deployment<br/>Pod 3/3 · core"]
        state["Deployment / kube-state-metrics<br/>1/1 · core"]
        exporter["DaemonSet / node-exporter<br/>2/2 · both nodes"]
        radioSM["ServiceMonitors<br/>Icecast + Liquidsoap"]
        secret["SOPS Secret / grafana-admin"]
        operator --> prom
        operator --> alerts
        prom -->|Alert notifications| alerts
        grafana -->|PromQL queries| prom
        prom -.->|Scrapes| state
        prom -.->|Scrapes| exporter
        prom -.->|Uses discovery rules| radioSM
        secret -.-> grafana
    end

    traefik --> grafana
    nodes -.->|Node metrics| exporter
    radioSM -.->|Selects radio metrics Services| radio
    prom -.->|Scrapes discovered targets| radio
    prom -->|Remote write for radio metrics| central

    classDef workload stroke:#16a34a,stroke-width:2px
    classDef external stroke:#64748b,stroke-dasharray:3 3
    class operator,prom,alerts,grafana workload
    class traefik,radio,nodes,central external
```

### 9. `topology-system` — Read-only external topology discovery

Only the ServiceAccount is namespaced. ClusterRole and ClusterRoleBinding are cluster-scoped. There are no application Pods in this namespace.

```mermaid
flowchart TB
    explorer["NovaLabs Topology Explorer<br/>Hosted on Docker LXC"]
    api["Lovelace Kubernetes API"]
    resources["List-only discovery<br/>Nodes, Pods, Services, EndpointSlices<br/>Deployments, ReplicaSets, StatefulSets<br/>DaemonSets, Jobs, CronJobs"]

    subgraph ns["Namespace: topology-system · no Pods"]
        sa["ServiceAccount / topology-reader<br/>automountServiceAccountToken: false"]
    end

    subgraph cluster["Cluster-scoped RBAC"]
        binding["ClusterRoleBinding<br/>novalabs-topology-reader"]
        role["ClusterRole<br/>novalabs-topology-reader<br/>list verb only"]
        binding -->|Role reference| role
        binding -->|Subject reference| sa
    end

    explorer -->|Authenticated API requests| api
    api -.->|Authorize against RBAC| binding
    api -->|Permitted list requests| resources

    classDef external stroke:#64748b,stroke-dasharray:3 3
    class explorer,api,resources external
```

The architecture diagram represents the live Lovelace workload topology and GitOps-managed resources as of November 11, 2026. Green borders highlight selected active workloads; dashed gray borders identify dormant resources; blue borders identify persistent storage.

The `minecraft` namespace continues running the shared Playit tunnel while its Paper StatefulSet and Alloy logger are scaled to zero. The `minecraft-active` ExternalName Service points to the active `minecraft-create` Service, preserving the public player address. Minecraft Create runs with four containers and its own retained storage, metrics, and Alloy logging.

The diagram excludes routine `kube-system` internals and transient Job Pods. Controller readiness, workload placement, and scheduling are based on a live cluster inventory; configuration relationships are based on the GitOps manifests. It represents configured dependencies rather than measured network traffic.

### Nodes and placement

| Node | Platform | Node-pool label | Primary responsibility |
| --- | --- | --- | --- |
| `lovelace` | Raspberry Pi 5, ARM64 | `novalabs.io/node-pool=core` | K3s control plane and core cluster services |
| `k8s-worker-01` | Debian, x86_64 | `novalabs.io/node-pool=worker` | Application workloads and node-local storage |

Stateless Deployments generally use a **logical node-pool selector**. Stateful workloads using node-local PersistentVolumes use **`kubernetes.io/hostname` selectors** aligned with PV node affinity. Changing only a node selector does not move data between nodes.

The logical node-pool labels are operational prerequisites. If a node is rebuilt or rejoins the cluster, verify and restore its label before relying on pool-based scheduling.

See [Architecture](docs/architecture.md) and [Operations and recovery](docs/operations.md).

## Selected managed workloads

| Workload | Namespace | Scheduling / delivery | Persistent data | Access |
| --- | --- | --- | --- | --- |
| Linkding | `linkding` | Single-replica Deployment on `k8s-worker-01`; Cloudflared on the worker pool | `linkding-data-worker-pvc` (1 GiB, `local-path`) | Traefik and Cloudflare Tunnel |
| Minecraft Paper | `minecraft` | StatefulSet 0/0 (stopped); shared Playit Deployment 1/1 on `lovelace` | Retained 60 GiB local PV on `k8s-worker-01` | Shared Playit tunnel; currently routes to Create |
| Minecraft Create | `minecraft-create` | StatefulSet 1/1 (4 containers); Alloy logger 1/1 on `k8s-worker-01` | Retained 90 GiB local PV | Active game server via `minecraft-active` and Playit |
| Radio | `radio` | Icecast and Liquidsoap Deployments; library-sync CronJob | Retained node-local music PV | Traefik; restricted public stream path |
| Renovate | `renovate` | Hourly CronJob | No application PVC | Forgejo API |
| kube-prometheus-stack | `monitoring` | Flux-managed HelmRelease | Grafana UI-created data is not durable | Traefik ingress |

This is a selected inventory, not a full listing of Kubernetes system controllers or every application. For authoritative live placement, inspect Pods in the cluster.

**Linkding storage:** Linkding uses `linkding-data-worker-pvc` (1 GiB, `local-path`) on `k8s-worker-01`. The original control-plane PVC was retired following migration, with a verified cold backup retained outside Kubernetes. Linkding uses `RollingUpdate` with `maxSurge: 0` and `maxUnavailable: 1`, preventing surge Pods during single-replica rollouts.

**Retired application:** Audiobookshelf was removed from the cluster in November 2026, including its namespace and local-path storage.

See [Applications](docs/applications.md), [Minecraft](docs/minecraft.md), and [Radio](docs/radio.md) for workload-specific details.

## Repository layout

```text
.
├── apps/
│   ├── base/                    # Reusable application resources
│   └── staging/                 # Lovelace overlays, patches, encrypted Secrets
├── clusters/staging/            # Flux bootstrap and reconciliation entry points
├── infrastructure/controllers/  # Platform controllers and automation
├── monitoring/
│   ├── controllers/             # Helm repositories and releases
│   └── configs/                 # Monitoring configuration and ServiceMonitors
├── images/
│   └── radio-library-sync/      # Radio reconciliation container image
├── docs/                        # Architecture, runbooks, application guides
├── CONTRIBUTING.md              # Contribution and validation workflow
├── renovate.json                # Dependency update configuration
└── README.md
```

`base` directories define shared resources. `staging` overlays compose those resources and apply Lovelace-specific scheduling, storage, ingress, and SOPS-encrypted configuration. The radio content repository is separate from this infrastructure repository.

## GitOps reconciliation

Flux reconciles declarative state from Forgejo `main`. The principal Kustomizations are:

| Kustomization | Repository path | Responsibility |
| --- | --- | --- |
| `apps` | `./apps/staging` | Application resources |
| `infrastructure-controllers` | `./infrastructure/controllers/staging` | Supporting controllers and automation |
| `monitoring-controllers` | `./monitoring/controllers/staging` | Monitoring controllers and Helm releases |
| `monitoring-configs` | `./monitoring/configs/staging` | Monitoring configuration |

Flux bootstrap resources live under `clusters/staging`. SOPS decryption is configured for the reconciliation paths that consume encrypted Kubernetes Secrets.

```mermaid
flowchart LR
    edit["Edit manifests"] --> branch["Feature branch"]
    branch --> pr["Forgejo pull request"]
    pr --> merge["Merge to main"]
    merge --> source["Flux GitRepository"]
    source --> reconcile["Flux Kustomizations"]
    reconcile --> cluster["Kubernetes desired state"]
```

Avoid routine imperative changes to Flux-managed workloads: reconciliation can overwrite them. Use a separate, reviewed change for storage deletion, node relocation, or other potentially destructive operations.

### Radio content delivery

Radio music is versioned separately in the Forgejo `NovaLabs/radio-library` repository using Git LFS. Its CronJob fetches and validates audio, publishes an immutable release directory, and atomically updates a `current` symlink. Liquidsoap can discover the updated library without restarting its Pod.

```mermaid
flowchart LR
    edit["Update radio-library"] --> forgejo["Push to Forgejo"]
    forgejo --> sync["radio-library-sync<br/>every 5 minutes"]
    sync --> verify["Fetch Git LFS objects<br/>validate release"]
    verify --> publish["Immutable release"]
    publish --> current["Atomic current symlink"]
    current --> liquidsoap["Liquidsoap<br/>periodic library reload"]
    liquidsoap --> icecast["Icecast stream"]
```

For library management, rollback, and image publishing, see [Radio](docs/radio.md).

## Working with this repository

### Prerequisites

- Access to the Forgejo repository and permission to open pull requests
- `git`
- `kubectl` with the correct Lovelace kubeconfig/context
- `flux` CLI
- `sops` and the appropriate public age recipient for encrypting new Secrets

Decryption private keys must **not** be placed in Git or shared in pull requests.

### Change workflow

```bash
git switch main
git pull --ff-only origin main
git switch -c feat/short-description
```

Edit the relevant manifests and documentation in the feature branch. Validate, review the diff, commit, push to Forgejo, and merge through a pull request. Flux deploys the merged desired state; a local branch or unmerged PR does not change the cluster.

### Render and validate

Render the full application reconciliation with the Flux CLI (the `apps/staging` directory is composed by Flux):

```bash
flux build kustomization apps --namespace flux-system --path ./apps/staging
```

For a focused application overlay:

```bash
kubectl kustomize apps/staging/linkding
```

Review the generated resource names, selectors, storage references, and deletion scope. For resources that can safely be submitted individually, use a **server-side dry-run** to check Kubernetes API compatibility before merging; a successful local render alone does not prove that an update will be accepted by the API server.

```bash
git diff --check
git status --short --branch
```

Before using server-side dry-run or applying resources, verify the `kubectl` context. Do not send encrypted SOPS documents directly to Kubernetes as though they were plaintext Secrets.

For encrypted manifests:

```bash
sops filestatus path/to/secret.sops.yaml
```

Expected encrypted status: `{"encrypted":true}`.

### Verify a reconciliation

```bash
flux get sources git -A
flux get kustomizations -A
flux get helmreleases -A
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

After storage or scheduling changes, also verify PVC/PV binding, PV node affinity, workload readiness, and actual application behavior. A `Ready` Kubernetes resource does not by itself prove data integrity or functional correctness.

See [GitOps workflow](docs/gitops-workflow.md) and [Contributing](CONTRIBUTING.md).

## Secrets, storage, and recovery

- **SOPS + age:** commit only encrypted Secret manifests; keep age identities and recovery material outside the repository.
- **Node-local storage:** a PV tied to one hostname is not automatically portable. Plan data transfer and volume binding before moving a stateful Pod.
- **Deletion protection:** review PV reclaim policy and Flux pruning behavior before removing a PVC, namespace, or storage manifest.
- **Backups:** preserve application data independently of Git. Git tracks desired state, not database contents or game worlds.
- **Rollbacks:** reverting a manifest does not reconstruct a deleted dynamically provisioned volume. Validate backup and restore procedures separately.
- **Credentials:** avoid displaying decrypted Secrets in logs, issue comments, or build output; use least-privilege registry and application credentials.

See [Secrets management](docs/secrets.md) and [Operations and recovery](docs/operations.md).

## Documentation

- [Architecture](docs/architecture.md)
- [Applications](docs/applications.md)
- [GitOps workflow](docs/gitops-workflow.md)
- [Secrets management](docs/secrets.md)
- [Operations and recovery](docs/operations.md)
- [Monitoring and logging](docs/monitoring.md)
- [Minecraft](docs/minecraft.md)
- [Radio](docs/radio.md)
- [Renovate](docs/renovate.md)
- [Contributing](CONTRIBUTING.md)

## License

This repository is maintained as a personal infrastructure and learning project. No license is currently declared.
