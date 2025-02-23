#!/usr/bin/env bash

CONTROL_PLANE_NODES="${CONTROL_PLANE_NODES:-3}"
NODES="${NODES:-0}"
FAKE_NODES="${FAKE_NODES:-100}"
WITHOUT_GATEKEEPER="${WITHOUT_GATEKEEPER:-false}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo "[*] Create KinD cluster"

control_plane=""
for ((i=0; i<$CONTROL_PLANE_NODES; i++)); do control_plane+="{'role': 'control-plane'},"; done
worker=""
for ((i=0; i<$NODES; i++)); do worker+="{'role': 'worker'},"; done
KIND_NODES_CONFIG="[$control_plane$worker]"

cat <<EOF | kind create cluster --config=- --wait=30s
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
- |-
  kind: ClusterConfiguration
  # configure controller-manager bind address
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
      secure-port: "10257"
  # configure etcd metrics listen address
  etcd:
    local:
      extraArgs:
        listen-metrics-urls: http://0.0.0.0:2381
  # configure scheduler bind address
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
      secure-port: "10259"
- |-
  kind: KubeProxyConfiguration
  # configure proxy metrics bind address
  metricsBindAddress: 0.0.0.0
nodes: $KIND_NODES_CONFIG
EOF

control_plane_nodes=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | jq -r '.items[].metadata.name')
readarray -t control_plane_nodes <<<"${control_plane_nodes}"

echo -e "\n[*] Enable scheduling pods on control plane nodes"
for node in "${control_plane_nodes[@]}"
do
  kubectl taint nodes ${node} node-role.kubernetes.io/control-plane=:NoSchedule-
done

# echo -e "\n[*] Install Ingress NGINX Controller"
# # NOTE: The Ingress controller ports will be exposed in your localhost address
# # through paths (i.e., /alertmanager, /prometheus, and /grafana)
# kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
# kubectl wait --namespace ingress-nginx \
#   --for=condition=ready pod \
#   --selector=app.kubernetes.io/component=controller \
#   --timeout=90s

echo -e "\n[*] Install metrics-server chart"
# kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
# kubectl patch -n kube-system deployment metrics-server --type=json \
#   -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
helm install metrics-server oci://registry-1.docker.io/bitnamicharts/metrics-server \
    --namespace kube-system --wait \
    --values $SCRIPT_DIR/values/metrics-server.yaml

echo -e "\n[*] Install kube-prometheus-stack chart"
helm upgrade --install kube-prometheus-stack --namespace monitoring --create-namespace --wait \
    --repo https://prometheus-community.github.io/helm-charts kube-prometheus-stack \
    --values $SCRIPT_DIR/values/kind-kube-prometheus-stack.yaml

if [ "$WITHOUT_GATEKEEPER" = false ]; then
  echo -e '\n[*] Install Gatekeeper chart'
  # kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.18.2/deploy/gatekeeper.yaml
  helm upgrade --install gatekeeper --namespace gatekeeper-system --create-namespace --wait \
      --repo https://open-policy-agent.github.io/gatekeeper/charts gatekeeper

  echo -e "\n[*] Install Gatekeeper pod monitors"
  kubectl apply -f $SCRIPT_DIR/gatekeeper-metrics-exporter
fi

echo -e "\n[*] Install Kubernetes WithOut Kubelet"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/latest/download/kwok.yaml"
# NOTE: To better simulate real behavior of Pod stages do not use the default
# Pod Fast Stage (i.e., pod-fast.yaml), but use the Pod General Stage (i.e.,
# pod-general.yaml)
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/latest/download/stage-fast.yaml"

# echo -e "\n[*] Setup default metrics usage policy"
# kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/latest/download/metrics-usage.yaml"

echo -e "\n[*] Disable scheduling pods on control plane nodes"
for node in "${control_plane_nodes[@]}"
do
  kubectl taint nodes ${node} node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
done

if [ "$FAKE_NODES" -gt 0 ]; then
  echo -e "\n[*] Create $FAKE_NODES fake nodes"
  ./node.sh $FAKE_NODES
fi
