# Closing the static-pod race with Node Readiness Controller

Oct 9, 2026 · @Ajay

If you have scaled a cluster up in a hurry and found a few pods sitting in `OutOfcpu`, you have met this problem. A new node goes Ready, the scheduler fills it with pods, and a minute later the kubelet rejects some of them because the node is full. The ReplicaSet creates replacements elsewhere, leaving a delay and a pile of Failed pods. It has a long-running upstream issue ([kubernetes/kubernetes#115325](https://github.com/kubernetes/kubernetes/issues/115325)), with reports from GKE, EKS and RKE2.

This post shows how to close the gap with Node Readiness Controller (NRC): a taint, a small DaemonSet and one `NodeReadinessRule`.

## What goes wrong

Static pods, such as `kube-proxy` on many node images, are started by the kubelet from manifest files on disk, so the kubelet counts their CPU and memory from the first second. The scheduler only knows what is in the API server, and a static pod shows up there as a *mirror pod*, a read-only copy named `<pod>-<node>`. On a fresh node that copy can be a minute or more late, because the kubelet cannot create it until the Node object exists and its informer has synced ([the upstream analysis](https://github.com/kubernetes/kubernetes/issues/115325)).

In that window the node is Ready and looks empty, so the scheduler packs it. When the mirror pods finally appear, the kubelet adds up what it is really running and rejects whatever does not fit.

_[Diagram: node bootstrap timeline — kubelet, API server and scheduler over time]_

Upstream is working on creating mirror pods as soon as the node registers ([#126870](https://github.com/kubernetes/kubernetes/pull/126870)), which shrinks the window but does not close it.

## Holding the node back

NRC keeps workloads off a node until a condition is true. Here the condition is that every static pod has a mirror pod in the API server. There are three pieces.

First, the node must be born with a taint. The kubelet's `--register-with-taints` puts it on at registration, before the scheduler can see the node. Set it with node pool taints on GKE (`--node-taints`), node group taints or Karpenter's `startupTaints` on EKS, or `nodeRegistration.taints` in kubeadm. Use `NoSchedule`, with a key under `readiness.k8s.io/` as NRC requires. We use `readiness.k8s.io/StaticPodsMirrored`.

Second, something on the node checks that the mirror pods exist and says so. A DaemonSet with an init container does it once, writes a condition onto the Node, and then sits idle.

Third, a `NodeReadinessRule` in `bootstrap-only` mode watches for that condition. When it turns True, NRC removes the taint and never looks at that node again. Mirror pods are only late once per Node object. A replacement node is a new object and is held again.

_[Diagram: gate architecture — node, API server, NRC, scheduler]_

The check pod tolerates the taint, so it runs while the node is held. The scheduler only gets involved at step 6.

## The check

The check is a short Python script. For each manifest in the static pod directory it reads the pod's name and namespace, asks the API server for `<name>-<node>`, and looks for the `kubernetes.io/config.mirror` annotation. When every mirror is there, it patches one condition onto the Node and exits.

```python
#!/usr/bin/env python3
"""Hold until every static pod on this node has a mirror pod in the API server,
then report a Node condition once and exit."""
import json
import os
import ssl
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import yaml

NODE = os.environ["NODE_NAME"]
MANIFESTS = Path(os.environ.get("MANIFESTS", "/etc/kubernetes/manifests"))
CONDITION = os.environ.get("CONDITION_TYPE", "readiness.example.com/StaticPodsMirrored")
POLL = float(os.environ.get("POLL_INTERVAL", "2"))

SA = Path(os.environ.get("SA_DIR", "/var/run/secrets/kubernetes.io/serviceaccount"))
API = os.environ.get("API_SERVER") or "https://{KUBERNETES_SERVICE_HOST}:{KUBERNETES_SERVICE_PORT}".format(**os.environ)
TLS = ssl.create_default_context(cafile=SA / "ca.crt")


def call(method, path, body=None, content_type="application/json"):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={
            "Authorization": "Bearer " + (SA / "token").read_text().strip(),
            "Content-Type": content_type,
        },
    )
    with urllib.request.urlopen(request, context=TLS, timeout=10) as response:
        return json.load(response)


def is_mirrored(namespace, pod):
    try:
        pod = call("GET", f"/api/v1/namespaces/{namespace}/pods/{pod}")
    except OSError as err:  # HTTPError is an OSError too
        if getattr(err, "code", None) != 404:
            print(f"lookup of {namespace}/{pod} failed: {err}", flush=True)
        return False
    return "kubernetes.io/config.mirror" in pod["metadata"].get("annotations", {})


def missing_mirrors():
    """Static pods on this node that have no mirror pod yet."""
    missing = []
    for path in sorted(MANIFESTS.iterdir()):
        if path.name.startswith(".") or not path.is_file():
            continue  # the kubelet ignores dotfiles, so do we
        try:
            # The kubelet reads only the first document; JSON manifests are valid YAML.
            pod = next(yaml.safe_load_all(path.read_text()))
            namespace = pod["metadata"].get("namespace", "default")
            name = f"{pod['metadata']['name']}-{NODE}"
        except (yaml.YAMLError, KeyError, TypeError, StopIteration):
            missing.append(f"{path.name} (unreadable manifest)")
            continue
        if not is_mirrored(namespace, name):
            missing.append(f"{namespace}/{name}")
    return missing


def report():
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    condition = {
        "type": CONDITION,
        "status": "True",
        "reason": "MirrorPodsRegistered",
        "message": "All static pods have mirror pods in the API server",
        "lastHeartbeatTime": now,
        "lastTransitionTime": now,
    }
    call("PATCH", f"/api/v1/nodes/{NODE}/status", {"status": {"conditions": [condition]}},
         content_type="application/strategic-merge-patch+json")


def main():
    while missing := missing_mirrors():
        print("waiting for mirror pods:", ", ".join(missing), flush=True)
        time.sleep(POLL)
    report()


if __name__ == "__main__":
    main()
```

The script retries in a loop rather than exiting non-zero, because a failing init container backs off for up to five minutes. It uses only PyYAML and the standard library and calls the API server with the pod's service account token, so the image needs no `kubectl` or `yq`.

```dockerfile
FROM python:3.13-alpine
RUN pip install --no-cache-dir PyYAML==6.0.3
COPY wait_for_mirrors.py install_static_pods.py /
```

The init container does the work. The main container is `pause`, so the pod makes no API calls after bootstrap.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: static-pod-mirror-check, namespace: kube-system}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: static-pod-mirror-check}
rules:
  - {apiGroups: [""], resources: [pods], verbs: [get]}
  - {apiGroups: [""], resources: [nodes, nodes/status], verbs: [get, patch]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: static-pod-mirror-check}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: static-pod-mirror-check}
subjects: [{kind: ServiceAccount, name: static-pod-mirror-check, namespace: kube-system}]
---
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: static-pod-mirror-check, namespace: kube-system}
spec:
  selector:
    matchLabels: {app: static-pod-mirror-check}
  template:
    metadata:
      labels: {app: static-pod-mirror-check}
    spec:
      serviceAccountName: static-pod-mirror-check
      priorityClassName: system-node-critical
      nodeSelector: {kubernetes.io/os: linux}   # same nodes as the rule
      tolerations:
        - operator: Exists                       # must run on held nodes
      initContainers:
        - name: wait-for-mirrors
          image: <your-registry>/static-pod-mirror-check:v1
          command: [python3, /wait_for_mirrors.py]
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          resources:
            requests: {cpu: 10m, memory: 32Mi}
            limits: {memory: 128Mi}
          volumeMounts:
            - {name: manifests, mountPath: /etc/kubernetes/manifests, readOnly: true}
      containers:
        - name: idle
          image: registry.k8s.io/pause:3.10
          resources:
            requests: {cpu: 1m, memory: 8Mi}
            limits: {memory: 8Mi}
      volumes:
        - name: manifests
          hostPath: {path: /etc/kubernetes/manifests, type: Directory}
```

Point `hostPath` at your kubelet's `staticPodPath`. `type: Directory` makes a wrong path fail the pod at the first rollout. The service account can patch any Node's status. The [NRC examples](https://github.com/kubernetes-sigs/node-readiness-controller/tree/main/examples/constrained-impersonation) show how to restrict it to its own node with constrained impersonation (Kubernetes 1.35+).

The rule:

```yaml
apiVersion: readiness.node.x-k8s.io/v1alpha1
kind: NodeReadinessRule
metadata:
  name: static-pods-mirrored
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  conditions:
    - type: readiness.example.com/StaticPodsMirrored
      requiredStatus: "True"
  taint:
    key: readiness.k8s.io/StaticPodsMirrored
    effect: NoSchedule
  enforcementMode: bootstrap-only
```

The rule sets no `defaultStatus`. A missing condition is Unknown, which does not match `"True"`, so the node stays held until the check has run.

If a mirror pod never appears, the check keeps waiting, logs which one, and the node stays tainted. A node with no static pods passes immediately. A reboot reruns the check, but NRC has already finished with that node. The condition is never refreshed, so use it only with `bootstrap-only` rules.

### When the DaemonSet installs the static pods too

If the DaemonSet also installs the static pods, as node agents often do, add an init container before the check that copies the manifests into the static pod directory. Init containers run in order, so the check waits for those pods too.

The installer:

```python
#!/usr/bin/env python3
"""Copy the bundled static pod manifests into the kubelet's static pod directory."""
import filecmp
import os
import shutil
from pathlib import Path

SRC = Path(os.environ.get("SRC", "/manifests"))
DEST = Path(os.environ.get("DEST", "/etc/kubernetes/manifests"))

for src in sorted(SRC.glob("*.yaml")):
    dest = DEST / src.name
    if dest.exists() and filecmp.cmp(src, dest, shallow=False):
        continue  # unchanged: leave the file (and the pod) alone
    tmp = DEST / f".{src.name}.tmp"  # the kubelet ignores dotfiles...
    shutil.copyfile(src, tmp)
    os.replace(tmp, dest)  # ...so it never sees a half-written manifest
```

It writes to a dotfile and renames it, since the kubelet skips dotfiles and never reads a half-copied manifest. It skips unchanged files, so restarting the DaemonSet leaves running pods alone. The manifests come from a ConfigMap and the installer gets a writable mount of the directory:

```yaml
      initContainers:
        - name: install-static-pods            # new, runs first
          image: <your-registry>/static-pod-mirror-check:v1
          command: [python3, /install_static_pods.py]
          volumeMounts:
            - {name: bundle, mountPath: /manifests, readOnly: true}
            - {name: manifests, mountPath: /etc/kubernetes/manifests}
        - name: wait-for-mirrors               # unchanged
          ...
      volumes:
        - name: bundle
          configMap: {name: static-pod-bundle}
        - name: manifests
          hostPath: {path: /etc/kubernetes/manifests, type: Directory}
```

The static pods outlive the DaemonSet, so removing them is a separate step. A manifest the kubelet refuses to run never gets a mirror pod, so the node stays held and the check's log names it.

## Rolling it out

Deploy the DaemonSet first. Existing nodes already have their mirror pods, so each gets the condition within seconds. Then install NRC and the rule. Last, add the taint to your node pools. On GKE:

```bash
gcloud container node-pools create pool-b \
  --cluster="$CLUSTER" --location="$LOCATION" \
  --node-taints=readiness.k8s.io/StaticPodsMirrored=pending:NoSchedule
```

Two caveats. Cluster Autoscaler builds a template node from the pool, taint included, and pending pods do not tolerate it, so it may not scale a pool up from zero. Karpenter's `startupTaints` avoid this. Cluster Autoscaler's `ignore-taint.cluster-autoscaler.kubernetes.io/` prefix would too, but NRC requires keys under `readiness.k8s.io/`, so test scale-from-zero. And do not re-apply the taint to nodes that already finished, for example by updating a pool's taints in place. A `bootstrap-only` rule will not revisit them, so they stay unschedulable until you remove the taint by hand.

## Trying it out

Size a ReplicaSet so its replicas exactly fill a node, pin it to the pool, and scale the pool from 3 to 20 nodes. Without the gate you should see `OutOfcpu` pods. With it, none:

```bash
kubectl get pods -A --field-selector status.phase=Failed -o json \
  | jq '[.items[] | select(.status.reason | startswith("OutOfcpu"))] | length'
```

Watching nodes with `kubectl get nodes -w -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'` shows the taint appear at registration and go a few seconds after the mirror pods exist. A held node's check pod sits in `Init:0/1`, and its log names the mirror pod it is waiting for:

```bash
kubectl logs -n kube-system -l app=static-pod-mirror-check -c wait-for-mirrors --prefix | tail
```

If you scrape NRC's metrics, alert on `node_readiness_rule_nodes{rule="static-pods-mirrored",state="held"} > 0` for ten minutes.

The same pattern works for any "not ready until X exists" check: a taint at registration, a small check that posts a condition, and a `bootstrap-only` rule.

## References

- [kubernetes/kubernetes#115325](https://github.com/kubernetes/kubernetes/issues/115325): the upstream race and its root-cause analysis
- [kubernetes/kubernetes#126870](https://github.com/kubernetes/kubernetes/pull/126870): creating mirror pods as soon as the node registers
- [kubernetes/website#47264](https://github.com/kubernetes/website/issues/47264): documenting `OutOfcpu` after node bootstrap
- [Node Readiness Controller](https://github.com/kubernetes-sigs/node-readiness-controller): `NodeReadinessRule`, `bootstrap-only` mode, constrained impersonation
