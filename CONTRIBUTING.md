# Contributing

## Change model

Forgejo is the source of truth for Lovelace. Every durable cluster change should be represented in Git and reviewed through a pull request before it reaches `main`.

Avoid making routine configuration changes directly against the cluster. Flux may revert them, and they leave no reproducible record.

## Branches

Start from an updated `main`:

```bash
git switch main
git pull --ff-only
git switch -c <type>/<short-description>
```

Suggested prefixes:

- `feat/` for new capabilities or workloads
- `fix/` for corrections
- `docs/` for documentation-only work
- `chore/` for maintenance and dependency changes

Keep each branch focused on one reviewable outcome.

## Repository conventions

### Kustomize

- Put reusable resources under `*/base`.
- Put Lovelace-specific composition, patches, ingress, storage, and secrets under `*/staging`.
- Add every new resource to the nearest `kustomization.yaml`.
- Prefer named ports and stable Service DNS.
- Do not hard-code generated ClusterIP addresses.

### Kubernetes resources

- Set namespaces explicitly or through the owning Kustomization.
- Use labels consistently so Services and monitors select the intended pods.
- Define resource requests and sensible limits for persistent workloads.
- Use non-root security contexts and drop Linux capabilities where supported.
- Document node affinity and local-storage assumptions.

### Container images

- Prefer explicit version tags.
- Review Renovate updates in Forgejo before merging.
- Avoid introducing new `latest` tags without a documented reason.

### Secrets

- Never commit plaintext Secret data.
- Name encrypted files `*.sops.yaml`.
- Encrypt only through the repository SOPS policy.
- Confirm `sops filestatus` before staging.
- Never include credentials in pull-request descriptions or screenshots.

## Validation

Run the checks relevant to the changed area.

### Applications

```bash
kubectl kustomize apps/staging | kubectl apply --dry-run=client -f -
```

### Infrastructure

```bash
kubectl kustomize infrastructure/controllers/staging | kubectl apply --dry-run=client -f -
```

### Monitoring

```bash
kubectl kustomize monitoring/controllers/staging | kubectl apply --dry-run=client -f -
kubectl kustomize monitoring/configs/staging | kubectl apply --dry-run=client -f -
```

### Git hygiene

```bash
git diff --check
git status --short
```

Inspect the staged change before committing:

```bash
git diff --cached --check
git diff --cached --stat
git diff --cached
```

Dry-run warnings about a missing `kubectl.kubernetes.io/last-applied-configuration` annotation are expected for Flux-managed resources. Validation errors are not.

## Commit messages

Use concise conventional-style messages when practical:

```text
feat(minecraft): add retained worker storage
fix(renovate): target Forgejo API
docs(cluster): add operations runbook
```

## Pull-request descriptions

Include:

- Why the change is needed
- What resources or behavior change
- Validation performed
- Expected rollout or restart behavior
- Storage, networking, or secret-management risk
- Rollback considerations for stateful changes

## After merge

Watch Flux and the affected workload:

```bash
flux get kustomizations -A
kubectl get pods -A -o wide
```

For a focused deployment:

```bash
kubectl rollout status deployment/<name> -n <namespace>
kubectl rollout status statefulset/<name> -n <namespace>
```

Confirm application behavior, monitoring, and public access where applicable. Do not consider a migration complete solely because the pod is `Running`.

## Destructive changes

Storage deletion, secret revocation, node removal, and workload decommissioning require explicit review. Resolve exact targets first, take a backup where relevant, and separate data deletion from ordinary manifest cleanup.