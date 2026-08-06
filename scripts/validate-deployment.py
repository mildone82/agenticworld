#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import jsonschema
import yaml


def merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


def documents(path: str) -> list[dict[str, Any]]:
    return [doc for doc in yaml.safe_load_all(Path(path).read_text()) if isinstance(doc, dict)]


def resource_count(resources: list[dict[str, Any]], kind: str, component: str | None = None) -> int:
    count = 0
    for resource in resources:
        if resource.get("kind") != kind:
            continue
        labels = resource.get("metadata", {}).get("labels", {})
        if component is None or labels.get("app.kubernetes.io/component") == component:
            count += 1
    return count


def main() -> None:
    if len(sys.argv) != 7:
        raise SystemExit("expected base values, schema, dev values, prod values, dev render, prod render")

    base = yaml.safe_load(Path(sys.argv[1]).read_text())
    schema = json.loads(Path(sys.argv[2]).read_text())
    dev = merge(base, yaml.safe_load(Path(sys.argv[3]).read_text()))
    prod = merge(base, yaml.safe_load(Path(sys.argv[4]).read_text()))
    jsonschema.validate(dev, schema)
    jsonschema.validate(prod, schema)

    assert dev["backend"]["replicas"] == 1
    assert dev["backend"]["config"]["redisUrl"] == ""
    assert dev["backend"]["config"]["s3Bucket"] == ""

    assert prod["backend"]["replicas"] >= 2
    assert prod["frontend"]["replicas"] >= 2
    assert prod["backend"]["config"]["redisUrl"].startswith("rediss://")
    assert prod["backend"]["config"]["s3Bucket"]
    assert prod["networkPolicy"]["databaseCidrs"] == ["10.40.0.0/16"]
    assert prod["networkPolicy"]["redisCidrs"] == ["10.40.0.0/16"]
    assert prod["images"]["backend"]["tag"] == prod["images"]["frontend"]["tag"]
    for component in ("backend", "frontend"):
        assert prod["images"][component]["digest"].startswith("sha256:")
        assert prod[component]["securityContext"]["readOnlyRootFilesystem"] is True
        assert prod[component]["securityContext"]["allowPrivilegeEscalation"] is False

    dev_resources = documents(sys.argv[5])
    prod_resources = documents(sys.argv[6])
    assert resource_count(dev_resources, "Deployment", "backend") == 1
    assert resource_count(dev_resources, "Deployment", "frontend") == 1
    assert resource_count(prod_resources, "Deployment", "backend") == 1
    assert resource_count(prod_resources, "Deployment", "frontend") == 1
    assert resource_count(prod_resources, "Job", "migration") == 1
    assert resource_count(prod_resources, "NetworkPolicy") == 3
    assert resource_count(prod_resources, "PodDisruptionBudget") == 2
    assert resource_count(prod_resources, "ServiceMonitor") == 1
    assert resource_count(prod_resources, "PrometheusRule") == 1

    services = {r["metadata"]["name"]: r for r in prod_resources if r.get("kind") == "Service"}
    assert services["multica-backend"]["metadata"]["annotations"]["alb.ingress.kubernetes.io/healthcheck-path"] == "/healthz"
    assert services["multica-frontend"]["metadata"]["annotations"]["alb.ingress.kubernetes.io/healthcheck-path"] == "/"

    backend = next(r for r in prod_resources if r.get("kind") == "Deployment" and r["metadata"]["name"] == "multica-backend")
    probes = backend["spec"]["template"]["spec"]["containers"][0]
    assert probes["livenessProbe"]["httpGet"]["path"] == "/health"
    assert probes["readinessProbe"]["httpGet"]["path"] == "/readyz"

    migration = next(r for r in prod_resources if r.get("kind") == "Job")
    assert "serviceAccountName" not in migration["spec"]["template"]["spec"]


if __name__ == "__main__":
    main()
