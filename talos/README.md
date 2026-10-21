# Talos

Machine configs for the `homelab` Talos cluster, built from layered patches. Only patches live in git.
The secrets bundle and every rendered config contain key material, so they're gitignored.

| Node     | Role         | IP             | Hardware        | Image schematic         |
|----------|--------------|----------------|-----------------|-------------------------|
| cp-1     | controlplane | 192.168.1.31   | Raspberry Pi 4B | `schematics/cp-1.yaml`  |
| worker-1 | worker       | 192.168.1.41   | Intel NUC (Zigbee dongle) | `schematics/worker-1.yaml` |
| worker-2 | worker       | 192.168.1.42   | BMAX B1         | `schematics/worker-2.yaml` |

Kubernetes API: `https://192.168.1.30:6443` (Layer2 VIP on the control plane). Address plan: [`../network.md`](../network.md).

## Layout

```
patches/common/        every node
patches/controlplane/  control plane nodes
patches/worker/        worker nodes (none yet)
nodes/<role>/<node>.yaml  per-node overlay (disk, installer image, network); `# ip:` header is used by apply.sh
schematics/            Image Factory schematics (curl -X POST --data-binary @file https://factory.talos.dev/schematics)
render.sh              secrets.yaml + patches -> _out/<node>.yaml and _out/talosconfig
apply.sh               talosctl apply-config for one node
```

Layering is `talosctl gen config` defaults → `patches/common` → `patches/<role>` → `nodes/<role>/<node>.yaml`.
Put a new setting in the narrowest layer that covers every node that needs it.

## Secrets

`secrets.yaml` (cluster CA, etcd CA, tokens…) must sit next to `render.sh` but is never committed.
Keep a copy in a password manager. If it's lost, recover it from a running control plane:

```sh
talosctl -n 192.168.1.31 get machineconfig -o jsonpath='{.spec}' > /tmp/cp.yaml
talosctl gen secrets --from-controlplane-config /tmp/cp.yaml -o secrets.yaml && rm /tmp/cp.yaml
```

## Workflow

```sh
./render.sh                         # writes _out/
./apply.sh worker-1 --dry-run       # shows the diff against the running config
./apply.sh worker-1                 # applies (add --mode=reboot if the change needs it)
talosctl config merge _out/talosconfig   # admin talosconfig for this cluster
```

Needs a `talosctl` matching `TALOS_VERSION` (v1.14 configs are multi-document; older clients can't render them).

## Upgrades

- Control plane first, then workers; one Talos minor at a time (latest patch of each), checking the node is Ready in between.
- Each node has its own schematic (`schematics/<node>.yaml`, id via the curl in the file) that bakes its address and
  hostname into the kernel args. Workers use Secure Boot: `factory.talos.dev/installer-secureboot/<id>:<version>`.
  A node coming from DHCP reappears on its static address after the reboot, so `talosctl upgrade` waiting on the old
  address never finishes; use `--wait=false` and watch the new one.
- Kubernetes: `talosctl upgrade-k8s --to <version>` (one minor at a time), then bump `K8S_VERSION` in `render.sh`.
  It resets the `coredns` ConfigMap; ArgoCD (`kluster-manifests/.../infrastructure/coredns`) puts the custom one back.
- After a version bump, set `TALOS_VERSION` / installer tags in git and `./apply.sh <node> --dry-run` to confirm no drift.

New node: add `nodes/<role>/<name>.yaml`, run `./render.sh`, then `./apply.sh <name> --insecure` while the node is in maintenance mode.

## Rebuild the control plane from an etcd backup

Backups are written weekly by `kluster-manifests/argocd-apps/infrastructure/talos-backups` (age-encrypted, in S3).

```sh
age -d -i agekey.age talos-homelab-<date>.snap.age > etcd.snap   # both gitignored
talosctl -n <node> reset --graceful=false --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
./render.sh && ./apply.sh cp-1 --insecure   # images bake in the node IP
talosctl -n 192.168.1.31 -e 192.168.1.31 bootstrap --recover-from=./etcd.snap
```

After a restore, delete Node objects that no longer exist (`kubectl get nodes`); storage is network-based
(synology-csi, NFS), so workloads reattach to whichever node they land on.
