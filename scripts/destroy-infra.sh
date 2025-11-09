#!/usr/bin/env bash
# Destroy infrastructure created by the GitHub deployment workflow.
# SAFE BY DEFAULT: requires explicit flags. Prompts for confirmation.
# Resources targeted:
#  - Kubernetes namespace (voting-app) + applied manifests
#  - EKS cluster (created via eksctl or aws eks)
#  - ECR repositories: vote, result, worker
# Optional (if you used them manually): RDS instance, ElastiCache cluster
#
# Usage examples:
#   ./scripts/destroy-infra.sh --all            # delete k8s resources, cluster, ECR repos
#   ./scripts/destroy-infra.sh --cluster        # delete only cluster (will prompt)
#   ./scripts/destroy-infra.sh --ecr            # delete only ECR repos
#   ./scripts/destroy-infra.sh --dry-run --all  # show what would be deleted
#   AWS_REGION=us-west-2 ./scripts/destroy-infra.sh --all
#
# Flags:
#   --all        : shorthand for --k8s --cluster --ecr
#   --k8s        : delete k8s namespace resources (voting-app)
#   --cluster    : delete EKS cluster
#   --ecr        : delete ECR repositories (vote,result,worker)
#   --rds <id>   : delete RDS instance (danger)
#   --elasticache <id> : delete ElastiCache replication group OR cluster (danger)
#   --force      : skip interactive confirmation
#   --dry-run    : show actions only
#   --region <r> : AWS region override
#
# Exit codes:
#   0 success, 1 usage error, >1 underlying AWS CLI errors.

set -euo pipefail
IFS=$'\n\t'

# Defaults
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${EKS_CLUSTER_NAME:-voting-app-cluster}"
NAMESPACE="voting-app"
ECR_REPOS=(
  voting-app/result
  voting-app/worker
  voting-app/voter
  voting-app/seed-data
)
DO_K8S=0
DO_CLUSTER=0
DO_ECR=0
DO_RDS_ID=""
DO_ELASTICACHE_ID=""
FORCE=0
DRY_RUN=0

log() { printf "[%s] %s\n" "$(date +'%Y-%m-%dT%H:%M:%S')" "$*"; }
err() { printf "[ERROR] %s\n" "$*" >&2; }
usage() { grep '^#' "$0" | sed 's/^# //'; exit 1; }

while (( "$#" )); do
  case "$1" in
    --all) DO_K8S=1; DO_CLUSTER=1; DO_ECR=1 ;;
    --k8s) DO_K8S=1 ;;
    --cluster) DO_CLUSTER=1 ;;
    --ecr) DO_ECR=1 ;;
    --rds) shift; DO_RDS_ID="${1:-}" ;;
    --elasticache) shift; DO_ELASTICACHE_ID="${1:-}" ;;
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --region) shift; AWS_REGION="${1:-}" ;;
    -h|--help) usage ;;
    *) err "Unknown arg: $1"; usage ;;
  esac
  shift || true
done

