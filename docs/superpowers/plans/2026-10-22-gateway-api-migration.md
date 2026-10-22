# Gateway API Migration (kgateway + ListenerSet) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Traefik + `Ingress` for internal traffic with one shared kgateway Gateway where every app self-serves its hostname/TLS via a `ListenerSet` and routes via an `HTTPRoute`.

**Architecture:** Argo CD apps (repo `vicsufer/homelab`, `kluster-manifests/argocd-apps/<group>/Application-*.yaml`). Platform: Gateway API CRDs app → kgateway app (chart + `kgateway-extras/` with Gateway, GatewayParameters, redirect, Pi-hole). cert-manager issues certs from ListenerSet annotations; external-dns (upstream chart) publishes HTTPRoute hostnames to Pi-hole. Apps disable chart ingress and ship a ListenerSet + HTTPRoute from an `*-extras/` directory source (or the chart's native support for argo-cd).

**Tech Stack:** Argo CD, Helm, kgateway v2.4.7, Gateway API v1.6.3 (experimental channel), cert-manager v1.21.2, external-dns chart 1.23.0 (app v0.23.0), MetalLB.

**Spec:** `docs/superpowers/specs/2026-10-22-gateway-api-migration-design.md`

## Global Constraints

- Work on a new branch `feat/gateway-api` off `main`. One PR, merged in one go (one-shot cutover).
- Shared Gateway: name `internal`, namespace `kgateway-system`, gatewayClassName `kgateway`, `allowedListeners.namespaces.from: All`.
- Gateway Service: `LoadBalancer`, annotation `metallb.io/loadBalancerIPs: 192.168.1.50`, label `metallb.universe.tf/address-pool: private-pool`.
- ListenerSet/HTTPRoute apiVersion: `gateway.networking.k8s.io/v1`. ListenerSet listener name `https`, port `443`, protocol `HTTPS`, `tls.mode: Terminate`, `allowedRoutes.namespaces.from: Same`.
- Every ListenerSet carries `cert-manager.io/cluster-issuer: letsencrypt-prod`. Reuse the existing TLS secret name listed per app (avoids LE re-issuance).
- Every HTTPRoute carries the app's `gethomepage.dev/*` annotations moved from the old Ingress, **plus an explicit `gethomepage.dev/href: https://<host>`**.
- Drop all `traefik.ingress.kubernetes.io/*` and `kubernetes.io/ingress.class` annotations.
- Never touch `smarthome/ingress/Ingress-external.yaml` (strrl tunnel) or `infrastructure/Application-cloudflared.yaml`.
- Never put manifests in a `*/values/` directory: those dirs are `path`+`ref` sources and get rendered into every app that references them.
- Each app's Ingress removal and its ListenerSet/HTTPRoute addition happen in the same task.

## Review Focus

1. **Orphaned Traefik:** No Application has a `resources-finalizer`, so pruning `Application-traefik.yaml` leaves the Traefik Deployment/Service holding `192.168.1.50`. Expect kgateway's Service to sit `<pending>` until Traefik is deleted by hand — Task 9 does this; the Gateway API CRDs (installed originally by Traefik) must **not** be deleted.
2. **Homepage discovery via ListenerSet parents:** homepage resolves route URLs through the parent Gateway and its RBAC has no `listenersets`; explicit `gethomepage.dev/href` must make every service show. Task 9 verifies the homepage service list.
3. **external-dns record loss:** `policy: sync` + any `--annotation-filter` on v0.23.0 deletes records for ListenerSet routes (external-dns#6788). Task 4 asserts the rendered args contain no `--annotation-filter` and RBAC includes `listenersets`.
4. **Websockets** (Home Assistant, zigbee2mqtt, mosquitto `mqtt-ws`): must stay connected through Envoy. Task 9 checks the UIs stay live.
5. **Sync ordering:** kgateway extras reference CRDs from the same app (`GatewayParameters`) and from the CRD app (`ListenerSet`); first sync must not fail with "no matches for kind". Tasks 1–2 set `SkipDryRunOnMissingResource=true` and sync waves.

## Inventory (from live cluster, 2026-10-22)

| Host | Namespace | Backend Service:port | TLS secret | Manifests go in |
|---|---|---|---|---|
| argocd.vicsufer.xyz | argocd | argocd-server:80 | argocd-server-tls | `kluster-manifests/argocd.values.yaml` (native chart) |
| homepage.vicsufer.xyz | homepage | homepage:3000 | homepage-general-tls | `selfhosted/homepage-extras/` |
| recetas.vicsufer.xyz | mealie | mealie:9000 | mealie-general-tls | `selfhosted/mealie-extras/` |
| leantime.vicsufer.xyz | leantime | leantime:80 | leantime-general-tls | `selfhosted/leantime-extras/` (new) |
| wallos.vicsufer.xyz | wallos | wallos:8282 | wallos-general-tls | `selfhosted/wallos-extras/` (new) |
| maybe.vicsufer.xyz | maybefinance | maybefinance:3000 | maybe-general-tls | `selfhosted/maybe-finance-extras/` |
| home-assistant.vicsufer.xyz | home-assistant | home-assistant:8080 | home-assistant-tls | `smarthome/ingress/` |
| mqtt.vicsufer.xyz | zigbee | mosquitto:9001 | mqtt-tls-secret | `smarthome/mosquitto-extras/` (new) |
| zigbee2mqtt.vicsufer.xyz | zigbee | zigbee2mqtt:8080 | zigbee2mqtt-tls-secret | `smarthome/zigbee2mqtt-extras/` (new) |
| overseerr.vicsufer.xyz | mediaserver | overseerr:5055 | overseerr-general-tls | `mediaserver/overseerr-extras/` (new) |
| prowlarr.vicsufer.xyz | mediaserver | prowlarr:9696 | prowlarr-general-tls | `mediaserver/prowlarr-extras/` (new) |
| prometheus.vicsufer.xyz | monitoring | prometheus-stack-kube-prom-prometheus:9090 | prometheus-general-tls | `monitoring/prometheus-stack-extras/` (new) |
| grafana.vicsufer.xyz | monitoring | prometheus-stack-grafana:80 | grafana-general-tls | same |
| alertmanager.vicsufer.xyz | monitoring | prometheus-stack-kube-prom-alertmanager:9093 | alertmanager-general-tls | same |
| pihole.vicsufer.xyz | kgateway-system | external-pihole:80 → 192.168.1.20 | pihole-cert | `infrastructure/kgateway-extras/` |

Notes: leantime and the 3 monitoring hosts have no live Ingress today (leantime pins chart `1.3.3`, which doesn't exist in the repo — latest is `1.3.0`; the monitoring values are mis-nested since commit `b3b3ec7`). Converting them is in scope; fixing leantime's chart version is not.

## Per-app file pattern (used by Tasks 5–7)

One file per app: `<dir>/Gateway-<app>.yaml` holding a ListenerSet and an HTTPRoute, both named `<app>`:

- ListenerSet: `spec.parentRef: {group: gateway.networking.k8s.io, kind: Gateway, name: internal, namespace: kgateway-system}`, one listener per Global Constraints with `hostname: <host>` and `certificateRefs: [{name: <TLS secret>}]`.
- HTTPRoute: `parentRefs: [{group: gateway.networking.k8s.io, kind: ListenerSet, name: <app>, sectionName: https}]`, `hostnames: [<host>]`, one rule with `backendRefs: [{name: <svc>, port: <port>}]`.

For a new `*-extras/` dir, add a source to the app's Application:

```yaml
    - repoURL: https://github.com/vicsufer/homelab
      targetRevision: HEAD
      path: kluster-manifests/argocd-apps/<group>/<app>-extras
```

Per-app test (run from repo root), expected to print `ListenerSet <app>` / `HTTPRoute <app>` and the host:

```bash
yq -r '.kind + " " + .metadata.name + " " + ((.spec.listeners[0].hostname // .spec.hostnames[0]))' <dir>/Gateway-<app>.yaml
```

And the chart must no longer render an Ingress (`helm template ... | yq 'select(.kind=="Ingress")'` → empty).

---

### Task 1: Gateway API CRDs app

**Files:**
- Create: `kluster-manifests/argocd-apps/infrastructure/Application-gateway-api-crds.yaml`

**Interfaces:**
- Produces: `ListenerSet`, `HTTPRoute`, `Gateway` CRDs at Gateway API v1.6.3 experimental, sync-wave `"1"`.

- [ ] **Step 1: Create the Application**

Pattern of the other infrastructure apps (project `homelab`, automated prune). Source: `repoURL: https://github.com/kubernetes-sigs/gateway-api`, `targetRevision: v1.6.3`, `path: config/crd/experimental`. Sync-wave `"1"`. syncOptions: `ServerSideApply=true`, `Replace=false`. **No `prune`** on this app's CRDs: set `syncPolicy.automated.prune: false` (CRD deletion would wipe every route).

- [ ] **Step 2: Verify the path renders the ListenerSet CRD**

Run: `kubectl kustomize "https://github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=v1.6.3" | yq -r 'select(.kind=="CustomResourceDefinition") | .metadata.name' | grep listenersets`
Expected: `listenersets.gateway.networking.k8s.io`

- [ ] **Step 3: Commit**

```bash
git add kluster-manifests/argocd-apps/infrastructure/Application-gateway-api-crds.yaml
git commit -m "Add Gateway API v1.6.3 experimental CRDs app"
```

### Task 2: kgateway app, shared Gateway, Pi-hole; remove Traefik

**Files:**
- Create: `kluster-manifests/argocd-apps/infrastructure/Application-kgateway.yaml`
- Create: `kluster-manifests/argocd-apps/infrastructure/kgateway-extras/Gateway-internal.yaml`
- Create: `kluster-manifests/argocd-apps/infrastructure/kgateway-extras/Pihole.yaml`
- Delete: `infrastructure/Application-traefik.yaml`, `infrastructure/values/traefik.values.yaml`, `infrastructure/traefik-external/` (whole dir)

**Interfaces:**
- Consumes: CRDs from Task 1.
- Produces: Gateway `kgateway-system/internal` with listener `http`:80; GatewayClass `kgateway` (created by the controller).

- [ ] **Step 1: Application-kgateway.yaml**

Destination namespace `kgateway-system`, sync-wave `"2"`, `CreateNamespace=true`, `SkipDryRunOnMissingResource=true`, `ServerSideApply=true`. Three sources: OCI chart `kgateway-crds` and `kgateway` from `cr.kgateway.dev/kgateway-dev/charts`, both `targetRevision: v2.4.7` (releaseNames `kgateway-crds`, `kgateway`), plus `path: kluster-manifests/argocd-apps/infrastructure/kgateway-extras`. No values needed. Copy the Traefik tolerations/priorityClass only if trivial (nice-to-have).

- [ ] **Step 2: Gateway-internal.yaml**

Three objects in `kgateway-system`:
- `GatewayParameters` (`gateway.kgateway.dev/v1alpha1`) `internal`: `spec.kube.service.type: LoadBalancer`, `extraAnnotations` / `extraLabels` = the MetalLB values from Global Constraints. (No dual-stack field exists in v2.4.7 — dropped.)
- `Gateway` `internal` per Global Constraints, `spec.infrastructure.parametersRef: {group: gateway.kgateway.dev, kind: GatewayParameters, name: internal}`, one listener `name: http, protocol: HTTP, port: 80, allowedRoutes.namespaces.from: Same`.
- `HTTPRoute` `https-redirect`: parentRef Gateway `internal` sectionName `http`, one rule with `RequestRedirect` filter `scheme: https, statusCode: 301`. No `hostnames` (so external-dns ignores it).

- [ ] **Step 3: Pihole.yaml**

In `kgateway-system`: Service `external-pihole` (no selector, port `name: http, port: 80`); `EndpointSlice` (`discovery.k8s.io/v1`) `external-pihole-1`, label `kubernetes.io/service-name: external-pihole`, `addressType: IPv4`, endpoint `192.168.1.20`, port `name: http, port: 80`; ListenerSet + HTTPRoute `pihole` per the per-app pattern (host `pihole.vicsufer.xyz`, secret `pihole-cert`, backend `external-pihole:80`; homepage annotations not needed).

- [ ] **Step 4: Delete Traefik files**

`git rm -r` the three paths listed above.

- [ ] **Step 5: Verify**

Run: `helm template kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway --version v2.4.7 -n kgateway-system >/dev/null && yq -r '.kind + "/" + .metadata.name' kluster-manifests/argocd-apps/infrastructure/kgateway-extras/*.yaml && grep -rn traefik kluster-manifests/argocd-apps/infrastructure`
Expected: chart renders; lists `GatewayParameters/internal Gateway/internal HTTPRoute/https-redirect Service/external-pihole EndpointSlice/external-pihole-1 ListenerSet/pihole HTTPRoute/pihole`; grep prints only `external-dns.values.yaml` hits (fixed in Task 4).

- [ ] **Step 6: Commit** — `git commit -m "Replace Traefik with kgateway shared Gateway"`

### Task 3: cert-manager v1.21.2 with ListenerSets

**Files:**
- Modify: `infrastructure/Application-certmanager.yaml` (`targetRevision: v1.18.6` → `v1.21.2`)
- Modify: `infrastructure/values/certmanager.values.yaml`

- [ ] **Step 1: Read release notes** for 1.19, 1.20, 1.21 (`https://cert-manager.io/docs/releases/`) and note any value/flag breaking changes affecting `crds.enabled/keep` or `extraObjects`. Adjust values if needed.

- [ ] **Step 2: Values** — add `config: {apiVersion: controller.config.cert-manager.io/v1alpha1, kind: ControllerConfiguration, enableGatewayAPI: true}` and `featureGates: "ListenerSets=true"` (gate name is `ListenerSets`, plural).

- [ ] **Step 3: Verify**

Run: `helm template cert-manager cert-manager --repo https://charts.jetstack.io --version v1.21.2 -n cert-manager -f kluster-manifests/argocd-apps/infrastructure/values/certmanager.values.yaml | yq 'select(.kind=="Deployment" and .metadata.name=="cert-manager") | .spec.template.spec.containers[0].args' ; helm template ... | yq 'select(.kind=="ClusterRole") | .rules[] | select(.apiGroups[0]=="gateway.networking.k8s.io") | .resources'`
Expected: args include `--feature-gates=ListenerSets=true` and the config mount; RBAC resources include `listenersets`. If `listenersets` is missing from RBAC, add a ClusterRole + binding to `extraObjects`.

- [ ] **Step 4: Commit** — `git commit -m "Upgrade cert-manager to v1.21.2 and enable ListenerSets"`

### Task 4: external-dns on upstream chart, gateway-httproute source

**Files:**
- Modify: `infrastructure/Application-external-dns.yaml` (chart `external-dns`, `repoURL: https://kubernetes-sigs.github.io/external-dns/`, `targetRevision: 1.23.0`; add source `path: kluster-manifests/argocd-apps/infrastructure/external-dns-extras`)
- Rewrite: `infrastructure/values/external-dns.values.yaml`
- Create: `infrastructure/external-dns-extras/SealedSecret-pihole.yaml` (move the SealedSecret from current `extraDeploy` verbatim — same name/namespace, it's scope-bound)

- [ ] **Step 1: Values** — `provider.name: pihole`; `sources: [gateway-httproute]`; `policy: sync`; `extraArgs: [--pihole-api-version=6, --pihole-tls-skip-verify]`; `env` with `EXTERNAL_DNS_PIHOLE_PASSWORD` and `EXTERNAL_DNS_PIHOLE_SERVER` from `secretKeyRef` `pihole-secret`; `rbac.additionalPermissions: [{apiGroups: [gateway.networking.k8s.io], resources: [listenersets], verbs: [get, list, watch]}]`. Keep registry `txt` and no txtOwnerId. Note: Pi-hole keeps no TXT ownership records, so external-dns effectively only creates records there (never updates/deletes). Also set `enableGatewayListenerSets: true` (adds `--gateway-listener-sets` and RBAC) instead of `rbac.additionalPermissions`. **No annotationFilter.**

- [ ] **Step 2: Verify**

Run: `helm template external-dns external-dns --repo https://kubernetes-sigs.github.io/external-dns/ --version 1.23.0 -n external-dns -f kluster-manifests/argocd-apps/infrastructure/values/external-dns.values.yaml | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].args'`
Expected: contains `--source=gateway-httproute`, `--policy=sync`, `--provider=pihole`, `--registry=txt`, `--pihole-api-version=6`; does **not** contain `--annotation-filter` or `--source=ingress`. ClusterRole includes `listenersets`.

- [ ] **Step 3: Commit** — `git commit -m "Move external-dns to upstream chart with Gateway API source"`

### Task 5: selfhosted apps (homepage, mealie, leantime, wallos, maybe-finance)

**Files:** per Inventory; Modify each `selfhosted/values/<app>.values.yaml` (ingress disabled / block removed), `Application-leantime.yaml` and `Application-wallos.yaml` (new extras source); Create `Gateway-<app>.yaml` per app.

- [ ] **Step 1: Homepage config** — in `homepage.values.yaml` set `config.kubernetes: {mode: cluster, gateway: true}`; move the homepage Ingress annotations to its HTTPRoute.
- [ ] **Step 2: Create the five `Gateway-<app>.yaml` files** per the per-app pattern and Inventory; disable each chart's ingress (`ingress.enabled: false` or `ingress.main.enabled: false` for wallos/truecharts — check the key the values file already uses).
- [ ] **Step 3: Verify** — per-app test for each; `helm template` of homepage 2.1.0, wallos 6.16.1 (`oci://oci.trueforge.org/truecharts/wallos`), maybe-finance 0.2.7, mealie (git chart `ben-kemister/mealie-helm-chart`, path `mealie`) with the new values renders no Ingress. leantime: render with `--version 1.3.0` (1.3.3 doesn't exist).
- [ ] **Step 4: Commit** — `git commit -m "Route selfhosted apps through kgateway ListenerSets"`

### Task 6: smarthome + mediaserver apps

**Files:** per Inventory; Modify `smarthome/values/{homeassistant,mosquitto,zigbee2mqtt}.values.yaml`, `mediaserver/values/{overseerr,prowlarr}.values.yaml`, Applications for mosquitto, zigbee2mqtt, overseerr, prowlarr (new extras source). Home Assistant reuses its existing `smarthome/ingress` source.

- [ ] **Step 1: Create the five `Gateway-<app>.yaml` files** and disable chart ingress. Home Assistant's file goes next to `Ingress-external.yaml`, which stays untouched.
- [ ] **Step 2: Verify** — per-app tests; `helm template` for home-assistant 0.3.87, mosquitto 0.1.1, zigbee2mqtt 2.14.2, overseerr 1.1.1, prowlarr 1.42.0 renders no Ingress; `yq '.kind' smarthome/ingress/Ingress-external.yaml` → `Ingress` and `git diff main -- kluster-manifests/argocd-apps/smarthome/ingress/Ingress-external.yaml` empty.
- [ ] **Step 3: Commit** — `git commit -m "Route smarthome and mediaserver apps through kgateway"`

### Task 7: monitoring (prometheus, grafana, alertmanager)

**Files:**
- Modify: `monitoring/values/prometheus-stack.values.yaml` — delete the whole mis-nested `prometheus:` block; keep `prometheusOperator`.
- Modify: `monitoring/Application-prometheus-stack.yaml` — add extras source.
- Create: `monitoring/prometheus-stack-extras/Gateway-monitoring.yaml` — one ListenerSet `monitoring` with three listeners (`prometheus`, `grafana`, `alertmanager`, each 443/HTTPS with its host + secret) and three HTTPRoutes, each `sectionName` = its listener name. Homepage annotations from the old values (keep the widget ones).

- [ ] **Step 1: Write files.**
- [ ] **Step 2: Verify** — `yq -r '.kind + " " + .metadata.name' monitoring/prometheus-stack-extras/Gateway-monitoring.yaml` → 1 ListenerSet, 3 HTTPRoutes; `helm template prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 69.8.2 -n monitoring -f <values> | yq -r 'select(.kind=="Service") | .metadata.name' | grep -E 'grafana$|prom-prometheus$|prom-alertmanager$'` → the three backend names in the Inventory.
- [ ] **Step 3: Commit** — `git commit -m "Expose monitoring UIs through kgateway"`

### Task 8: ArgoCD server route (native chart support)

**Files:** Modify `kluster-manifests/argocd.values.yaml`

- [ ] **Step 1:** `server.ingress.enabled: false`; `server.listenerset: {enabled: true, parentRef: {name: internal, namespace: kgateway-system}, annotations: {cert-manager.io/cluster-issuer: letsencrypt-prod}}` (secret defaults to `argocd-server-tls` = existing); `server.httproute: {enabled: true, annotations: <the gethomepage.dev annotations from the old ingress + href>}`.
- [ ] **Step 2: Verify** — `helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.5 -n argocd -f kluster-manifests/argocd.values.yaml | yq -r 'select(.kind=="ListenerSet" or .kind=="HTTPRoute" or .kind=="Ingress") | .kind'` → `HTTPRoute`, `ListenerSet`, no `Ingress`.
- [ ] **Step 3: Commit** — `git commit -m "Route ArgoCD through kgateway ListenerSet"`

### Task 9: Cutover and live verification (with Victor)

- [ ] **Step 1:** Open PR; Victor merges.
- [ ] **Step 2:** Watch Argo: `gateway-api-crds` then `kgateway` Healthy. `kubectl get crd listenersets.gateway.networking.k8s.io` exists.
- [ ] **Step 3: Remove orphaned Traefik** (confirm with Victor first): `kubectl delete ns traefik` and Traefik's own CRDs only: `kubectl get crd -o name | grep -E 'traefik\.(io|containo\.us)' | xargs kubectl delete`. Also delete `clusterrole/traefik-traefik`, `clusterrolebinding/traefik-traefik` and `ingressclass/traefik` (check names with `kubectl get clusterrole,clusterrolebinding,ingressclass | grep traefik` first). Do **not** delete `*.gateway.networking.k8s.io` CRDs.
  - Note: if a CRD sync fails with "Installing experimental CRDs on top of standard channel CRDs is prohibited", delete the safe-upgrades ValidatingAdmissionPolicy + its binding and resync.
  - Stuck app recovery (Argo UI down): `kubectl -n argocd patch app <x> --type merge -p '{"operation":{"sync":{}}}'`.
- [ ] **Step 4:** `kubectl -n kgateway-system get svc` → EXTERNAL-IP `192.168.1.50`, ports 80 and 443.
- [ ] **Step 5:** Victor runs `helm upgrade argocd argo/argo-cd --version 10.10.5 -f kluster-manifests/argocd.values.yaml --install --namespace argocd`.
- [ ] **Step 6:** `kubectl get gateway,listenerset,httproute -A` → all Accepted/Programmed; `kubectl get certificate -A` → all Ready; `kubectl get listenerpolicy -A` shows `internal`; check each Certificate's ownerReference is now the ListenerSet.
- [ ] **Step 7:** For every host in the Inventory: `curl -sI https://<host> | head -1` → 2xx/3xx from the app; `curl -sI http://<host> | head -1` → `301`; `dig +short <host> @192.168.1.20` → `192.168.1.50`. Websocket check: `curl -i -N -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' https://home-assistant.vicsufer.xyz/api/websocket` → `101`. Leantime is expected to fail (chart 1.3.3 missing, out of scope).
- [ ] **Step 7b:** Remove the stale `traefik.vicsufer.xyz` record from Pi-hole by hand (the Pi-hole provider can't store TXT ownership, so external-dns never deletes/updates records).
- [ ] **Step 8:** Victor checks Home Assistant, zigbee2mqtt UIs stay connected; Home Assistant via Cloudflare still works; homepage lists every service.
