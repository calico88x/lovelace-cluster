# Renovate

## Purpose

Renovate automates dependency discovery and opens update pull requests against the primary Forgejo repository.

It runs inside Lovelace as an hourly CronJob in the `renovate` namespace.

## Platform configuration

The intended configuration is:

| Setting | Value |
| --- | --- |
| Platform | `forgejo` |
| Endpoint | `http://forgejo.caliconet.lab:3002/api/v1/` |
| Repository | `NovaLabs/lovelace-cluster` |
| Author | `Lovelace Renovate Bot <renovate-bot@caliconet.lab>` |
| Schedule | Hourly |
| Concurrency policy | `Forbid` |

The API token is loaded from the SOPS-encrypted `renovate-container-env` Secret. Do not store the token in the ConfigMap, CronJob, or `renovate.json`.

## Repository configuration

The root `renovate.json` enables Kubernetes YAML discovery. Renovate inspects applicable manifests and proposes image-tag updates as pull requests.

## Trigger a manual run

Create a one-off Job from the CronJob:

```bash
kubectl create job \
  --from=cronjob/renovate \
  renovate-manual-$(date +%s) \
  -n renovate
```

Watch it:

```bash
kubectl get jobs,pods -n renovate
kubectl logs -n renovate job/<job-name> --follow
```

Remove the completed manual Job after inspection if desired.

## Verify deployed configuration

```bash
kubectl get configmap renovate-configmap \
  -n renovate \
  -o jsonpath='{.data.RENOVATE_PLATFORM}{"\n"}{.data.RENOVATE_ENDPOINT}{"\n"}{.data.RENOVATE_GIT_AUTHOR}{"\n"}'
```

```bash
kubectl get cronjob renovate \
  -n renovate \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].args}{"\n"}'
```

## Forgejo permissions

The Renovate bot needs enough repository access to:

- Read repository content and metadata
- Create and update branches
- Create and update pull requests
- Create related issues or comments when Renovate requires them

Use the narrowest Forgejo token permissions that satisfy those operations.

## Mirror caveat

Renovate must operate against Forgejo, not GitHub. GitHub is a mirror. Branches and pull requests created only on GitHub can be removed or closed when Forgejo mirrors its authoritative refs.

## Troubleshooting

If no PR appears:

1. Confirm the CronJob produced a Job.
2. Inspect the Job log for authentication, endpoint, or repository errors.
3. Confirm `RENOVATE_PLATFORM=forgejo`.
4. Confirm the endpoint includes `/api/v1/`.
5. Confirm the repository argument uses the Forgejo owner and repository name.
6. Confirm the encrypted token belongs to the Renovate bot and is not expired.
7. Confirm the bot can push a test branch and open a PR in Forgejo.