# Minecraft Private Secret Editor

This runbook documents the interactive tools used to manage the private
configuration for the Paper and Create Minecraft servers without placing
plaintext secrets in the Git repository or on the Windows workstation.

## Entry points

Run the appropriate PowerShell launcher from the root of the
`lovelace-cluster` repository:

| Server | Command | Encrypted file |
| --- | --- | --- |
| Paper | `.\operations\minecraft\edit-paper-secrets.ps1` | `apps/staging/minecraft/minecraft-private.sops.yaml` |
| Create | `.\operations\minecraft\edit-create-secrets.ps1` | `apps/staging/minecraft-create/minecraft-private.sops.yaml` |

The two launchers use the same editor workflow but operate on separate
Kubernetes Secrets and namespaces.

| Server | Namespace | Secret |
| --- | --- | --- |
| Paper | `minecraft` | `minecraft-private` |
| Create | `minecraft-create` | `minecraft-create-private` |

## Managed values

The editor manages these keys:

| Key | Purpose |
| --- | --- |
| `WHITELIST` | Minecraft usernames allowed to join the server |
| `OPS` | Minecraft usernames granted operator permissions |
| `SEED` | Seed used when initially creating a world |
| `RCON_PASSWORD` | Password used by the container's RCON client and server |

Changing `SEED` does not recreate an existing world. It is primarily relevant
before initial world generation.

## Requirements

### Windows workstation

- A current checkout of `lovelace-cluster`
- PowerShell
- `ssh` and `scp`
- Working SSH access through the `lovelace` host alias

### Lovelace

- `/usr/local/bin/sops`
- `kubectl` access to the cluster
- The `flux-system/sops-age` Secret containing `age.agekey`
- Permission to read that Secret

Decryption must occur on Lovelace because the private age identity is stored in
the cluster's `sops-age` Secret.

## Security model

The launcher performs the sensitive work remotely on Lovelace:

1. It copies the encrypted SOPS document and editor helpers to a temporary
   working directory.
2. It obtains the age identity from `flux-system/sops-age` for the SOPS
   process.
3. It decrypts and edits the document on Lovelace.
4. It validates and re-encrypts the updated document.
5. It returns only the encrypted YAML to the workstation.
6. It removes the temporary remote files when the session ends.

Plaintext values are never written into the repository. The workstation only
receives the resulting SOPS-encrypted file.

The editor hides `RCON_PASSWORD` by default. Reveal it only when necessary and
avoid running the editor while screen sharing or recording the terminal.

## Normal workflow

Start from a clean, current branch:

```powershell
git switch main
git pull --ff-only
git switch -c chore/update-minecraft-secrets
```

Run the launcher for the intended server:

```powershell
.\operations\minecraft\edit-create-secrets.ps1
```

Or, for Paper:

```powershell
.\operations\minecraft\edit-paper-secrets.ps1
```

The menu provides these operations:

1. View current values
2. Manage `WHITELIST`
3. Manage `OPS`
4. Change or clear `SEED`
5. Change `RCON_PASSWORD`
6. Save encrypted update
7. Cancel without changes

Choose **Save encrypted update** only after reviewing the intended values. A
successful run ends with a message similar to:

```text
Updated and verified: apps/staging/minecraft-create/minecraft-private.sops.yaml
The file remains encrypted. Review and commit it through the normal GitOps workflow.
```

Choosing **Cancel without changes** leaves the repository file untouched.

## Review and commit

Check the working tree:

```powershell
git status --short
git diff --check
```

The SOPS ciphertext, initialization vectors, tags, and MAC will normally change
when the document is saved. This is expected even when only one logical value
was edited.

Confirm that the file still contains encrypted values without decrypting it:

```powershell
Select-String `
  -Path .\apps\staging\minecraft-create\minecraft-private.sops.yaml `
  -Pattern 'ENC\[AES256_GCM'
```

Stage, commit, and push the encrypted file:

```powershell
git add apps/staging/minecraft-create/minecraft-private.sops.yaml
git commit -m "Update Create Minecraft private settings"
git push -u origin HEAD
```

Use the corresponding Paper path and commit message when editing Paper.

After the pull request is merged into `main`, Flux discovers and applies the
encrypted Secret automatically during its normal reconciliation interval.

## Applying the change to a running server

Flux decrypts and updates the Kubernetes Secret, but Kubernetes does not
restart an existing pod merely because a referenced Secret changed. Values
loaded through environment variables take effect when a new pod starts.

To request immediate Flux reconciliation:

```bash
flux reconcile kustomization apps --with-source
```

Confirm the applied revision:

```bash
flux get kustomization apps
```

Restart Create when the changed value must be loaded from the Secret:

```bash
kubectl -n minecraft-create rollout restart statefulset/minecraft-create
kubectl -n minecraft-create rollout status statefulset/minecraft-create
```

Restart Paper with:

```bash
kubectl -n minecraft rollout restart statefulset/minecraft
kubectl -n minecraft rollout status statefulset/minecraft
```

The Minecraft container handles a normal Kubernetes termination gracefully by
saving players, worlds, and chunks before exiting.

### Updating the live whitelist without restarting

After the encrypted source of truth has been updated, a username can also be
added immediately to the running server through RCON:

```bash
kubectl -n minecraft-create exec minecraft-create-0 \
  -c minecraft-create -- \
  rcon-cli "whitelist add PLAYER_NAME"
```

For Paper:

```bash
kubectl -n minecraft exec minecraft-0 \
  -c minecraft -- \
  rcon-cli "whitelist add PLAYER_NAME"
```

The RCON command updates the live server; the encrypted Git value ensures the
entry remains present after future pod restarts.

## Failure behavior

The launcher is designed to fail closed. If SSH, SOPS decryption, validation,
encryption, or file transfer fails, it reports the failure and does not replace
the repository file.

### Invalid age recipient

```text
The encrypted document contains an invalid age recipient.
```

Do not manually alter the `sops` metadata. Confirm that the local branch is
current and that the encrypted file was produced for the cluster's configured
age recipient. The editor should be rerun only after correcting that mismatch.

### Unable to decrypt

Confirm that the cluster Secret and SOPS binary are available on Lovelace:

```bash
kubectl -n flux-system get secret sops-age
command -v sops
```

Do not copy the age private key to the workstation as a workaround.

### Interrupted or cancelled session

Run `git status --short`. Unless the editor printed its successful
`Updated and verified` message, the encrypted repository file should remain
unchanged.

## Operational rules

- Never commit a decrypted Secret.
- Never paste `RCON_PASSWORD` into a command line, commit message, issue, or PR.
- Keep Paper and Create values in their corresponding encrypted files.
- Treat Git as the durable source of truth; use live RCON changes only for
  immediate effect.
- Review the target server shown by the editor before saving.
- Merge Secret changes through the normal pull-request workflow.
