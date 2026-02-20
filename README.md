# gitops-repo

## Description

This repository is the GitOps source of truth for deploying applications to Kubernetes using Argo CD, ApplicationSets, and a single reusable Helm chart.

It is designed to be DRY:
- One generic Helm chart (`charts/generic-app`) that can deploy many services.
- Environment/application configuration lives in `apps/<app>/<env>/values.yaml`.
- Argo CD ApplicationSet automatically discovers:
  - Stable environments by scanning folders (`apps/*/{dev,staging,prod}`).
  - Ephemeral preview environments by scanning Pull Requests in `app-repo` (one environment per PR).

Promotion is Git-based:
- CI builds and pushes an image tagged with an immutable short Git SHA.
- CI updates only `image.tag` in the target environment values file.
- Argo CD detects the Git change and syncs the cluster to that exact artifact.

Repository layout (important paths):
- charts/generic-app/                  DRY base Helm chart (Deployment/Service/Ingress + optional HPA/PDB)
- apps/<app>/<env>/values.yaml         Env-specific values and the promotion anchor (image.tag)
- infra/appsets/*.yaml                 Argo CD ApplicationSet definitions
- infra/projects/*.yaml                Argo CD AppProject definitions (blast-radius control)

## Installation

### Prerequisites

1) Kubernetes cluster (k3s/k8s/minikube/EKS/etc.)
2) kubectl configured to access the cluster
3) Argo CD installed in namespace `argocd`
4) Access to this repository from Argo CD (HTTPS or SSH)
5) If using PR preview environments:
   - A GitHub Personal Access Token (PAT) with permission to read PR metadata
   - A Kubernetes Secret in `argocd` namespace containing the PAT (see below)
6) Ingress Controller installed (e.g., nginx ingress), if you enable ingress in values files

### Install Argo CD (quick install)

Note: In production you likely install Argo CD via Helm and manage it with GitOps as well. This quick install is convenient for labs/demos.

1) Create namespace:

```bash
kubectl create namespace argocd
```

2) Install Argo CD:

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

3) Wait for Argo CD to be ready:

```bash
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-repo-server
kubectl -n argocd rollout status deployment/argocd-application-controller
```

### Configure PR generator token (required only for PR preview environments)

The ApplicationSet PR generator references:

- secretName: github-token
- key: token

Create it (replace with your token):

```bash
kubectl -n argocd create secret generic github-token \
  --from-literal=token='<YOUR_GITHUB_PAT>'
```

Security note:
- Restrict who can create/modify ApplicationSets.
- Consider requiring a PR label (this repo’s ApplicationSet expects label "preview") to avoid creating environments for every PR.

### Apply GitOps resources from this repo

From a clone of gitops-repo:

1) Apply the Argo CD project (recommended blast-radius control):

```bash
kubectl apply -n argocd -f infra/projects/platform-project.yaml
```

2) Apply the ApplicationSet:

```bash
kubectl apply -n argocd -f infra/appsets/hello-web-applicationset.yaml
```

Verify resources:

```bash
kubectl -n argocd get appprojects
kubectl -n argocd get applicationsets
kubectl -n argocd get applications
```

If folder discovery is configured correctly, you should see generated Applications for:
- apps/hello-web/dev
- apps/hello-web/staging
- apps/hello-web/prod

## Usage

### How the system works (GitOps loop)

1) A container image is built in CI (in app-repo) and pushed to the registry.
2) CI updates the GitOps promotion anchor in this repo:
   - apps/<app>/<env>/values.yaml -> image.tag: "<immutable_sha>"
3) Argo CD detects the Git change and syncs the Kubernetes resources to match.
4) Promoting to another environment is a Git change:
   - Update the target env values file’s image.tag to the same already-built SHA.

This ensures:
- You promote the exact tested artifact.
- Cluster state always converges to Git state (pull model).

### Deploy / update dev, staging, prod (stable environments)

Stable environments are discovered by folder scanning:
- apps/*/dev
- apps/*/staging
- apps/*/prod

To deploy a new version to dev:
- Update apps/<app>/dev/values.yaml image.tag to the desired SHA and push.
- Argo CD will reconcile automatically.

Example using yq:

```bash
git clone https://github.com/example-org/gitops-repo.git
cd gitops-repo

yq -i '.image.tag = "a1b2c3d4"' apps/hello-web/dev/values.yaml

git add apps/hello-web/dev/values.yaml
git commit -m "chore(gitops): deploy hello-web dev -> a1b2c3d4"
git push origin main
```

