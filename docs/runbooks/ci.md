# Runbook — Jenkins (Phase 7 and 8)

**Last verified: not yet — this phase has no cluster.** Every command below is one
that will be run and its output pasted into `docs/evidence/` on the first deploy.
Until then the commands are correct and untested; that state is the honest one.
What *is* verified is everything that does not need a cluster: `helm lint
--strict`, `helm template`, `kubeconform`, `conftest`, `shellcheck`, `actionlint`,
`gitleaks` and `trivy config` all pass on this phase, and the Jenkinsfile's gates
run those same commands in pinned containers.

Install and secret seeding live in `ci/jenkins/README.md`. This file is for when
something is wrong.

## Diagnostic entry point

```bash
# Is the controller up, and what is it doing?
kubectl -n ci get pods,sts,svc,pvc
kubectl -n ci logs sts/ci --tail=100

# The events, in time order. Pending pods, quota refusals and failed mounts
# all announce themselves here and nowhere else.
kubectl -n ci get events --sort-by=.lastTimestamp | tail -30

# Does the edge reach it? A 502 here with the pod Running means the route,
# the port or the URL, not the controller.
curl -sSI https://<jenkinsHost>/

# Are agent pods appearing at all? (they are named agent-*)
kubectl -n ci get pods | grep -c '^agent-'

# The backup job's last attempt.
kubectl -n ci get jobs,cronjob
kubectl -n ci logs job/$(kubectl -n ci get jobs -o name | tail -1) 2>/dev/null
```

---

## 1. The controller never becomes Ready

**Symptom:** `kubectl -n ci get pods` shows `ContainerCreating` or
`CrashLoopBackOff`, and `describe` mentions one of the three Secrets.

**Most likely cause, in order:**

1. `jenkins-admin` does not exist (or is missing `jenkins-admin-user` /
   `jenkins-admin-password`). The chart projects it as a volume; a missing key
   fails the mount and the pod never starts. This is deliberate: a controller
   that boots with a default password is worse than one that does not boot.
2. ServiceAccount `jenkins` does not exist — `ci/rbac/` was not applied, or was
   applied to the wrong namespace.
3. The PVC is `Pending` — no `local-path` StorageClass (it is created by
   `cluster/policies/`; check `kubectl get sc`).

**Diagnose:**

```bash
kubectl -n ci describe pod -l app.kubernetes.io/component=jenkins-controller | tail -30
kubectl -n ci get secret jenkins-admin jenkins-pipeline-credentials jenkins-backup-credentials
kubectl get storageclass
```

## 2. Jenkins loads but is empty (no jobs, no libraries, no security)

**Symptom:** the UI answers, but the shared library is unknown, the matrix
authorization is gone, or every job is `NoSuchMethodError`.

**Cause:** JCasC did not apply. The chart's `autoReload` must be on — with it
off the chart emits no JCasC ConfigMaps at all and the controller boots from
whatever `config.xml` is on the PVC. The `config-reload` sidecar is what turns a
ConfigMap edit into a reload without a restart.

**Diagnose:**

```bash
kubectl -n ci get cm | grep jcasc
kubectl -n ci logs sts/ci -c config-reload --tail=50
kubectl -n ci exec sts/ci -- sh -c 'ls -l /var/jenkins_home/casc_configs 2>/dev/null'
```

If the ConfigMaps exist and the sidecar is quiet, restart the controller:
`kubectl -n ci rollout restart sts/ci` (the PVC keeps the state).

## 3. Login redirects to a host that does not resolve

**Symptom:** after login the browser goes to `http://ci:8080/…` or to a
certificate error.

