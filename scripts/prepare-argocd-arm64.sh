#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE="/tmp/argocd-install.yaml"
OUTPUT="/tmp/argocd-arm64-install.yaml"

test -s "$SOURCE" || {
  echo "ERROR: Official Argo CD manifest missing"
  exit 1
}

echo "===== PATCHING ARGO CD FOR ARM64 ====="

python3 - <<'PY'
import yaml

source = "/tmp/argocd-install.yaml"
output = "/tmp/argocd-arm64-install.yaml"

optional = {
    "argocd-applicationset-controller",
    "argocd-dex-server",
    "argocd-notifications-controller",
}

resources = {
    "argocd-application-controller": (250, 256, 500, 512),
    "argocd-repo-server": (100, 256, 300, 384),
    "argocd-server": (100, 128, 300, 256),
    "argocd-redis": (50, 64, 200, 128),
}

with open(source) as f:
    documents = list(yaml.safe_load_all(f))

patched = []

for doc in documents:
    if not isinstance(doc, dict):
        continue

    if doc.get("kind") not in ("Deployment", "StatefulSet"):
        continue

    name = doc.get("metadata", {}).get("name")
    if not name:
        continue

    spec = doc.setdefault("spec", {})
    template = spec.setdefault("template", {})
    pod_spec = template.setdefault("spec", {})

    if name in optional:
        spec["replicas"] = 0
        print(f"DISABLED: {name}")
        continue

    if name not in resources:
        print(f"WARNING: Unrecognized workload: {name}")
        continue

    pod_spec.setdefault("nodeSelector", {}).update({
        "kubernetes.io/arch": "arm64",
        "workload-tier": "application"
    })

    cpu_req, mem_req, cpu_lim, mem_lim = resources[name]

    for container in pod_spec.get("containers", []) + \
                     pod_spec.get("initContainers", []):
        container["resources"] = {
            "requests": {
                "cpu": f"{cpu_req}m",
                "memory": f"{mem_req}Mi"
            },
            "limits": {
                "cpu": f"{cpu_lim}m",
                "memory": f"{mem_lim}Mi"
            }
        }

    patched.append(name)
    print(f"ARM64 APPLICATION NODE: {name}")

with open(output, "w") as f:
    yaml.safe_dump_all(documents, f, sort_keys=False)

required = {
    "argocd-application-controller",
    "argocd-repo-server",
    "argocd-server",
    "argocd-redis"
}

if not required.issubset(set(patched)):
    raise SystemExit(
        f"ERROR: Missing required workloads. Found: {patched}"
    )

print(f"\nSUCCESS: Prepared {len(patched)} essential workloads.")
print(f"Output: {output}")
PY

echo "===== VALIDATING PATCHED MANIFEST ====="

kubectl apply \
  --dry-run=client \
  -f "$OUTPUT" >/dev/null

echo "Manifest validation successful."

echo "===== ESSENTIAL WORKLOADS ====="
grep -E '^kind: (Deployment|StatefulSet)' "$OUTPUT"

echo "===== NODE SELECTORS ====="
grep -n -A3 'nodeSelector:' "$OUTPUT"
