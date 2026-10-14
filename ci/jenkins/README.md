# ci/jenkins — the Jenkins controller, as a wrapper chart

This directory is not the Jenkins chart. It is a two-file wrapper around
`jenkins/jenkins` **5.9.68** (`Chart.yaml` + `values.yaml`), plus the two things
that deliberately live outside it:

| path | what it is | why it is not in the chart |
|---|---|---|
| `ci/jenkins/` | the controller, its agent pod template, JCasC | wrapper only: `jenkins.rbac.create: false`, `jenkins.serviceAccount.create: false` |
| `ci/rbac/` | ServiceAccount `jenkins`, Role, RoleBinding, SA `jenkins-agent`, and the binding that lets an agent deploy into `boutique` | the permissions of an identity that can create pods belong in a file you can read top to bottom, not a template diffed against upstream |
| `ci/backup/cronjob.yaml` | the daily PVC → S3 backup | the backup job is this platform's policy (quota, schedule, prune), not the chart's |

`helm dependency build ci/jenkins` pulls the chart into the gitignored
`charts/`; nothing under `charts/` is committed.

## Prerequisites

1. **Namespace `ci`.** Nothing in this repository creates it — the
   `ResourceQuota`/`LimitRange` in `cluster/policies/` reference it, they do not
   make it.

   ```bash
   kubectl create namespace ci
   ```

2. **Three Secrets, seeded out of band.** None of them is in git, none is in
   Terraform, and all three are fail-closed: the controller pod will not reach
   `Running` if `jenkins-admin` is missing (the projected volume mount fails),
   and the backup pod will not start without `jenkins-backup-credentials`.

   ```bash
   # admin login — generated, never printed, never written to disk
   kubectl -n ci create secret generic jenkins-admin \
     --from-literal=jenkins-admin-user=admin \
     --from-literal=jenkins-admin-password="$(openssl rand -base64 24)"

   # repository checkout credential (the JCasC references these key names)
   read -rsp "GitHub username: " GH_USER; echo
   read -rsp "GitHub PAT: " GH_PAT; echo
   kubectl -n ci create secret generic jenkins-pipeline-credentials \
     --from-literal=github-username="$GH_USER" \
     --from-literal=github-password="$GH_PAT"
   unset GH_USER GH_PAT

   # S3 write credential for the backup CronJob (bucket does not exist yet:
   # TASKS.md — until it does, the job fails at `aws s3 cp`, loudly)
   read -rsp "AWS access key id: " AWS_KEY; echo
   read -rsp "AWS secret access key: " AWS_SECRET; echo
   kubectl -n ci create secret generic jenkins-backup-credentials \
     --from-literal=aws-access-key-id="$AWS_KEY" \
     --from-literal=aws-secret-access-key="$AWS_SECRET"
   unset AWS_KEY AWS_SECRET
   ```

   The `read -rsp` form exists because `--from-literal=x=<paste>` lands in shell
   history. Verify without printing values:

   ```bash
   kubectl -n ci get secrets            # three names, no data
   ```

3. **An edge route.** `cluster/traefik` carries IngressRoute `jenkins`, which
   matches `Host(<jenkinsHost>)` and forwards to Service `ci:8080`. The same
   hostname is what `jenkinsUrl` has to be, or JCasC will hand out redirects to
   a host that does not resolve (see `docs/runbooks/ci.md`).

## Install

```bash
# 1. identity first: the controller pod cannot start without its
#    ServiceAccount, and the chart is told not to create one.
kubectl apply -f ci/rbac/ -n ci

# 2. the chart, then the wrapper around it
helm repo add jenkins https://charts.jenkins.io
helm dependency build ci/jenkins
helm lint --strict ci/jenkins
helm install ci ci/jenkins -n ci \
  --set jenkins.controller.jenkinsUrl="https://<jenkinsHost>"

# 3. the job that depends on the PVC the chart just created
kubectl apply -f ci/backup/cronjob.yaml
```

Order matters: `jenkins-admin` must exist before step 2 (the projected volume
mount fails otherwise and the pod never leaves `ContainerCreating`), and the
ServiceAccount before the controller starts, because its
`automountServiceAccountToken: true` is what the Kubernetes plugin uses to
create every agent pod.

## What the values change, and why

- **`fullnameOverride: "ci"`** — the Service must be named `ci`, because that is
  what the Traefik route and the ServiceMonitor already point at.
- **`serviceAccount.create: false` / `rbac.create: false`** — the chart
  *references* `jenkins`; `ci/rbac/` *owns* it. Same for `agent.serviceAccount:
  jenkins-agent`, whose own RoleBinding lives in `boutique` and grants exactly
  what `platform:developers` gets — nothing cluster-wide.
- **`controller.priorityClassName: platform-ci-controller`** — set in the
  manifest rather than by a `kubectl patch` after install, so an upgrade cannot
  drop it.
- **`controller.installLatestPlugins: false`** plus the explicit plugin list —
  with the chart default, dependency versions resolve to `latest` on every
  restart and the pins become comments.
- **`controller.additionalContainers: dind`** (docker 27.5.1-dind,
  `privileged`) — the one privileged container this platform admits. The
  alternative (`kaniko`, userspace builds) is not installed. Recorded in
  `TASKS.md` as untested.
- **`agent.containerCap: "8"`** — derived from the `ci-quota`, not from the
  chart's default 10: a ninth agent would be refused by the ResourceQuota and
  the build would queue forever. See `docs/resource-budget.md` §4.

## Sizes (rendered, not remembered)

```bash
helm template ci ci/jenkins -n ci
```

| pod | requests | limits |
|---|---|---|
| controller (`StatefulSet ci`) | 120m / 576Mi (jenkins 50m/256Mi, init 50m/256Mi, config-reload 10m/32Mi ×2) | 1100m / 1664Mi |
| agent (one per build, `containerCap` 8) | 200m / 768Mi (jnlp 150m/512Mi + dind 50m/256Mi) | 350m / 1280Mi |
| backup (`CronJob jenkins-backup`, 03:17 UTC) | 50m / 128Mi | 200m / 256Mi |

## Verification this repository can run without a cluster

```bash
helm dependency build ci/jenkins && helm lint --strict ci/jenkins
helm template ci ci/jenkins -n ci | grep -E 'kind: (StatefulSet|Service|PersistentVolumeClaim)'
kubeconform -strict -summary -kubernetes-version 1.36.3 ci/rbac ci/backup
conftest test ci/ -p policy/
```

The Jenkinsfile runs the same four (plus kubeconform over the whole repository,
gitleaks, actionlint and the deliberately-failing policy fixtures) in pinned
containers; `scripts/check.sh` runs them on the laptop. What none of them can
prove is whether the controller boots — that needs a cluster, and is listed as
unproven in `docs/runbooks/ci.md` and `TASKS.md`.

## Known gaps

- The `ci` namespace has no manifest; it is created by hand (above).
- No `aws_ecr_repository` exists anywhere in Terraform, so `scanAndSign`'s push
  path has nothing to push to and skips with a stated reason.
- No cosign key exists, so nothing is signed. Both are `TASKS.md` entries, not
  silent skips.
- Ephemeral `pr-<n>` preview namespaces are not provisioned:
  `deployToStaging(prNumber: …)` fails with that sentence instead of applying to
  a namespace that does not exist.
