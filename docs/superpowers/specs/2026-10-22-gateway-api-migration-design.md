# Migrate internal ingress from Traefik to Gateway API (kgateway + ListenerSet)

Date: 2026-10-22
Branch: off `main` (not `chore/smarthome-upgrade`)

## Intent

Replace classic `Ingress` + Traefik with Kubernetes Gateway API for all *internal* (LAN) traffic.
The shape Victor wants: **one shared set of gateway pods**, owned by the platform, with each app
self-serving its hostname + TLS through a `ListenerSet` and its routing through an `HTTPRoute`.
Apps never edit the shared `Gateway`.

## Decisions (made by Victor)

- **Controller: kgateway.** Traefik is dropped. The Gateway API v1.6 conformance reports show Traefik
  v3.7.10 lists `ListenerSet` as *unsupported*; kgateway v2.4.5 supports it in HTTP/GRPC/TCP/TLS profiles.
- **ListenerSet per app** on a single shared Gateway.
- **External exposure stays as-is.** The strrl `cloudflare-tunnel-ingress-controller` and its
  `Ingress` (`smarthome/ingress/Ingress-external.yaml`, `home-assistant.vicsufer.xyz`) are untouched.
  (Future option, not now: `lexfrei/cloudflare-tunnel-gateway-controller`, which supports ListenerSet.)
- **One-shot cutover.** Traefik removed and kgateway takes over in the same change; no parallel run.

## Goals

- All internal apps reachable at their current `https://<app>.vicsufer.xyz` hostnames via kgateway.
- Per-app Let's Encrypt certs (DNS-01 via the existing `letsencrypt-prod` ClusterIssuer), issued from ListenerSets.
- Pi-hole DNS records keep being managed automatically by external-dns.
- Homepage auto-discovery keeps working.

## Non-goals

- Migrating the Cloudflare tunnel / public exposure.
- MQTT over TCP (`smarthome/mqtt-certs`, `mosquitto.vicsufer.xyz`) — not routed by Traefik today, unchanged.
- Commented-out apps (firefly-iii, immich, wp-lapizarra): leave the comments; no conversion.
- Wildcard certificates, mTLS, rate limiting, auth policies.

## Anti-goals

- Apps having to edit the shared Gateway to get a hostname.
- external-dns `sync` policy deleting Pi-hole records for apps that are still served (see gotcha below).
- Breaking the strrl tunnel Ingress (its cert-manager ingress-shim cert must keep working).

## Target architecture

```
LAN client ──DNS (Pi-hole, by external-dns)──▶ 192.168.1.50 (MetalLB, private-pool)
   └─▶ kgateway Envoy pods (ns kgateway-system, one Deployment for Gateway "internal")
         ├─ Gateway "internal": listener http:80 (redirect to https), allowedListeners: All
         ├─ ListenerSet <app> (ns <app>): https:443, hostname <app>.vicsufer.xyz, TLS secret <app>-tls
         │     └─ HTTPRoute <app> (parentRef: ListenerSet) ─▶ Service <app>
         └─ ...
```

### Platform pieces (infrastructure/)

1. **Gateway API CRDs v1.6.x** — new Argo app (sync-wave lower than kgateway, e.g. `"1"`). ListenerSet is
   v1/standard in 1.6, but kgateway's conformance run used the **experimental** channel, so install the
   experimental bundle to be safe. Use `ServerSideApply=true` (CRDs are large).
2. **kgateway** — new Argo app replacing `Application-traefik.yaml`. Two OCI charts from
   `cr.kgateway.dev/kgateway-dev/charts`: `kgateway-crds` and `kgateway`, version **v2.4.7**
   (latest stable; v2.5 is beta). Values: scheduling tolerations/priorityClass equivalent to the
   current Traefik ones are a nice-to-have, not required.
3. **Shared Gateway** `internal` in `kgateway-system`, gatewayClass `kgateway`:
   - `allowedListeners.namespaces.from: All`
   - listener `http` on 80 with an `HTTPRoute` doing a 301 to https (attach to Gateway, sectionName http).
   - Envoy Service: `LoadBalancer`, MetalLB annotations/labels copied from current Traefik service
     (`metallb.io/loadBalancerIPs: 192.168.1.50`, label `metallb.universe.tf/address-pool: private-pool`,
     dual-stack PreferDualStack). Done through kgateway's `GatewayParameters` (or whatever kgateway v2.4
     uses for the generated Service) referenced from the Gateway.
4. **cert-manager** upgrade `v1.18.6` → `v1.21.x` and enable Gateway API + ListenerSet:
   `config.enableGatewayAPI: true` and feature gate `ListenerSet=true` (alpha in 1.20+). Keep ingress-shim (strrl Ingress still needs it).
