#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT/deploy/aws/helm/multica"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for command in helm terraform python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "required validation tool is missing: $command" >&2
    exit 1
  fi
done

helm lint "$CHART" -f "$ROOT/deploy/aws/helm/values-dev.yaml"
helm lint "$CHART" -f "$ROOT/deploy/aws/helm/values-prod.yaml"
helm template multica "$CHART" -n multica -f "$ROOT/deploy/aws/helm/values-dev.yaml" >"$TMP_DIR/dev.yaml"
helm template multica "$CHART" -n multica -f "$ROOT/deploy/aws/helm/values-prod.yaml" >"$TMP_DIR/prod.yaml"

python3 "$ROOT/scripts/validate-deployment.py" \
  "$ROOT/deploy/aws/helm/multica/values.yaml" \
  "$ROOT/deploy/aws/helm/multica/values.schema.json" \
  "$ROOT/deploy/aws/helm/values-dev.yaml" \
  "$ROOT/deploy/aws/helm/values-prod.yaml" \
  "$TMP_DIR/dev.yaml" "$TMP_DIR/prod.yaml"

if grep -Eiq 'kind:[[:space:]]*(ScaledObject|ScaledJob)|aws_sqs|outbox[-_ ]relay|agent[-_ ]worker|dead[-_ ]letter|\bdlq\b' "$TMP_DIR/prod.yaml" "$ROOT"/deploy/aws/terraform/*.tf; then
  echo "forbidden deployment topology found" >&2
  exit 1
fi

if grep -Eq 'image: .*:latest([[:space:]]|$)' "$TMP_DIR/dev.yaml" "$TMP_DIR/prod.yaml"; then
  echo "mutable latest image found" >&2
  exit 1
fi

grep -q '^USER 10001:10001$' "$ROOT/multica/Dockerfile"
grep -q 'RUN_MIGRATIONS' "$ROOT/multica/docker/entrypoint.sh"
grep -Fq 'ARG GO_BASE_IMAGE=public.ecr.aws/docker/library/golang:1.26-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2' "$ROOT/multica/Dockerfile"
grep -Fq 'ARG RUNTIME_BASE_IMAGE=public.ecr.aws/docker/library/alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d' "$ROOT/multica/Dockerfile"
grep -Fq 'ARG NODE_BASE_IMAGE=public.ecr.aws/docker/library/node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32' "$ROOT/multica/Dockerfile.web"
if grep -Eq '^FROM (golang|alpine|node):' "$ROOT/multica/Dockerfile" "$ROOT/multica/Dockerfile.web"; then
  echo "unqualified Docker Hub base image found" >&2
  exit 1
fi

terraform -chdir="$ROOT/deploy/aws/terraform" fmt -check -recursive
terraform -chdir="$ROOT/deploy/aws/terraform" init -backend=false -input=false
terraform -chdir="$ROOT/deploy/aws/terraform" validate

echo "deployment artifact validation passed"