Confirm Argo CD synced:

```bash
kubectl -n argocd get applications
```

Confirm the running app version:

```bash
kubectl -n hello-web-dev get pods
kubectl -n hello-web-dev port-forward svc/generic-app 8080:80

curl -s http://localhost:8080/ | jq .
```

Note:
- The chart name is generic and may produce stable names. What matters is the image tag and namespace.
- If you change naming, ensure Service/Ingress selectors still match.

### Promotion flow (Dev -> Staging -> Prod)

Promotion is changing only one field: image.tag.

Example: promote the same SHA from dev to staging:

1) Read dev’s current tag:

```bash
yq '.image.tag' apps/hello-web/dev/values.yaml
```

2) Set staging to the same tag:

```bash
TAG="$(yq -r '.image.tag' apps/hello-web/dev/values.yaml)"
yq -i ".image.tag = \"${TAG}\"" apps/hello-web/staging/values.yaml

git add apps/hello-web/staging/values.yaml
git commit -m "chore(gitops): promote hello-web staging -> ${TAG}"
git push origin main
```

Promote staging -> prod in the same way:

```bash
TAG="$(yq -r '.image.tag' apps/hello-web/staging/values.yaml)"
yq -i ".image.tag = \"${TAG}\"" apps/hello-web/prod/values.yaml

git add apps/hello-web/prod/values.yaml
git commit -m "chore(gitops): promote hello-web prod -> ${TAG}"
git push origin main
```

Recommended controls:
- Require PR approvals for staging/prod changes.
- Add Jenkins/manual approval gates for non-dev environment promotions.
- Use protected branches on gitops-repo.

### Ephemeral PR preview environments

Preview environments are generated from Pull Requests in app-repo using the ApplicationSet pullRequest generator.

Behavior:
- For each open PR with the label "preview", Argo CD generates:
  - An Application named like: hello-web-pr-<number>-<branch_slug>
  - A namespace like: pr-<number>-<branch_slug>
  - A Helm values override that sets image.tag = PR head_short_sha

This is DRY because:
- Base preview behavior is described once in apps/hello-web/preview/values.yaml
- Per-PR uniqueness (namespace, host, tag) comes from ApplicationSet templating

How to use:
1) Open a PR in app-repo
2) Add label "preview" to the PR
3) Ensure the PR image is built and pushed tagged by commit SHA (CI responsibility)
4) Argo CD will create the preview namespace and deploy it

Verify:

```bash
kubectl -n argocd get applications | grep hello-web-pr
kubectl get ns | grep '^pr-'
```

Cleanup:
- When the PR closes, the ApplicationSet no longer generates that Application.
- With automated pruning enabled, resources are removed.

Security note:
- PR generators can be abused if not controlled. Restrict who can label PRs and who can alter ApplicationSets.

### Adding a new application using the same generic chart

1) Create environment folders:

```bash
mkdir -p apps/my-service/dev apps/my-service/staging apps/my-service/prod
```

2) Add values files similar to hello-web:

apps/my-service/dev/values.yaml:
- image.repository: <your-registry>/<your-image>
- image.tag: <sha>
- ingress.hosts: <dev host>
- resources/probes/etc.

3) Commit and push:

```bash
git add apps/my-service
git commit -m "feat(gitops): add my-service environments"
git push origin main
```

4) ApplicationSet directory generator will auto-create Applications because it scans apps/*/{dev,staging,prod}.

### Common operations

List Applications:

```bash
kubectl -n argocd get applications
kubectl -n argocd get applicationsets
```

Force a refresh (rarely needed; Argo CD polls and also watches webhooks if configured):

```bash
kubectl -n argocd annotate applicationset hello-web \
  argocd.argoproj.io/refresh=hard --overwrite
```

Check sync status:

```bash
kubectl -n argocd get application hello-web-dev -o jsonpath='{.status.sync.status}{"\n"}'
kubectl -n argocd get application hello-web-dev -o jsonpath='{.status.health.status}{"\n"}'
```

### Why the configuration is production-oriented

Key best practices implemented:
- Git as the single source of truth (no kubectl apply from CI for app manifests)
- Immutable image tags for promotion safety (short SHA)
- AppProject used to limit allowed sources/destinations
- Automated sync + self-heal + prune for drift control
- Helm chart security defaults:
  - non-root, seccomp, readOnlyRootFilesystem, drop Linux capabilities
- Values separated by environment folder to reduce duplication and accidental cross-env changes

## License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