5. **external-dns** — switch from the bitnami chart (8.9.2, image 0.18.0, too old: ListenerSet support landed in v0.21)
   to the upstream `kubernetes-sigs/external-dns` chart (~1.23, app v0.23.0), pihole provider v6 kept.
   - sources: `gateway-httproute` only (drop `ingress` and `traefik-proxy`).
   - **Remove `--annotation-filter`.** It only existed to exclude the strrl Ingress; with the `ingress`
     source gone it's not needed. Also, in v0.23.0 the filter is wrongly applied to ListenerSets
     ([external-dns#6788](https://github.com/kubernetes-sigs/external-dns/issues/6788)), which with
     `policy: sync` deletes records.
   - Keep `policy: sync`, pihole secret (SealedSecret) as-is, but re-expressed in the new chart's values.
6. **Pi-hole proxy** (`traefik-external/pihole-proxy.yaml` → new `kgateway-extras/` or similar):
   Gateway API backends can't use `ExternalName` reliably, so: selector-less `Service` `external-pihole`
   port 80 + `EndpointSlice` pointing to `192.168.1.20:80`, plus a ListenerSet + HTTPRoute for
   `pihole.vicsufer.xyz`. Keep it in the gateway's platform namespace.
7. **Delete**: `Application-traefik.yaml`, `values/traefik.values.yaml`, `traefik-external/`, Traefik dashboard
   route and its `traefik-cert`.

### Per-app pattern

For each app, set the chart's `ingress.enabled: false` (or remove the block) and add, in the app's
namespace, either via the chart's native Gateway API support if it has it **and** it can target a
ListenerSet, or as raw manifests (chart `extraObjects`/`extraDeploy`, or an `*-extras/` dir as a second
Argo source — follow whatever that app already does):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: ListenerSet
metadata:
  name: <app>
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  parentRef: { group: gateway.networking.k8s.io, kind: Gateway, name: internal, namespace: kgateway-system }
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: <app>.vicsufer.xyz
      tls: { mode: Terminate, certificateRefs: [{ name: <app>-tls }] }
      allowedRoutes: { namespaces: { from: Same } }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>
  annotations: { gethomepage.dev/...: (moved from the old Ingress) }
spec:
  parentRefs: [{ group: gateway.networking.k8s.io, kind: ListenerSet, name: <app>, sectionName: https }]
  hostnames: [<app>.vicsufer.xyz]
  rules: [{ backendRefs: [{ name: <service>, port: <port> }] }]
```

Traefik-specific annotations (`traefik.ingress.kubernetes.io/*`, `kubernetes.io/ingress.class`) are dropped.
`gethomepage.dev/*` annotations move to the HTTPRoute.

### Apps in scope

| Hostname | File | Notes |
|---|---|---|
| argocd | `kluster-manifests/argocd.values.yaml` | Installed by manual `helm upgrade` (see file header), not by Argo. Apply manually after merge. `server.insecure: true` → backend port 80. |
| homepage | `selfhosted/values/homepage.values.yaml` | Also turn on Gateway/HTTPRoute discovery in homepage's kubernetes config and drop ingress discovery. Remove the Traefik widget/service entry. |
| recetas (mealie) | `selfhosted/values/mealie.values.yaml` | |
| leantime | `selfhosted/values/leantime.values.yaml` | |
| wallos | `selfhosted/values/wallos.values.yaml` | |
| maybe | `selfhosted/values/maybe-finance.values.yaml` | |
| home-assistant | `smarthome/values/homeassistant.values.yaml` | strrl `Ingress-external.yaml` stays. Websockets must work. |
| mqtt (mosquitto) | `smarthome/values/mosquitto.values.yaml` | HTTP ingress only (websocket listener). |
| zigbee2mqtt | `smarthome/values/zigbee2mqtt.values.yaml` | Websockets. |
| overseerr | `mediaserver/values/overseerr.values.yaml` | |
| prowlarr | `mediaserver/values/prowlarr.values.yaml` | |
| prometheus, grafana, alertmanager | `monitoring/values/prometheus-stack.values.yaml` | 3 hostnames: either 3 ListenerSets or one ListenerSet with 3 listeners in `monitoring`; builder's call. |
| pihole | platform (see above) | |

Keep each app's existing TLS secret name where convenient so cert-manager reuses issued certs (avoids
hitting LE rate limits on a one-shot cutover of ~15 certs). Not mandatory.

## Cutover

Single PR, merged at once. Argo sync order via waves: CRDs → kgateway + Gateway + cert-manager/external-dns
upgrades → apps. Traefik deletion in the same PR (Argo `prune: true` removes it; the MetalLB IP
`192.168.1.50` frees and kgateway's Service picks it up — may need a manual re-sync if MetalLB raced).
ArgoCD's own route: manual `helm upgrade` right after merge (ArgoCD UI is unreachable via hostname
between Traefik going away and that upgrade; `kubectl port-forward` is the fallback).

## Verification

- `kubectl get gateway,listenerset,httproute -A` — all `Accepted`/`Programmed`, routes `ResolvedRefs`.
- `kubectl get certificate -A` — all Ready.
- Pi-hole has A records for every hostname pointing at `192.168.1.50`.
- `curl -I https://<host>` from the LAN for every hostname in the table returns the app (and http→https 301).
- Home Assistant + zigbee2mqtt UIs load and stay connected (websockets).
- `https://home-assistant.vicsufer.xyz` via Cloudflare still works (strrl untouched).
- Homepage shows the discovered services.

## Left to the builder

- Exact kgateway values / `GatewayParameters` shape for the LoadBalancer Service in v2.4.x.
- Whether ListenerSet works on the standard CRD channel with kgateway (default: experimental).
- Per-chart mechanism for extra manifests and whether any chart natively renders ListenerSet-attached HTTPRoutes.
- Whether the argo-cd chart's native `server.httproute` can attach to a ListenerSet, else raw manifests.
- Homepage config keys for Gateway API discovery in the deployed homepage version.
- Sync-wave numbers.

## Risks / gotchas

- cert-manager ListenerSet support is **alpha**. Fallback: explicit `Certificate` per app (secret name = the
  ListenerSet's `certificateRefs`), drop the annotation.
- external-dns v0.23.0 annotation-filter bug (#6788) — avoided by not using an annotation filter.
- One-shot cutover means LAN-wide downtime of all internal UIs until kgateway is programmed and certs issued.
