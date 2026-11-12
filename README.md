# Lovelace Cluster

Lovelace is a two-node, heterogeneous [K3s](https://k3s.io/) Kubernetes cluster managed declaratively with [Flux](https://fluxcd.io/). A Raspberry Pi 5 provides the ARM64 control plane, and a Debian x86_64 worker runs application workloads and hosts node-local application data.

**Forgejo is the authoritative Git repository.** Changes go through pull requests, reach `main` after review, and are reconciled by Flux. GitHub is an external mirror, not a separate deployment source.

## Architecture

```mermaid
flowchart TB
    classDef active stroke:#16a34a,stroke-width:2px
    classDef dormant stroke:#94a3b8,stroke-width:2px,stroke-dasharray:5 5
    classDef storage stroke:#3b82f6,stroke-width:2px

    subgraph external["External systems and users"]
        direction LR
        operator["Operator"]
        forgejo["Forgejo<br/>Authoritative GitOps source"]
        github["GitHub mirror"]
        library["Radio library<br/>Git LFS"]
        registry["Forgejo OCI registry"]
        players["Minecraft players"]
        playitEdge["Playit public edge"]
        cloudflare["Cloudflare edge"]
        webUsers["Web users"]
        listeners["Radio listeners"]
        central["Docker LXC<br/>Central Loki + Prometheus"]
        explorer["NovaLabs Topology Explorer<br/>Docker LXC"]
    end

    subgraph cluster["Lovelace · K3s cluster"]
        direction TB

        nodes["Nodes<br/>lovelace: ARM64 control plane / core<br/>k8s-worker-01: Debian x86_64 / worker"]
        traefik["Traefik ingress gateway<br/>LoadBalancer on both node IPs"]

        subgraph fluxNS["flux-system · core node"]
            fluxGit["GitRepository / flux-system"]
            fluxCtrl["4 running controllers<br/>source / kustomize<br/>helm / notification"]
            fluxApps["Kustomization: apps"]
            fluxInfra["Kustomization: infrastructure-controllers"]
            fluxMon["Kustomizations:<br/>monitoring-controllers + configs"]
            fluxGit --> fluxCtrl
            fluxCtrl --> fluxApps
            fluxCtrl --> fluxInfra
            fluxCtrl --> fluxMon
        end

        subgraph minecraftNS["minecraft · shared tunnel ACTIVE / Paper STOPPED"]
            mcPlayit["Deployment / playit<br/>1/1 · core node"]
            mcAlias["Service / minecraft-active<br/>ExternalName → Create"]
            mcPaperSvc["Services / minecraft + headless<br/>No running Paper endpoints"]
            mcPaper["StatefulSet / minecraft<br/>0/0 · STOPPED"]
            mcAlloy["Deployment / alloy-minecraft-logs<br/>0/0 · STOPPED"]
            mcPV[("PV + PVC / minecraft-data<br/>60 GiB · Retain · worker-local")]
            mcConfig["Paper ConfigMaps + Secrets<br/>Playit Secret"]
            mcPlayit --> mcAlias
            mcPaperSvc -.-> mcPaper
            mcPaper -.-> mcPV
            mcConfig -.-> mcPaper
            mcConfig -.-> mcPlayit
        end

        subgraph createNS["minecraft-create · ACTIVE on worker"]
            crSvc["Services<br/>minecraft-create + headless"]
            crSTS["StatefulSet / minecraft-create<br/>1/1 · Pod 4/4"]
            crContainers["NeoForge / All of Create<br/>Storage metrics collector<br/>Network exporter<br/>DH metrics collector"]
            crAlloy["Deployment / Alloy logs<br/>1/1 · worker"]
            crPV[("PV + PVC / minecraft-create-data<br/>90 GiB · Retain")]
            crConfig["ConfigMaps + encrypted Secret<br/>Modpack / server / RCON config"]
            crSvc --> crSTS
            crSTS --> crContainers
            crSTS --> crPV
            crConfig -.-> crSTS
            crAlloy -.->|Collects logs| crSTS
        end

        subgraph linkNS["linkding · ACTIVE on worker"]
            linkCF["Deployment / cloudflared<br/>1/1 · worker"]
            linkSvc["Service / linkding<br/>ClusterIP · 9090"]
            linkApp["Deployment / linkding<br/>1/1 · worker"]
            linkPV[("PVC / linkding-data-worker-pvc<br/>1 GiB · local-path")]
            linkIng["Ingress / linkding<br/>Private lab hostname"]
            linkSecrets["Encrypted Secrets + ConfigMap<br/>Tunnel and application config"]
            linkCF --> linkSvc
            linkSvc --> linkApp
            linkApp --> linkPV
            linkIng --> linkSvc
            linkSecrets -.-> linkCF
            linkSecrets -.-> linkApp
        end

        subgraph radioNS["radio · ACTIVE on worker"]
            radioSync["CronJob / radio-library-sync<br/>Every 5 minutes"]
            radioPV[("PV + PVC / radio-music<br/>60 GiB · Retain")]
            liquid["Deployment / liquidsoap<br/>1/1"]
            liquidSvc["Service / liquidsoap-metrics"]
            iceSvc["Service / icecast<br/>8000 + 9119"]
            icecast["Deployment / icecast<br/>1/1 · Pod 2/2<br/>Icecast + exporter"]
            radioIng["Ingresses / internal + public<br/>Exact path /radio.mp3"]
            radioCert["Certificate / radio-public<br/>TLS Secret"]
            radioConfig["Encrypted Secrets + ConfigMaps<br/>Stream / library / registry"]
            radioSync -->|Publish library| radioPV
            radioPV -->|Music files| liquid
            liquid -->|Audio source| iceSvc
            iceSvc --> icecast
            liquid --> liquidSvc
            radioIng --> iceSvc
            radioCert -.-> radioIng
            radioConfig -.-> radioSync
            radioConfig -.-> liquid
            radioConfig -.-> icecast
        end

        subgraph renovateNS["renovate · core node"]
            renovate["CronJob / renovate<br/>Hourly · completed Jobs"]
            renConfig["Configuration + encrypted credentials"]
            renConfig -.-> renovate
        end

        subgraph certNS["cert-manager · core node"]
            cert["Deployment / cert-manager<br/>1/1"]
            cainj["Deployment / cainjector<br/>1/1"]
            webhook["Deployment / webhook<br/>1/1"]
            issuers["ClusterIssuers<br/>Let's Encrypt staging + production<br/>Cloudflare DNS-01"]
            cert --> issuers
        end

        subgraph monitorNS["monitoring"]
            monOperator["Prometheus Operator<br/>Deployment 1/1 · core"]
            monProm["Prometheus StatefulSet<br/>Pod 2/2 · core"]
            monAlerts["Alertmanager StatefulSet<br/>Pod 2/2 · core"]
            monGrafana["Grafana Deployment<br/>Pod 3/3 · core"]
            monState["kube-state-metrics<br/>Deployment 1/1 · core"]
            monNodes["Node exporter DaemonSet<br/>2/2 · both nodes"]
            monRadio["Radio ServiceMonitors<br/>Icecast + Liquidsoap"]
            monOperator --> monProm
            monProm --> monAlerts
            monProm --> monState
            monProm --> monNodes
            monProm --> monRadio
            monGrafana -->|Queries| monProm
        end

        subgraph topologyNS["topology-system · RBAC only"]
            topoRBAC["ServiceAccount<br/>ClusterRole + ClusterRoleBinding<br/>Read-only discovery · no Pods"]
        end
    end

    operator --> forgejo
    forgejo -.->|Mirror| github
    forgejo --> fluxGit
    renovate -->|Dependency PRs| forgejo

    fluxApps -.-> mcPlayit
    fluxApps -.-> crSTS
    fluxApps -.-> linkApp
    fluxApps -.-> radioSync
    fluxInfra -.-> cert
    fluxInfra -.-> renovate
    fluxInfra -.-> topoRBAC
    fluxMon -.-> monOperator
    fluxMon -.-> monRadio

    players --> playitEdge --> mcPlayit
    mcAlias -->|DNS alias| crSvc

    webUsers --> cloudflare
    linkCF <-->|Outbound tunnel| cloudflare
    webUsers -->|Private LAN| traefik
    traefik --> linkIng

    listeners -->|HTTPS| traefik
    traefik --> radioIng

    issuers -.->|Certificate issuance| radioCert
    registry -.->|Image pulls| radioSync
    library -->|Git LFS fetch| radioSync

    crAlloy -->|Logs| central
    monProm -->|Radio metrics remote write| central
    monRadio -.->|Scrape| iceSvc
    monRadio -.->|Scrape| liquidSvc

    traefik -->|Grafana ingress| monGrafana
    explorer -.->|Kubernetes API / RBAC| topoRBAC

    class mcPaper,mcAlloy,mcPaperSvc dormant
    class mcPlayit,crSTS,crAlloy,linkApp,linkCF,radioSync,liquid,icecast active
    class mcPV,crPV,linkPV,radioPV storage
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
