# Home network

Flat LAN `192.168.1.0/24` (no VLANs: the ISP router can't do them).
Pi-hole on the NAS is the DHCP and DNS server; the router's DHCP is off and its DNS points to Pi-hole.

## Address plan

Everything below `.100` is assigned by hand and never handed out by DHCP.

| Range         | Use                                   | Assigned by                                   |
|---------------|---------------------------------------|-----------------------------------------------|
| `.1`          | Router                                | ISP router                                    |
| `.2–.19`      | Network gear (APs, switches)          | static on the device                          |
| `.20–.29`     | Infrastructure                        | DHCP reservation in Pi-hole                   |
| `.30`         | Kubernetes API (Talos Layer2 VIP)     | `talos/nodes/controlplane/cp-1.yaml`          |
| `.31–.39`     | Kubernetes control plane nodes        | static in `talos/nodes/controlplane/`, baked into the image |
| `.40`         | Spare                                 |                                               |
| `.41–.49`     | Kubernetes worker nodes               | static in `talos/nodes/worker/`               |
| `.50–.54`     | MetalLB LoadBalancer pool             | `kluster-manifests/.../metallb-extras/IpAddressPool-private.yaml` |
| `.55–.99`     | Spare (grow the MetalLB pool here)    |                                               |
| `.100–.251`   | DHCP pool: phones, laptops, IoT, guests | Pi-hole DHCP (24h leases)                   |

## Hosts

| Address | Name        | Hardware                              | Notes                                  |
|---------|-------------|---------------------------------------|----------------------------------------|
| `.20`   | `synology`  | Synology DS720+                       | NAS: Pi-hole, NPM (80/443), DSM on 5000/82/446 |
| `.30`   | `k8s-api`   | VIP                                   | `https://192.168.1.30:6443`            |
| `.31`   | `cp-1`      | Raspberry Pi 4B                       | Talos control plane                    |
| `.41`   | `worker-1`  | Intel NUC                             | Sonoff Zigbee dongle (`zigbeeGateway: present`) |
| `.42`   | `worker-2`  | BMAX B1                               |                                        |
| `.50`   | `traefik`   | MetalLB                               | ingress; `*.vicsufer.xyz` records point here |

Kubernetes nodes carry a `homelab/hardware` label (`rpi-4b`, `nuc`, `bmax-b1`) instead of encoding hardware in the hostname.