if [[ $DO_K8S$DO_CLUSTER$DO_ECR$DO_RDS_ID$DO_ELASTICACHE_ID == 000"""" ]]; then
  err "No actions specified. Use --all or individual flags."; usage
fi

log "Region: $AWS_REGION"

confirm() {
  local prompt="$1"; shift
  if [[ $FORCE -eq 1 ]]; then return 0; fi
  read -r -p "$prompt [y/N]: " ans || true
  [[ $ans == y || $ans == Y ]]
}

action() {
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: $desc"
  else
    log "$desc"
    "$@"
  fi
}

# Ensure AWS CLI available
if ! command -v aws >/dev/null 2>&1; then
  err "aws CLI not found. Install and retry."; exit 2
fi

# Optional: kubectl + eksctl checks only if needed
if [[ $DO_K8S -eq 1 || $DO_CLUSTER -eq 1 ]]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    log "kubectl not found - k8s deletion will attempt anyway after updating kubeconfig"
  fi
  if ! command -v eksctl >/dev/null 2>&1 && [[ $DO_CLUSTER -eq 1 ]]; then
    err "eksctl required for cluster deletion. Install from https://eksctl.io/"; exit 3
  fi
fi

log "Planned actions:"
[[ $DO_K8S -eq 1 ]] && log " - Delete Kubernetes namespace '$NAMESPACE' and applied manifests"
[[ $DO_CLUSTER -eq 1 ]] && log " - Delete EKS cluster '$CLUSTER_NAME'"
[[ $DO_ECR -eq 1 ]] && log " - Delete ECR repositories: ${ECR_REPOS[*]}"
[[ -n $DO_RDS_ID ]] && log " - Delete RDS instance: $DO_RDS_ID"
[[ -n $DO_ELASTICACHE_ID ]] && log " - Delete ElastiCache cluster/replication group: $DO_ELASTICACHE_ID"

if ! confirm "Proceed with destruction?"; then
  log "Aborted."; exit 0
fi

set +e  # Allow individual failures while continuing
STATUS=0

if [[ $DO_K8S -eq 1 ]]; then
  log "Deleting Kubernetes namespace resources..."
  # Try to update kubeconfig so kubectl can reach cluster (if still present)
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || log "(kubeconfig update failed; cluster may not exist)"
  if command -v kubectl >/dev/null 2>&1; then
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
      action "Delete manifests (best-effort)" bash -c "kubectl delete -f k8s-specifications/ -n $NAMESPACE --ignore-not-found || true"
      action "Delete namespace" kubectl delete namespace "$NAMESPACE" --ignore-not-found
    else
      log "Namespace '$NAMESPACE' not found; skipping."
    fi
  else
    log "kubectl unavailable; skipping k8s cleanup."
  fi
fi

if [[ $DO_ECR -eq 1 ]]; then
  for repo in "${ECR_REPOS[@]}"; do
    if aws ecr describe-repositories --repository-name "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
      action "Delete ECR repository $repo" aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION"
    else
      log "ECR repo '$repo' not found; skipping."
    fi
  done
fi

if [[ $DO_RDS_ID != "" ]]; then
  if aws rds describe-db-instances --db-instance-identifier "$DO_RDS_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    action "Delete RDS instance $DO_RDS_ID (no final snapshot)" aws rds delete-db-instance --db-instance-identifier "$DO_RDS_ID" --skip-final-snapshot --region "$AWS_REGION"
  else
    log "RDS instance '$DO_RDS_ID' not found; skipping."
  fi
fi

if [[ $DO_ELASTICACHE_ID != "" ]]; then
  # Try replication group first, then cluster
  if aws elasticache describe-replication-groups --replication-group-id "$DO_ELASTICACHE_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    action "Delete ElastiCache replication group $DO_ELASTICACHE_ID" aws elasticache delete-replication-group --replication-group-id "$DO_ELASTICACHE_ID" --region "$AWS_REGION"
  elif aws elasticache describe-cache-clusters --cache-cluster-id "$DO_ELASTICACHE_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    action "Delete ElastiCache cluster $DO_ELASTICACHE_ID" aws elasticache delete-cache-cluster --cache-cluster-id "$DO_ELASTICACHE_ID" --region "$AWS_REGION"
  else
    log "ElastiCache group/cluster '$DO_ELASTICACHE_ID' not found; skipping."
  fi
fi

if [[ $DO_CLUSTER -eq 1 ]]; then
  if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    action "Delete EKS cluster $CLUSTER_NAME" eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --disable-nodegroup-eviction
  else
    log "Cluster '$CLUSTER_NAME' not found; skipping."
  fi
fi

set -e
log "Destruction sequence complete."  
if [[ $DRY_RUN -eq 1 ]]; then
  log "(Dry run only - no changes were made)"
fi
exit $STATUS
