#!/bin/bash

set -e # make sure the job fails if any instruction fails

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

declare -a SECURITY_RINGS=("sensitive" "unhardened")

function deploy {
    print_section_title "\n[*] Deploy $1"
    pe "kubectl apply -f \"$1\""

    if [ ${kind} != "pod" ]; then
        sleep 1 # wait for all pods to show up
    fi

    print_section_title "\n[.] Pod's node selector"
    if [ ${kind} == "pod" ]; then
        pe "kubectl get -f \"$1\" -o json | jq -r '.items[] | \"\(.metadata.name) name -> \(.spec.nodeSelector)\"'"
    else
        pe "kubectl get pods -o json | jq -r '.items[] | \"\(.metadata.name) name -> \(.spec.nodeSelector)\"'"
    fi

    print_section_title '\nWaiting for the deployment...'
    if [ ${kind} == "pod" ]; then
        pe "kubectl wait -f \"$1\" --for=condition=Ready"
    else
        pe "kubectl rollout status -f \"$1\""
    fi

    print_section_title "\n[.] Node labels"
    pe "kubectl get nodes -o \"jsonpath={range .items[*]}{.metadata.name}{'\tsecurity-ring='}{.metadata.labels.security-ring}{'\n'}{end}\""

    print_section_title '\n[.] Pod schedules'
    pe "kubectl get pods -o wide"

    wait

    print_section_title '\n[.] Delete pod'
    pe "kubectl delete -f \"$1\""
}

function label_nodes {
    nodes=$1
    num=$2

    i=0
    for node in "${nodes[@]}"
    do
        kubectl label nodes ${node} security-ring=${SECURITY_RINGS[${i} % ${num}]} --overwrite
        i=$((i+1))
    done
}

function print_section_title {
    echo -n $'\e[32;1m'
    echo -e "$1"
    echo -n $'\e[0m'
}

source "${SCRIPT_DIR}/../demo-magic.sh" -n

# Speed at which to simulate typing
TYPE_SPEED=30

# minikube start --nodes=8

kind="${1:-pod}"

if [ ${kind} != "pod" ] && [ ${kind} != "deployment" ]
then
    echo 'Invalid argument value. Valid argument values are: pod (default), deployment'
    exit 1
fi

# Set node labels
control_plane_nodes=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | jq -r '.items[].metadata.name')
readarray -t control_plane_nodes <<< "${control_plane_nodes}"
label_nodes ${control_plane_nodes} 1
nodes=$(kubectl get nodes -l !node-role.kubernetes.io/control-plane -o json | jq -r '.items[].metadata.name')
readarray -t nodes <<< "${nodes}"
label_nodes ${nodes} 2

clear
wait # avoid seeing command prompt

print_section_title "[*] Let's see the nodes part of our Kubernetes cluster"
pe "kubectl get nodes -o \"jsonpath={range .items[*]}{.metadata.name}{'\tsecurity-ring='}{.metadata.labels.security-ring}{'\n'}{end}\""

if [[ $install ]]; then
    source "${SCRIPT_DIR}/../../gatekeeper-install.sh"
else
    print_section_title "\n[*] Let's see what is running in our Kubernetes cluster"
    pe 'kubectl get pods --namespace gatekeeper-system'

    print_section_title '\n[*] External services'
    print_section_title '\n[.] Gatekeeper Policy Manager'
    pe 'export URL=http://$(kubectl get ingress -n gatekeeper-system gatekeeper-policy-manager -o jsonpath="{.spec.rules[0].host}")'
    pe 'echo "Serving Gatekeeper Policy Manager at $URL"'
fi

wait # show nodes labels and web UI

print_section_title '\n[*] Allow Gatekeeper to reject workloads that create pods violating constraints'
pe "kubectl apply -f \"${SCRIPT_DIR}/policy/expansion-template.yaml\""

print_section_title '\n[*] Use Gatekeeper to mutate the node selector config'
pe "kubectl apply -f \"${SCRIPT_DIR}/policy/mutation.yaml\""

print_section_title '\n[*] Use Gatekeeper to validate the node selector config'
print_section_title '[.] Add constraint template'
pe "kubectl apply -f \"${SCRIPT_DIR}/policy/allowed-nodeselector-values-template.yaml\""
pe "kubectl apply -f \"${SCRIPT_DIR}/policy/template.yaml\""
print_section_title '[.] Add constraint'
pe "kubectl apply -f \"${SCRIPT_DIR}/policy/allowed-nodeselector-values-constraint.yaml\""
pe "kubectl apply -f \"${SCRIPT_DIR}/policy/constraint.yaml\""

wait # web UI

if [ ${kind} == "pod" ]; then
    deploy "${SCRIPT_DIR}/resources/pods.yaml"
else
    deploy "${SCRIPT_DIR}/resources/deployments.yaml"
fi

print_section_title '\n[*] Delete Gatekeeper resources'
pe "kubectl delete -f \"${SCRIPT_DIR}/policy/allowed-nodeselector-values-constraint.yaml\""
pe "kubectl delete -f \"${SCRIPT_DIR}/policy/constraint.yaml\""
pe "kubectl delete -f \"${SCRIPT_DIR}/policy/allowed-nodeselector-values-template.yaml\""
pe "kubectl delete -f \"${SCRIPT_DIR}/policy/template.yaml\""
pe "kubectl delete -f \"${SCRIPT_DIR}/policy/mutation.yaml\""
pe "kubectl delete -f \"${SCRIPT_DIR}/policy/expansion-template.yaml\""

if [[ $install ]]; then
    source "${SCRIPT_DIR}/../../gatekeeper-uninstall.sh"
fi

wait # avoid seeing command prompt

# Remove node labels
all_nodes=$(kubectl get nodes -o json | jq -r '.items[].metadata.name')
for node in "${all_nodes[@]}"
do
    kubectl label nodes ${node} security-ring-
done

# minikube delete
