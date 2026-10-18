# Talos

Machine configs for the `homelab` Talos cluster, built from layered patches. Only patches live in git.
The secrets bundle and every rendered config contain key material, so they're gitignored.

| Node (hostname)            | Role         | IP           | Address source          | Schematic                 |
|----------------------------|--------------|--------------|-------------------------|---------------------------|
| rpi-4b-0 (talos-hlb-vdh)  | controlplane | 192.168.1.40 | static (Talos config)   | `schematics/rpi_generic.yaml` |
| nuc-0 (talos-wvf-ric)     | worker       | 192.168.1.67 | Pi-hole DHCP reservation | see node file             |
| bmax-b1-0 (talos-iyf-r5c) | worker       | 192.168.1.47 | Pi-hole DHCP reservation | see node file             |

## Layout

```
patches/common/        every node
patches/controlplane/  control plane nodes
patches/worker/        worker nodes
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
talosctl -n 192.168.1.40 get machineconfig -o jsonpath='{.spec}' > /tmp/cp.yaml
talosctl gen secrets --from-controlplane-config /tmp/cp.yaml -o secrets.yaml && rm /tmp/cp.yaml
```

## Workflow

```sh
./render.sh                         # writes _out/
./apply.sh nuc-0 --dry-run          # shows the diff against the running config
./apply.sh nuc-0                    # applies (add --mode=reboot if the change needs it)
talosctl config merge _out/talosconfig   # admin talosconfig for this cluster
```

Bump `TALOS_VERSION` / `K8S_VERSION` in `render.sh` to match the cluster after upgrades
(`talosctl upgrade --image ...`, `talosctl upgrade-k8s --to ...`).

New node: add `nodes/<role>/<name>.yaml`, run `./render.sh`, then `./apply.sh <name> --insecure` while the node is in maintenance mode.

## Rebuild the control plane from an etcd backup

Backups are written weekly by `kluster-manifests/argocd-apps/infrastructure/talos-backups` (age-encrypted, in S3).

```sh
age -d -i agekey.age talos-homelab-<date>.snap.age > etcd.snap   # both gitignored
talosctl -n <node> reset --graceful=false --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
./render.sh && IP=<maintenance-ip> ./apply.sh rpi-4b-0 --insecure
talosctl -n 192.168.1.40 -e 192.168.1.40 bootstrap --recover-from=./etcd.snap
```

Node hostnames are pinned to the names stored in etcd (`talos-hlb-vdh`, `talos-wvf-ric`, `talos-iyf-r5c`) so a restore
reattaches to the existing Node objects and volumes.
