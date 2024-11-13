# Homelab

This repository holds configuration as code for the homelab.

## Goals

- Replicate a enterprise ecosystem to learn and practice new technologies on a safe environment.
- Self-host applications.
- Tinkering.

## Overview

### Components

- Kubernetes Cluster:
  - k3s installation for simplicity.
  - 1 control node.
  - 3 worker nodes.

- NAS:
  - Host a small subset of services.
  - MediaServer.
  - Provides NFS Storage to workloads on the kubernetes cluster.

### Setup

- The configuration of the hosts is managed via ansible to provision the initial configuration. 
- Applications are deployed to k8s cluster with GitOps.
  - Web UIs will always be exposed through ingress with https with a valid certificate.
  - Secrets are encrypted using SealedSecrets.

### TODO

- Create baseline OS image. (Packer or other tool)
- Configure NAS with ansible.
- Move simple kubernetes/helm files to ArgoCD applications leveraging sealedsecrets
