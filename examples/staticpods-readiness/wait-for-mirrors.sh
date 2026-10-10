#!/bin/bash

# Copyright The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# wait-for-mirrors.sh: init container of the static-pod-mirror-check DaemonSet.
# Waits until every static pod on this node has a mirror pod in the API server,
# then sets the Node condition that the NodeReadinessRule watches, and exits.
set -euo pipefail
MANIFEST_DIR="${MANIFEST_DIR:-/etc/kubernetes/manifests}"
CONDITION="${CONDITION:-readiness.example.com/StaticPodsMirrored}"
: "${NODE_NAME:?set NODE_NAME from spec.nodeName}"
log() { echo "$(date -u +%FT%TZ) [StaticPodMirrorCheck] $*"; }

while :; do
  missing=""
  for f in "$MANIFEST_DIR"/*; do
    [[ -f "$f" && "$(basename "$f")" != .* ]] || continue   # the kubelet skips dotfiles
    read -r name ns <<< "$(kubectl patch --local -f "$f" -p '{}' \
      -o jsonpath='{.metadata.name} {.metadata.namespace}' 2>/dev/null || true)"
    if [[ -z "${name:-}" ]]; then
      missing+=" $(basename "$f")(unparsed)"
      continue
    fi
    mirror="${ns:-default}/$name-$NODE_NAME"
    if ! out="$(kubectl get pod "$name-$NODE_NAME" -n "${ns:-default}" -o name 2>&1)"; then
      [[ "$out" == *NotFound* ]] || log "lookup of $mirror failed: $out"
      missing+=" $mirror"
    fi
  done
  [[ -z "$missing" ]] && break
  log "waiting for mirror pods:$missing"
  sleep 2
done

now="$(date -u +%FT%TZ)"
until kubectl apply --server-side --subresource=status --field-manager=static-pod-mirror-check -f - >/dev/null <<EOF
{"apiVersion":"v1","kind":"Node","metadata":{"name":"$NODE_NAME"},"status":{"conditions":[{"type":"$CONDITION","status":"True",
 "reason":"MirrorPodsRegistered","message":"All static pods have mirror pods in the API server","lastHeartbeatTime":"$now","lastTransitionTime":"$now"}]}}
EOF
do sleep 2; done
log "set $CONDITION=True on $NODE_NAME"
