#!/usr/bin/env bash
# promote.sh — Git-SHA-anchored GitOps promotion script
#
# Each promotion carries the git SHA of the source environment's last values.yaml commit
# into the target environment's promotionAnchor.gitSHA field.
#
# This ensures:
#   - You can only promote from a clean, committed state (no dirty local changes).
#   - The exact git commit that was tested in the source env is traceable in the target.
#   - staging→prod refuses to promote if staging was never promoted via this script
#     (anchor SHA would be empty, indicating a manual/untrusted edit).
#
# Usage:
#   ./scripts/promote.sh <from-env> <to-env> [app]
#
# Examples:
#   ./scripts/promote.sh dev staging
#   ./scripts/promote.sh dev staging hello-web
#   ./scripts/promote.sh staging prod hello-web
#
# Promotion chain: ci → dev → staging → prod
#
# Requirements: git, yq (https://github.com/mikefarah/yq)

set -euo pipefail

# ── arguments ──────────────────────────────────────────────────────────────────
FROM_ENV="${1:?Usage: $0 <from-env> <to-env> [app]}"
TO_ENV="${2:?Usage: $0 <from-env> <to-env> [app]}"
APP="${3:-hello-web}"

# ── paths ──────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
FROM_FILE="${REPO_ROOT}/gitops-repo/apps/${APP}/${FROM_ENV}/values.yaml"
TO_FILE="${REPO_ROOT}/gitops-repo/apps/${APP}/${TO_ENV}/values.yaml"

# ── validate inputs ────────────────────────────────────────────────────────────
if [[ ! -f "${FROM_FILE}" ]]; then
  echo "ERROR: source values file not found: ${FROM_FILE}" >&2
  exit 1
fi

if [[ ! -f "${TO_FILE}" ]]; then
  echo "ERROR: target values file not found: ${TO_FILE}" >&2
  exit 1
fi

# Guard: refuse to promote from a dirty (uncommitted) source file.
# Promoting uncommitted changes would make the anchor SHA meaningless.
if ! git -C "${REPO_ROOT}" diff --quiet -- "${FROM_FILE}"; then
  echo "ERROR: ${FROM_FILE} has uncommitted local changes." >&2
  echo "       Commit or stash them before promoting." >&2
  exit 1
fi

# Guard: for staging→prod, require that staging was promoted via this script
# (i.e. its anchor SHA is non-empty). An empty anchor means staging was edited
# manually and has not been through the controlled promotion flow.
if [[ "${FROM_ENV}" != "dev" ]]; then
  EXISTING_ANCHOR="$(yq -r '.appMetadata.promotionAnchor.gitSHA // ""' "${FROM_FILE}")"
  if [[ -z "${EXISTING_ANCHOR}" ]]; then
    echo "ERROR: ${FROM_ENV}/values.yaml has no promotionAnchor.gitSHA." >&2
    echo "       ${FROM_ENV} must be promoted via promote.sh before promoting to ${TO_ENV}." >&2
    exit 1
  fi
fi

# ── read source state ──────────────────────────────────────────────────────────
IMAGE_TAG="$(yq -r '.image.tag' "${FROM_FILE}")"
IMAGE_REPO="$(yq -r '.image.repository' "${FROM_FILE}")"

# The anchor SHA is the git commit that last touched the source values file.
# This is the exact, tested, committed state we are about to promote.
ANCHOR_SHA="$(git -C "${REPO_ROOT}" log -1 --format='%H' -- "${FROM_FILE}")"
ANCHOR_SHA_SHORT="${ANCHOR_SHA:0:8}"
PROMOTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── print promotion plan ───────────────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  GitOps Promotion                                   │"
echo "├─────────────────────────────────────────────────────┤"
printf "│  App        : %-37s│\n" "${APP}"
printf "│  From       : %-37s│\n" "${FROM_ENV}"
printf "│  To         : %-37s│\n" "${TO_ENV}"
printf "│  Image      : %-37s│\n" "${IMAGE_REPO}:${IMAGE_TAG}"
printf "│  Anchor SHA : %-37s│\n" "${ANCHOR_SHA_SHORT}"
printf "│  Promoted at: %-37s│\n" "${PROMOTED_AT}"
echo "└─────────────────────────────────────────────────────┘"
echo ""

# ── apply changes to target values file ───────────────────────────────────────
yq -i ".image.tag = \"${IMAGE_TAG}\""                                        "${TO_FILE}"
yq -i ".image.repository = \"${IMAGE_REPO}\""                               "${TO_FILE}"
yq -i ".appMetadata.lastPromotedTag = \"${IMAGE_TAG}\""                     "${TO_FILE}"
yq -i ".appMetadata.promotionAnchor.gitSHA = \"${ANCHOR_SHA_SHORT}\""      "${TO_FILE}"
yq -i ".appMetadata.promotionAnchor.promotedAt = \"${PROMOTED_AT}\""       "${TO_FILE}"
yq -i ".appMetadata.promotionAnchor.fromEnv = \"${FROM_ENV}\""             "${TO_FILE}"

# ── commit and push ────────────────────────────────────────────────────────────
git -C "${REPO_ROOT}" add "${TO_FILE}"
git -C "${REPO_ROOT}" commit -m \
  "chore(gitops): promote ${APP} ${FROM_ENV}→${TO_ENV} tag=${IMAGE_TAG} anchor=${ANCHOR_SHA_SHORT}"
git -C "${REPO_ROOT}" push origin master

echo "Promoted ${APP} to ${TO_ENV}."
echo "  ArgoCD will sync hello-${APP}-${TO_ENV} within ~3 minutes."
echo "  Force immediate sync:"
echo "    kubectl -n argocd patch application ${APP}-${TO_ENV} \\"
echo "      --type merge -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"hard\"}}}'"
