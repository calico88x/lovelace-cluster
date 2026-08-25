# Secrets Management

## Model

Kubernetes Secrets are encrypted with SOPS before they are committed. The repository stores only encrypted `data` or `stringData` values. Flux decrypts them inside the cluster using the `sops-age` Secret in `flux-system`.

The age private key must never be committed. Workstations only need the public recipient to create new encrypted files; decryption access is not required for normal contribution.

## Naming convention

Encrypted manifests use the suffix:

```text
*.sops.yaml
```

An unencrypted Secret must never be committed, regardless of its filename.

## Encryption policy

`clusters/staging/.sops.yaml` defines the age recipient and encrypts the `data` and `stringData` sections of YAML manifests.

Create plaintext only in a temporary file outside the repository:

```bash
sops --config clusters/staging/.sops.yaml \
  --encrypt \
  --output path/to/secret.sops.yaml \
  /path/to/temporary-secret.yaml
```

Delete the temporary plaintext immediately after successful encryption.

## Verify before committing

```bash
sops filestatus path/to/secret.sops.yaml
```

Expected result:

```json
{"encrypted":true}
```

Search the staged diff for accidental placeholders or plaintext:

```bash
git diff --cached --check
git diff --cached
```

Never paste decrypted secret contents into pull requests, issues, logs, or chat.

## Existing encrypted secrets

The repository uses SOPS for:

- Audiobookshelf Cloudflare Tunnel credentials
- Linkding Cloudflare Tunnel credentials
- Linkding superuser configuration
- Minecraft private configuration
- Playit agent credentials
- Renovate Forgejo token
- Grafana TLS material
- Grafana administrator credentials

## Rotation procedure

1. Generate or obtain the replacement credential.
2. Build a temporary Kubernetes Secret manifest outside the repository.
3. Encrypt it using the staging SOPS policy.
4. Replace the corresponding `.sops.yaml` file.
5. Confirm `sops filestatus` reports encrypted.
6. Render and dry-run the affected Kustomization.
7. Merge through Forgejo.
8. Confirm Flux reconciliation and workload rollout.
9. Revoke the previous credential when the new one is proven functional.

For persistent applications, note that changing a Kubernetes Secret does not always update credentials stored inside an application's database. Follow the application's rotation procedure where applicable.

## Recovery requirement

Back up the age private key securely and separately from the Git repository. Without a valid recipient identity, the encrypted repository secrets cannot be recovered or rotated in place.