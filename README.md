# gitops-appset-demo-charts

GitOps source of truth for deploying applications to Kubernetes using Argo CD, ApplicationSets, and a single reusable Helm chart.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Repository Layout](#repository-layout)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Promotion Guide](#promotion-guide)
- [Adding a New Application](#adding-a-new-application)
- [PR Preview Environments](#pr-preview-environments)
- [Common Operations](#common-operations)
- [Known Gotchas](#known-gotchas)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  app-repo (github.com/ido83/gitops-appset-demo-app)              │
│  - Go application source                                          │
│  - Dockerfile                                                      │
│  - Jenkinsfile (builds image, updates values.yaml in this repo)  │
└────────────────────────┬─────────────────────────────────────────┘
                         │  Jenkins pushes image tag to ↓
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  gitops-appset-demo-charts (this repo)                           │
│  - Helm chart  (charts/generic-app)                              │
│  - Per-env values  (apps/hello-web/{dev,staging,prod}/values.yaml│
│  - ArgoCD ApplicationSet + AppProject                            │
└────────────────────────┬─────────────────────────────────────────┘
                         │  ArgoCD watches + syncs ↓
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  Kubernetes cluster                                               │
│  - hello-web-dev      (1 replica)                                │
│  - hello-web-staging  (2 replicas)                               │
│  - hello-web-prod     (3 replicas)                               │
└──────────────────────────────────────────────────────────────────┘
```

**Key design principles:**
- **Git is the single source of truth.** No `kubectl apply` from CI for app manifests.
- **Immutable tags.** Promotion means copying an already-built tag to the next env, never rebuilding.
- **DRY.** One Helm chart serves all environments and applications. Only `values.yaml` differs.
- **ApplicationSet auto-discovery.** Adding a folder under `apps/<app>/<env>/` automatically creates an ArgoCD Application — no manual ArgoCD config needed.

---

## Repository Layout

```
gitops-repo/
├── apps/
│   └── hello-web/
│       ├── dev/
│       │   └── values.yaml       ← promotion anchor (Jenkins updates image.tag here)
│       ├── staging/
│       │   └── values.yaml
│       ├── prod/
│       │   └── values.yaml
│       └── preview/
│           └── values.yaml       ← base values for PR preview environments
├── charts/
│   └── generic-app/              ← reusable Helm chart
│       ├── Chart.yaml
│       ├── values.yaml           ← chart defaults
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           ├── hpa.yaml
│           ├── pdb.yaml
│           └── serviceaccount.yaml
└── infra/
    ├── appsets/
    │   └── hello-web-applicationset.yaml   ← ArgoCD ApplicationSet
    └── projects/
        └── platform-project.yaml           ← ArgoCD AppProject (blast-radius control)
```

> **Note:** All paths above are relative to `gitops-repo/` inside this repository.
> When referencing paths in ArgoCD manifests, prefix with `gitops-repo/`
> (e.g. `gitops-repo/charts/generic-app`, `gitops-repo/apps/hello-web/dev`).

---

## How It Works

### GitOps loop

```
1. Developer merges code to app-repo
       ↓
2. Jenkins builds & pushes image
       docker build -t idona/demo-app-set:v2 .
       docker push idona/demo-app-set:v2
       ↓
3. Jenkins updates dev values.yaml
       image.tag: "v1" → "v2"
       git commit + push → this repo
       ↓
4. ArgoCD detects the Git change (polls every ~3 min or via webhook)
       ↓
5. ArgoCD syncs hello-web-dev → rolls out idona/demo-app-set:v2
       ↓
6. After verification, a human (or automated gate) promotes to staging
       (same image tag, new env values.yaml updated, Git commit + push)
       ↓
7. ArgoCD syncs hello-web-staging
       ↓
8. Repeat for prod (with approval gate in Jenkins pipeline)
```

### ApplicationSet directory generator

The ApplicationSet scans `gitops-repo/apps/*/dev|staging|prod` for directories. Each directory maps to one ArgoCD Application:

| Directory | ArgoCD Application | Namespace |
|-----------|-------------------|-----------|
| `gitops-repo/apps/hello-web/dev` | `hello-web-dev` | `hello-web-dev` |
| `gitops-repo/apps/hello-web/staging` | `hello-web-staging` | `hello-web-staging` |
| `gitops-repo/apps/hello-web/prod` | `hello-web-prod` | `hello-web-prod` |

To add a new app/env, just add a folder — ArgoCD picks it up automatically.

---

## Prerequisites

1. Kubernetes cluster (minikube, k3s, EKS, GKE, etc.)
2. `kubectl` configured to access the cluster
3. ArgoCD installed in namespace `argocd`
4. Docker Hub account (images are pushed to `docker.io/idona/demo-app-set`)
5. GitHub access to both repos:
   - `github.com/ido83/gitops-appset-demo-charts` (this repo)
   - `github.com/ido83/gitops-appset-demo-app` (app source)
6. Ingress controller if you enable ingress in values files (e.g., `minikube addons enable ingress`)

---

## Installation

### 1. Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all components to be ready
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller
```

### 2. Apply the AppProject

The AppProject restricts which repos and destinations ArgoCD can use — limits blast radius.

```bash
kubectl apply -f gitops-repo/infra/projects/platform-project.yaml
```

### 3. Apply the ApplicationSet

```bash
kubectl apply -f gitops-repo/infra/appsets/hello-web-applicationset.yaml
```

### 4. Verify

```bash
# Should show hello-web ApplicationSet
kubectl -n argocd get applicationsets

# After ~30 seconds, should show hello-web-dev, hello-web-staging, hello-web-prod
kubectl -n argocd get applications

# Check pods are running
kubectl get pods -n hello-web-dev
kubectl get pods -n hello-web-staging
kubectl get pods -n hello-web-prod
```

Expected output:
```
NAME                SYNC STATUS   HEALTH STATUS
hello-web-dev       Synced        Healthy
hello-web-staging   Synced        Healthy
hello-web-prod      Synced        Healthy
```

### 5. (Optional) Enable PR preview environments

The PR generator is disabled by default until the GitHub token secret exists.
To enable it:

```bash
# Create a GitHub PAT with read access to pull request metadata
kubectl -n argocd create secret generic github-token \
  --from-literal=token='<YOUR_GITHUB_PAT>'
```

Then uncomment the `pullRequest` generator block in
`gitops-repo/infra/appsets/hello-web-applicationset.yaml` and re-apply.

---

## Promotion Guide

Promotion = updating `image.tag` in a target environment's `values.yaml`, committing, and pushing.
ArgoCD detects the Git change and rolls out the new version automatically.

### The promotion anchor

Each environment has one file that acts as the promotion anchor:

```
gitops-repo/apps/hello-web/
├── dev/values.yaml       ← image.tag updated here first (by Jenkins or manually)
├── staging/values.yaml   ← promoted from dev
└── prod/values.yaml      ← promoted from staging (requires approval gate)
```

The only field that changes during promotion:

```yaml
image:
  repository: idona/demo-app-set
  tag: "v2"              # ← this is the promotion anchor
```

---

### Step-by-step: Promote dev → staging

**Step 1 — confirm what tag is currently running in dev:**

```bash
kubectl get deployment -n hello-web-dev \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'
# idona/demo-app-set:v2

# Or read directly from the values file:
grep 'tag:' gitops-repo/apps/hello-web/dev/values.yaml
# tag: "v2"
```

**Step 2 — update staging values.yaml:**

```bash
# Using yq (recommended — safe YAML edit):
TAG="$(yq -r '.image.tag' gitops-repo/apps/hello-web/dev/values.yaml)"

yq -i ".image.tag = \"${TAG}\""                    gitops-repo/apps/hello-web/staging/values.yaml
yq -i ".appMetadata.lastPromotedTag = \"${TAG}\""  gitops-repo/apps/hello-web/staging/values.yaml
```

Or edit manually in your editor — change only the `tag` field in
[gitops-repo/apps/hello-web/staging/values.yaml](gitops-repo/apps/hello-web/staging/values.yaml).

**Step 3 — commit and push:**

```bash
git add gitops-repo/apps/hello-web/staging/values.yaml
git commit -m "chore(gitops): promote hello-web staging -> ${TAG}"
git push origin master
```

**Step 4 — ArgoCD syncs automatically (within ~3 minutes). Verify:**

```bash
kubectl -n argocd get application hello-web-staging
# NAME                SYNC STATUS   HEALTH STATUS
# hello-web-staging   Synced        Healthy

kubectl get deployment -n hello-web-staging \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'
# idona/demo-app-set:v2
```

**Force immediate sync (optional — skips the poll wait):**

```bash
kubectl -n argocd patch application hello-web-staging \
  --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

---

### Step-by-step: Promote staging → prod

Same flow, different file. In production, this should be gated behind a PR approval or Jenkins `input` step.

```bash
TAG="$(yq -r '.image.tag' gitops-repo/apps/hello-web/staging/values.yaml)"

yq -i ".image.tag = \"${TAG}\""                    gitops-repo/apps/hello-web/prod/values.yaml
yq -i ".appMetadata.lastPromotedTag = \"${TAG}\""  gitops-repo/apps/hello-web/prod/values.yaml

git add gitops-repo/apps/hello-web/prod/values.yaml
git commit -m "chore(gitops): promote hello-web prod -> ${TAG}"
git push origin master
```

---

### Full promotion flow (all envs in one script)

```bash
#!/usr/bin/env bash
set -euo pipefail

APP="hello-web"
TAG="${1:?Usage: $0 <image-tag>}"   # e.g. ./promote.sh v3

REPO_ROOT="gitops-repo"

for ENV in dev staging prod; do
  FILE="${REPO_ROOT}/apps/${APP}/${ENV}/values.yaml"
  echo "Promoting ${APP} ${ENV} -> ${TAG}"
  yq -i ".image.tag = \"${TAG}\""                   "${FILE}"
  yq -i ".appMetadata.lastPromotedTag = \"${TAG}\"" "${FILE}"
  git add "${FILE}"
done

git commit -m "chore(gitops): promote ${APP} all envs -> ${TAG}"
git push origin master
```

---

### Rollback

Rollback is just promoting an older tag. Find the last known-good tag in git history:

```bash
git log --oneline gitops-repo/apps/hello-web/prod/values.yaml
# abc1234 chore(gitops): promote hello-web prod -> v2
# def5678 chore(gitops): promote hello-web prod -> v1  ← rollback target

# Promote v1 back to prod:
yq -i '.image.tag = "v1"' gitops-repo/apps/hello-web/prod/values.yaml
git add gitops-repo/apps/hello-web/prod/values.yaml
git commit -m "chore(gitops): rollback hello-web prod -> v1"
git push origin master
```

---

## Adding a New Application

1. Create environment folders:

```bash
mkdir -p gitops-repo/apps/my-service/{dev,staging,prod}
```

2. Create `values.yaml` in each folder (copy from `hello-web` as a template):

```bash
cp gitops-repo/apps/hello-web/dev/values.yaml     gitops-repo/apps/my-service/dev/values.yaml
cp gitops-repo/apps/hello-web/staging/values.yaml gitops-repo/apps/my-service/staging/values.yaml
cp gitops-repo/apps/hello-web/prod/values.yaml    gitops-repo/apps/my-service/prod/values.yaml
```

3. Edit each file: update `image.repository`, `image.tag`, `ingress.hosts`, and `appMetadata.environment`.

4. Commit and push:

```bash
git add gitops-repo/apps/my-service
git commit -m "feat(gitops): add my-service environments"
git push origin master
```

5. The ApplicationSet directory generator auto-discovers the new folders and creates:
   - `my-service-dev` Application → namespace `my-service-dev`
   - `my-service-staging` Application → namespace `my-service-staging`
   - `my-service-prod` Application → namespace `my-service-prod`

No manual ArgoCD configuration needed.

---

## PR Preview Environments

When enabled, the ApplicationSet's `pullRequest` generator creates an ephemeral environment for each open PR in `gitops-appset-demo-app` that has the `preview` label.

| What | Value |
|------|-------|
| Application name | `hello-web-pr-<number>-<branch-slug>` |
| Namespace | `pr-<number>-<branch-slug>` |
| Image tag | PR head commit SHA (set by CI) |
| Ingress host | `hello-web-pr-<number>-<branch-slug>.example.local` |

**To enable:**

```bash
kubectl -n argocd create secret generic github-token \
  --from-literal=token='<YOUR_GITHUB_PAT>'
```

Then uncomment the `pullRequest` generator block in the ApplicationSet and re-apply.

**Lifecycle:**
- Environment is created when a PR gets the `preview` label.
- Environment is destroyed when the PR is closed/merged (ArgoCD prune removes it).

---

## Common Operations

**List all ArgoCD Applications:**
```bash
kubectl -n argocd get applications
```

**Check sync + health status of one app:**
```bash
kubectl -n argocd get application hello-web-dev \
  -o jsonpath='Sync: {.status.sync.status}  Health: {.status.health.status}{"\n"}'
```

**Force immediate refresh (re-read Git):**
```bash
kubectl -n argocd patch application hello-web-dev \
  --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

**Check what image is running:**
```bash
kubectl get deployment -n hello-web-dev \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'
```

**Port-forward to test the app directly:**
```bash
kubectl -n hello-web-dev port-forward svc/hello-web 8080:80
curl http://localhost:8080/
```

---

## Known Gotchas

Lessons learned deploying this demo — here to save you time:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `app path does not exist` | Chart path missing `gitops-repo/` prefix | Use `gitops-repo/charts/generic-app`, not `charts/generic-app` |
| `unable to resolve 'main' to a commit SHA` | Branch is `master`, not `main` | Set `revision: master` and `targetRevision: master` in ApplicationSet |
| `resource :Namespace is not permitted in project` | AppProject `clusterResourceWhitelist` is empty | Add `- group: "" kind: Namespace` to `clusterResourceWhitelist` |
| `container has runAsNonRoot and image has non-numeric user (nonroot)` | Distroless uses named user, Kubernetes needs numeric UID | Add `runAsUser: 65532` + `runAsGroup: 65532` to `podSecurityContext` |
| `error converting YAML to JSON` on ApplicationSet apply | Go template `{{- if }}` inside `valuesObject` is not valid YAML | Use `values` (string) instead of `valuesObject` (structured) |
| PR generator crashes on startup | `github-token` Secret missing in `argocd` namespace | Create the secret or comment out the `pullRequest` generator |
| Applications generated but 0 resources synced | `apps/*/env` paths don't match actual repo layout | Paths in the `git` generator must match the repo directory structure exactly |