**Cause:** `jenkins.controller.jenkinsUrl` does not match the hostname
IngressRoute `jenkins` matches. They are set in two different places — the
route's `jenkinsHost` (Traefik values) and `--set
jenkins.controller.jenkinsUrl=…` (this install) — and only agree if you made
them agree.

```bash
helm -n ci get values ci | grep jenkinsUrl
kubectl -n traefik get ingressroute jenkins -o yaml | grep match
```

Fix with `helm upgrade ci ci/jenkins -n ci --set …`, not by editing the PVC.

## 4. A build queues forever

**Symptom:** the build sits in the queue; no agent pod appears, or one appears
`Pending`.

**Most likely cause, in order:**

1. **ResourceQuota.** The `ci` quota is 2000m/8Gi of requests, 4000m/12Gi of
   limits, 12 pods. Controller (120m/576Mi) + eight agents (200m/768Mi each)
   fit; a ninth does not, and the pod is refused at creation with
   `exceeded quota: ci-quota` in the events. `containerCap: "8"` exists so the
   refusal is Jenkins' limit rather than a mystery.
2. **The agent image cannot be pulled** (`jenkins/inbound-agent:…-jdk25`), so
   the pod sits `ImagePullBackOff`.
3. **`containerCap` already reached** — eight builds running or stuck.

```bash
kubectl -n ci get events | grep -iE 'quota|pull|failed'
kubectl -n ci get resourcequota ci-quota -o jsonpath='{.status}'; echo
kubectl -n ci describe pod | grep -A4 '^Events'
```

Alert `JenkinsQueueBacklog` in `observability/rules/boutique-alerts.yaml` is the
signal for this state.

## 5. The agent runs but every `container('dind')` step fails

**Symptom:** shell steps pass, then `docker: not found` or a TLS handshake error.

**Cause:** either the steps are running in the wrong container (the jnlp
container has no docker CLI by design — `vars/tools.groovy` switches to `dind`
for exactly this reason), or `DOCKER_TLS_CERTDIR` came back non-empty, in which
case dockerd listens on 2376 and `DOCKER_HOST` still points at 2375.

```bash
kubectl -n ci get pod agent-xxxx -o yaml | grep -A2 DOCKER_
kubectl -n ci exec agent-xxxx -c dind -- docker version --format '{{.Server.Version}}'
```

`values.yaml` pins `DOCKER_TLS_CERTDIR` to an empty string; a `helm upgrade`
that drops it is the regression to look for.

## 6. A gate is red in Jenkins but green on the laptop

**Symptom:** `helm lint`, `conftest`, `kubeconform` or `trivy` fails in CI only.

**Cause:** the two runs are supposed to be the same command in the same pinned
image (`pipelines/vars/toolImages.groovy` lists every tag, each verified against
its registry). What differs is the input: CI sees the merge of your change plus
whatever `main` has, and it scans the whole tree while `scripts/check.sh` may
have been run on a subset. Read the failing gate's name — it names the command:

```bash
# reproduce, with the same image Jenkins used
docker run --rm -u 0 -e HOME=/tmp -v "$PWD:/work" -w /work \
  openpolicyagent/conftest:v0.68.0 \
  test apps cluster ci observability -p policy --ignore 'apps/boutique/(upstream-kubernetes-manifests\.yaml|chaos/)|/templates/|(values\.yaml|Chart\.ya?ml|Chart\.lock)$|/rules/|/slos/|alerts\.yaml$'
```

A gate that is red because the tool moved (a tag re-pointed, a new check bundle)
is fixed by pinning, and the pins are in `toolImages.groovy`.

## 7. The backup job fails at `aws s3 cp`

**Symptom:** the pod starts, `tar` succeeds, `aws s3 cp` returns
`NoSuchBucket` or `AccessDenied`.

**Cause:** both are expected today. The bucket is Terraform and has not been
applied (`TASKS.md`); the credential Secret must exist or the pod never starts
at all. The job is deliberately written to fail loudly rather than to skip —
a backup that silently does nothing is indistinguishable from a backup that
works until the day it does not.

```bash
kubectl -n ci create job --from=cronjob/jenkins-backup manual-1   # run it now
kubectl -n ci logs job/manual-1
```

---

## The pipeline, in one table

| stage | does | when it runs |
|---|---|---|
| Build & test | 12 gates: `git log --check`, conflict markers, `bash -n`, shellcheck, actionlint, `helm dependency build`/`lint`/`template`, conftest (manifests), conftest (the should-fail fixtures), kubeconform, gitleaks | always |
| Scan & sign | `trivy config` on the manifests; then image scan, syft SBOM, cosign, push | manifest scan always; image steps only with `APP_IMAGE` |
| Deploy to staging | `kubectl apply` + `rollout status` | `APP_MANIFESTS` or `APP_ROLLOUT` set |
| Smoke gate | N samples, zero-error budget + latency ceiling (`pipelines/resources/smoke.sh`) | `APP_URL` set |
| Canary | shifts Traefik weights, samples `BURN_QUERY`, and rolls back on breach or on missing data (`pipelines/resources/canary.sh`) | all six canary parameters set |
| Promote to production | `input` approval (submitter `platform:admins`), then apply + rollout | `APP_MANIFESTS` or `APP_ROLLOUT` set |

Stages that have no input say so in the log and stop. Nothing in this pipeline
reports a release it did not perform.

## Rollback

```bash
helm history ci -n ci
helm rollback ci <revision> -n ci
kubectl -n ci rollout status sts/ci
```

An application release is rolled back by the canary script itself (`rollout
undo` plus the traffic weights restored) before anyone is asked for anything.

## Cost note

The controller is 120m/576Mi of requests. The cost is in the agents: 200m/768Mi
each, up to eight, i.e. 1600m/6Gi of requests that only exist while a build
runs — and `idleMinutes: 5` is what bounds how long they linger. The arithmetic
against the `ci` quota and the node budget is `docs/resource-budget.md` §4.

## What is unproven

Nothing below has been run, because running it needs a cluster and starting one
is not this phase's gate:

- the controller booting, JCasC applying, and the plugin pins resolving
- agent pods starting, `container('dind')` reaching a daemon, buildx building
- the backup CronJob succeeding end to end (the bucket does not exist yet)
- cosign signing and any registry push (no key, no ECR repository)
- the smoke gate, the canary's rollback, and the approval dialog — each needs a
  deployed application to act on, and this repository deploys none of its own

Each of these has a `TASKS.md` entry; none is marked done here.
