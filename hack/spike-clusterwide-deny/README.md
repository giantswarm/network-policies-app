# Spike kit: clusterwide deny with namespace opt-out

Kit for [giantswarm/roadmap#4339](https://github.com/giantswarm/roadmap/issues/4339), slice 1 of the
[default-deny-netpol PRD](https://github.com/giantswarm/cabbage-plans/blob/main/default-deny-netpol/PRD.md). It hand-applies the **clusterwide deny**, the clusterwide DNS allow and one
Kyverno `GeneratingPolicy` per **standard allow** on a test workload cluster, then runs a probe per acceptance
criterion and prints PASS / FAIL / FINDING / INCONCLUSIVE / ERROR / MANUAL / NOT-RUN with the observed evidence. Terms follow
`context/glossary.md`.

**Everything the kit creates is named `ddn-spike-*` and labeled `spike.giantswarm.io/owner=default-deny-netpol`**, so it
can never collide with, or delete, the real chart objects (`default-deny-all-namespaces`, `allow-dns-all-namespaces`,
the real GeneratingPolicies, ...). The preflight refuses to run if a kit name already exists without that label, and
every delete is either label-selected (`cleanup`) or name plus owner-label checked. The kit's GeneratingPolicies only act
on namespaces carrying the owner label, so a real namespace that happens to carry a `policy.giantswarm.io/allow-*`
annotation is not touched.

## What is in here

| Path | What |
|---|---|
| `manifests/ccnp-default-deny-all-namespaces.yaml` | **Clusterwide deny** (`ddn-spike-default-deny-all-namespaces`): all endpoints except namespaces labeled `policy.giantswarm.io/default-deny: "false"` (**namespace opt-out**); `NotIn` also selects unlabeled namespaces |
| `manifests/ccnp-allow-dns-all-namespaces.yaml` | clusterwide DNS allow (`ddn-spike-allow-dns-all-namespaces`), same selector, DNS targets copied from network-policies-app `allow-dns.yaml` |
| `manifests/generatingpolicies/*.yaml` | six `GeneratingPolicy` `ddn-spike-allow-*` (`policies.kyverno.io/v1beta1`), one per **generation annotation**; the file name `generatingpolicy-<annotation>.yaml` is the single source the script derives its annotation list from; each generates a CNP of the same `ddn-spike-allow-*` name |
| `manifests/kyverno-rbac-ciliumnetworkpolicies.yaml` | ClusterRole `ddn-spike-background-controller-ciliumnetworkpolicies` aggregated into Kyverno's background controller |
| `manifests/probes/` | probe namespaces/pods (netshoot) and the webhook listener; the DNS probe pods in `kube-system` / `giantswarm` are created inline by the `dns` check |
| `manifests/webhook-variants/` | candidate webhook-ingress sources, narrowest first |
| `run-checklist.sh` | setup, one function per acceptance criterion, cleanup |
| `SOURCES.md` | file:line evidence for every non-obvious field |

Versions found: **Giant Swarm deploys Kyverno v1.18.2** (security-bundle pins `kyverno` app 0.25.0 and `kyverno-crds`
1.18.0; kyverno-app 0.25.0 "Updated kyverno to upstream version v1.18.2"). `GeneratingPolicy` exists in that release
as **`apiVersion: policies.kyverno.io/v1beta1`** (storage version; `v1` and `v1alpha1` are also served). Details in
`SOURCES.md`.

## Design notes that differ from a naive reading of the PRD

- **The annotation check lives in a policy variable, not in `matchConditions`.** Kyverno does put a GeneratingPolicy's
  match conditions on the webhook it registers, and the Kubernetes API server evaluates `matchConditions` with both
  `object` and `oldObject` available, so a condition such as "new or old object carries an allow annotation" would let
  annotation removal through. The kit does not rely on that: the test is a policy variable evaluated by Kyverno, so the
  UPDATE that *removes* the annotation always reaches it, synchronization first deletes the trigger's downstreams, and
  nothing is regenerated. `ac5` proves this live. Using a `matchCondition` to cut the webhook volume is an optimisation
  worth its own spike (see `SOURCES.md`, which also marks which parts are traced and which are inference).
- **The kit sets NO selector on the Namespace webhook, on purpose.** The six GeneratingPolicies register a cluster-wide
  webhook on Namespaces. GeneratingPolicies without `matchConditions`/`matchPolicy`/timeout all go into ONE shared
  webhook (`gpol.validate.kyverno.svc-ignore`) whose `namespaceSelector`/`objectSelector` are overwritten per policy in
  informer order, so the last policy listed wins (`pkg/controllers/webhook/validating.go:196-211`, policies listed at
  `controller.go:1433-1443`; non-deterministic). A kit `objectSelector` on the owner label could therefore silently stop
  *foreign* GeneratingPolicies from receiving admission requests. With nil kit selectors foreign policies can only see
  more events, never fewer, so the kit relies only on the CEL gate (owner label AND annotation) in each policy's
  variables. The preflight lists GeneratingPolicies that do not carry the owner label and warns that they share this
  webhook (it does not refuse). GeneratingPolicy `failurePolicy` is hard-coded `Ignore` in the API module Kyverno
  uses, so a Kyverno outage never blocks Namespace writes through this webhook, but under the deny a webhook the API
  server cannot reach just times out and **nothing is generated**: the preflight therefore checks that something allows
  ingress on the admission port (service targetPort, 9443 by default) from `kube-apiserver` / `remote-node` / `host`
  (CNP `fromEntities` values kube-apiserver / remote-node / host / cluster / all, or `fromCIDR`/`fromCIDRSet`, or for a NetworkPolicy an `ipBlock` or an open `from`; a CIDR is accepted with a note that it must cover the API server). The port is the admission service's `https` targetPort (named ports are resolved through the admission-controller container port, default 9443; the metrics service is never used) and the policy must select the admission controller (component `admission-controller`, Kyverno name/instance labels, or an empty selector) to the Kyverno admission controller
  (kyverno-app ships `allow-kyverno-admission-controller-talk-to-apiserver`) and refuses otherwise
  (`SPIKE_ALLOW_NO_KYVERNO_INGRESS=true`). A rule has to cover both the port and such a source; a policy that only
  allows the same namespace does not count. The real chart policies run the same cluster-wide webhook for every
  Namespace write, which `flap` and `restart` help to size.
- **Generate-existing is policy-driven**: Kyverno lists existing triggers when the policy is created or updated.
  Whether namespaces annotated while Kyverno was down are caught after a restart is what `ac5b` with
  `SPIKE_ALLOW_KYVERNO_SCALE=true` answers.
- **Every Namespace UPDATE evaluates six policies, and Synchronize deletes then regenerates every downstream of the
  trigger on each of them** (`kyverno pkg/background/gpol/generate_controller.go:87-93`, `dynamic_watcher.go:213-246`).
  If that also happens for *unrelated* Namespace updates (a label change by any controller), the allows blink out and
  back. The `flap` check measures the gap and the probe failures it causes; the `restart` check measures whether a
  background-controller restart can strand a generated CNP after the annotation is removed. Both are design probes for
  the PRD, not checks of this kit: their result is a finding.
- **CoreDNS ingress is not provided by the kit.** The deny selects `kube-system`, CoreDNS included, with an empty
  ingress rule, and no DNS allow in the kit is an ingress allow for CoreDNS (the `allow-dns` policies are egress). In
  the Giant Swarm stack the ingress comes from `coredns-app`, which ships a Kubernetes `NetworkPolicy`
  `kube-system/coredns` allowing ingress on the DNS ports (and the metrics port) from anywhere
  (`helm/coredns-app/templates/np.yaml`, see `SOURCES.md`); Cilium unions that allow with the CCNP deny. The preflight
  looks for such a policy (NetworkPolicy and CNP in `kube-system`, all non-kit CCNPs) and **refuses to continue if it
  finds none** (override `SPIKE_ALLOW_NO_COREDNS_INGRESS=true`), because DNS would break cluster-wide. A
  policy with an empty selector only counts when it also allows port 53/1053; otherwise it is listed as "unconfirmed"
  and the preflight still refuses. If node-local DNS cache pods exist it asks you to confirm an ingress allow for them;
  the `dns` check shows it empirically.
- **Kyverno itself runs under the deny.** kyverno-app ships its own CiliumNetworkPolicies
  (`ciliumNetworkPolicy.enabled: true`); if generation stops working after setup, check
  `kubectl -n kyverno logs` and `kubectl get ciliumnetworkpolicy -n kyverno` first. That is also an input for giantswarm/roadmap#4375.
- Provisional values: metrics-scraping source is `alloy-metrics` in `kube-system`; webhook ports are
  `443,4443,8443,9443,10250`; webhook source entities are `kube-apiserver` + `remote-node` until `ac6` says otherwise.

## Prerequisites

- A **dedicated test workload cluster per provider** (CAPA/AWS, CAPZ/Azure, vSphere/CAPV as available, **and AKS**).
  The clusterwide deny denies **all** traffic of **all** namespaces including `kube-system` and `giantswarm`; do not
  run this against a shared or production cluster. `kube-system` and `giantswarm` keep DNS only through the existing
  per-namespace `default-allow-dns` (network-policies-app `allowEgressToDNS`); the script reports whether it exists.
- Cilium with CCNP support (cilium-app, or Azure-managed Cilium on AKS) and the `CiliumClusterwideNetworkPolicy` CRD.
- **security-bundle with Kyverno running** (kyverno-app and `kyverno-crds`), so the `GeneratingPolicy` CRD exists.
  Without it the generate checks degrade to MANUAL.
- `kubectl` with cluster-admin rights, `bash`. `timeout` or `gtimeout` is used when present to bound every `kubectl exec`
  that watches something; without it the script falls back to killing the process group. The probe image `nicolaka/netshoot:v0.13` and `registry.k8s.io/pause:3.9`
  must be pullable; mirror them and set `SPIKE_IMAGE` / `SPIKE_PAUSE_IMAGE` otherwise.
- Exec into the Cilium agent pods (`kube-system`, label `k8s-app=cilium`) for `ac2`, `ac3`, `ac4`, `ac8`. On AKS
  exec may be blocked; those checks then report MANUAL with the commands.
- For AKS drop signals, `az` access to the cluster to check ACNS (see `ac3`).

## How to run

```bash
cd hack/spike-clusterwide-deny

# list the functions
./run-checklist.sh list

# everything, with the safety gate (SPIKE_CONFIRM must equal the kubectl context that will actually be used: the
# preflight resolves it with --kubeconfig/--context honoured, prints it, and refuses when it cannot be determined)
SPIKE_CONFIRM=<test-wc-context> ./run-checklist.sh --kubeconfig ~/wc.kubeconfig --context <test-wc-context> --provider aws run

# a subset
SPIKE_CONFIRM=<ctx> ./run-checklist.sh --context <ctx> --provider aks --only ac1,ac6 run

# opt in to the "Kyverno down" generate-existing test: scales ALL kyverno deployments to 0 and back. Typically 1-3
# minutes; worst case about 10 minutes (up to 180 s for the pods to go away, 5 s fixed wait, up to 300 s per deployment
# for the rollout to complete again and up to 180 s for the CNP). Refused when a Kyverno-managed webhook is not
# failurePolicy Ignore AND matches Namespaces, Deployments (scale) or everything: it would block the annotation or the
# restore itself while Kyverno is down. Kyverno's own policy/exception/cleanup webhooks are hard-coded Fail but only
# match Kyverno CRDs, so they do not trip the guard. Override: SPIKE_KYVERNO_SCALE_ALLOW_FAIL_CLOSED=true.
# The replica counts live in ConfigMap kyverno/ddn-spike-kyverno-replicas (owner-labelled), so `cleanup` from anywhere
# restores them; a trap on EXIT/INT/TERM restores them as well, ignoring further Ctrl-C while it works. The saved state
# is only deleted after every saved deployment was scaled back; on any error the script prints
# "KYVERNO STILL SCALED DOWN" with the recovery command and exits non-zero (also when SPIKE_CLEANUP_ON_EXIT=true), and
# `cleanup` then keeps the ConfigMap and skips the namespace deletion. The guard also refuses when the webhook list
# cannot be read, and treats `*`-prefixed and `namespaces*`/`deployments*` resource tokens as matching.
# Once the restore has started it cannot be interrupted (Ctrl-C and SIGTERM are ignored, a closed pipe such as a killed
# `| tee` is ignored too) and may take up to 5 minutes per deployment (the rollout wait); that is intentional.
SPIKE_ALLOW_KYVERNO_SCALE=true SPIKE_CONFIRM=<ctx> ./run-checklist.sh --context <ctx> --only ac5b run
```

`--provider` is one of `aws`, `azure`, `aks`, `vsphere`, ...; `aks` switches `ac3` to its AKS wording. Evidence files
(`results-*.md`, BPF dumps, drop captures, hostNetwork snapshots) land in `./spike-results/` (`--outdir` or `SPIKE_OUTDIR`).
`run` is idempotent: it re-applies the manifests and skips the pre-deny baseline when the deny is already there.
The clusterwide deny **stays applied** after `run` so you can keep poking; remove it with `cleanup`. The script says so
on every exit (normal, error, Ctrl-C) and prints the exact `cleanup` command for the targeted context; it removes the
deny on exit only with `SPIKE_CLEANUP_ON_EXIT=true`.

Exit status of `run`: 1 when any check ended `FAIL` or `ERROR`, 0 otherwise (`INCONCLUSIVE`, `FINDING`, `PROBE-FAIL`,
`MANUAL` do not change it: read the table); 2 for usage errors (an unknown name in `--only` is rejected **before**
anything is applied) and when the safety gate refuses.

Statuses: `PASS` / `FAIL` as expected; `FINDING` = a design risk was measured (`ac7` widening, `flap` regeneration),
not a kit failure; `PROBE-FAIL` = `flap` saw probe failures but no CNP regeneration, so the cause is elsewhere; `INCONCLUSIVE` = a probe could not run or its precondition did not hold (pods not Ready, no server IP,
connection refused instead of a timeout, `dig`/`exec` failure, baseline already reachable): never a PASS; `ERROR` = a
kit operation failed (for example the `ac5` hand-edit patch); `NOT-RUN` / `MANUAL` as before.
Blocked means **curl timeout (exit 28)** or an explicit **dig timeout**; refused connections, SERVFAIL/REFUSED answers
and exec failures are not evidence of a block.

Hand-applying instead of using the script:

```bash
kubectl apply -f manifests/kyverno-rbac-ciliumnetworkpolicies.yaml
kubectl apply -f manifests/generatingpolicies/
kubectl apply -f manifests/probes/probes.yaml
kubectl apply -f manifests/ccnp-default-deny-all-namespaces.yaml   # the cluster is now denied
kubectl apply -f manifests/ccnp-allow-dns-all-namespaces.yaml      # optional, clusterwide DNS allow
# the namespace needs the owner label for the kit's GeneratingPolicies to act on it (probes.yaml namespaces have it)
kubectl annotate namespace <ns> policy.giantswarm.io/allow-same-namespace=true
kubectl label namespace <ns> policy.giantswarm.io/default-deny=false   # namespace opt-out, live
```

## Checklist functions

| Function | Acceptance criterion of giantswarm/roadmap#4339 | Result type |
|---|---|---|
| `same-ns` | same-namespace (and cross-namespace, external) traffic is denied when unannotated; opted-out control works. External is only asserted if it was reachable before the deny | automated |
| `ac1` | opt-out label is part of the Cilium identity **and** a flip takes effect live, same pod uid/restart count. PASS needs both halves: if no agent exec is possible or the identity list shows no identity with the label, the result is INCONCLUSIVE | automated |
| `ac2` | kubelet readiness/liveness probes keep working (server Ready, restart count did not rise); hostNetwork pods: snapshot taken at least 40 s after the deny and diffed against the pre-deny baseline (only newly not-ready pods fail); Cilium `Cluster health` must be N/N (a missing line is INCONCLUSIVE). The baseline is only trusted if `baseline.meta` ties it to the same context and the same deny uid | automated, extra MANUAL hints |
| `ac3` | AKS: CCNP and selectors work (derived from `ac1`, which is auto-run when needed), drop signals present (hubble-relay, retina/ACNS, drop metrics), effective `bpf-policy-map-max`. Non-AKS: PASS needs `ac1` PASS **and** at least one drop signal **and** `bpf-policy-map-max` set; otherwise INCONCLUSIVE (FAIL if `ac1` failed) | MANUAL on AKS (`az aks show ...`), judged elsewhere |
| `dns` | DNS with clusterwide allow off vs `allow-dns` annotation vs clusterwide allow on; **probe pods in `kube-system` and `giantswarm` must resolve in both states** and `default-allow-dns` must exist there | automated |
| `apiserver` | `allow-kube-apiserver` end to end: a pod curls `https://<kubernetes ClusterIP>` (no DNS involved): blocked without the annotation, TLS/HTTP answer with it, blocked again after removal | automated |
| `ac5` | GeneratingPolicy sync: annotation -> CNP, hand edit reverted, hand delete recreated, annotation removal deletes CNP | automated |
| `ac5b` | generate-existing: policy created after annotation; Kyverno-down case behind `SPIKE_ALLOW_KYVERNO_SCALE=true` | automated / MANUAL commands |
| `flap` | six annotations on a namespace, a continuous same-namespace + DNS probe loop in the client pod (a curl+dig pair per iteration, ~5-10 pairs/s) for `SPIKE_FLAP_SECONDS` (60), while the script makes unrelated Namespace updates (dummy label/annotation add/remove). Records CNP DELETED/ADDED events (`kubectl get -w --output-watch-events`, 1 s resolution), uid/creationTimestamp changes and probe failures; keeps observing until the regeneration settles (all CNPs back, no event for 10 s, max 30 s) and reports the measured delete-to-recreate gap | automated; PASS, FINDING (regeneration seen) or PROBE-FAIL (failures without regeneration) |
| `restart` | annotate, wait for the CNP, restart the Kyverno background controller (rolling), remove the annotation: the CNP must be gone within 120 s (FAIL if it lingers). Skip with `SPIKE_SKIP_KYVERNO_RESTART=true` | automated |
| `ac6` | narrowest working webhook-ingress source: per-variant delta of API-server connections to a logging listener (baseline > 0 = INCONCLUSIVE), then the **real generated `allow-webhook-ingress`** (443/4443/8443/9443/10250) | automated; MANUAL fallback commands on failure |
| `ac7` | L4-only DNS allow vs customer L7 DNS (FQDN) rule: does the generated `allow-dns` widen the L7 allow-list? PASS only if the L7 rule was effective first, the allowed name still resolves afterwards and the generated CNP exists | automated finding; INCONCLUSIVE/MANUAL if a precondition fails |
| `ac4` | per-endpoint BPF policy-map usage with deny + DNS allow + six allows and `SPIKE_LOAD_PODS` identities; action above ~50% of the limit | automated; MANUAL if no agent exec |
| `ac8` | drops in `kube-system` / `giantswarm` for the app coverage audit (giantswarm/roadmap#4375): raw `cilium-dbg monitor --type drop` capture; every exec is bounded by the window (in-container `timeout` plus local `timeout`/`gtimeout`, else process-group kill) | MANUAL (data collected) |
| `ac9` | record guidance in giantswarm/giantswarm#32658 | MANUAL |

Manual commands the script cannot run for you:

```bash
# AKS: ACNS / drop signals
az aks show -g <rg> -n <cluster> --query networkProfile.advancedNetworking
kubectl -n kube-system get pods | grep -Ei 'hubble|retina'
# Webhook ingress, real source identity when ac6 fails (run while the webhook probe is denied)
kubectl -n kube-system exec <agent-on-webhook-node> -c cilium-agent -- cilium-dbg monitor --type drop
hubble observe --verdict DROPPED --to-namespace ddn-spike-webhook --since 5m   # if Hubble exists
# Policy-map headroom on any agent
kubectl -n kube-system exec <agent> -c cilium-agent -- cilium-dbg bpf policy get --all -n | less
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-policy-map-max}'
# L7 DNS / FQDN: the policy used by ac7 is inlined in run-checklist.sh (ddn-spike-fqdn)
# Drops in GS namespaces over a longer window
SPIKE_DROP_WINDOW=600 SPIKE_CONFIRM=<ctx> ./run-checklist.sh --context <ctx> --only ac8 run
```

## Clean up

```bash
./run-checklist.sh --kubeconfig ~/wc.kubeconfig --context <ctx> cleanup
```

First restores Kyverno if the saved replica ConfigMap `kyverno/ddn-spike-kyverno-replicas` exists (from any directory or
machine: the state is in the cluster, not in `spike-results/`). Then deletes, **by the label
`spike.giantswarm.io/owner=default-deny-netpol` only**: the CCNPs (clusterwide deny first, which restores the cluster),
the six GeneratingPolicies, the validating webhook configuration, the ClusterRole, the DNS probe pods in `kube-system` /
`giantswarm`, the replica ConfigMap, and the `ddn-spike-*` namespaces (which takes the generated CNPs with them).
Objects without that label are not touched; the other deletes in the script go through a name plus owner-label check
and refuse otherwise.
Emergency rollback without the script: `kubectl delete ciliumclusterwidenetworkpolicy ddn-spike-default-deny-all-namespaces`.

## Results table (copy per provider)

Fill from `spike-results/results-*.md` and paste into giantswarm/roadmap#4339.

Provider: ______  Cluster / version: ______  Cilium version: ______  Kyverno: ______  Date: ______

| Check | AWS (CAPA) | Azure (CAPZ) | vSphere | AKS | Notes |
|---|---|---|---|---|---|
| same-ns: unannotated traffic denied | | | | | |
| ac1: opt-out in identity, live flip, no restart (flip time s) | | | | | |
| ac2: kubelet probes, hostNetwork, Cilium health | | | | | |
| ac3: CCNP + namespace selector work | | | | | |
| ac3: drop signals (hubble / ACNS / metrics) | | | | | |
| ac3: effective policy-map size | | | | | |
| dns: off denied / `allow-dns` works / clusterwide works / kube-system + giantswarm keep DNS | | | | | |
| ac5: sync (revert edit, delete on annotation removal) | | | | | |
| ac5b: generate-existing (policy create / Kyverno down) | | | | | |
| apiserver: allow-kube-apiserver end to end | | | | | |
| flap: CNP regeneration on unrelated Namespace updates (deleted x, gap s, probe failures) | | | | | |
| restart: annotation removed after background-controller restart deletes the CNP (s) | | | | | |
| ac6: narrowest webhook-ingress source | | | | | |
| ac7: L4 DNS allow vs customer L7 DNS rule | | | | | |
| ac4: max map entries / limit / % | | | | | |
| ac8: drops in kube-system / giantswarm (counts, top apps) | | | | | |
| ac9: guidance recorded in giantswarm/giantswarm#32658 | | | | | |

Status per cell: PASS / FAIL / FINDING / PROBE-FAIL / INCONCLUSIVE / ERROR / MANUAL / NOT-RUN / n/a, plus the evidence value.

## Known limits of the kit

- Ingress-controller and metrics-scraping allows are verified by generation only (the CNP appears and syncs); an end to
  end probe needs a real Envoy Gateway / alloy-metrics source, because probe pods in those namespaces would be denied
  themselves. Verify with `hubble observe` or a real HTTPRoute. (`allow-kube-apiserver` and `allow-webhook-ingress` do
  have end-to-end probes: `apiserver`, `ac6`.)
- The probe server (`socat` in `probes.yaml`) drains the request line before it answers, so closing the socket does not
  cause RSTs that look like failures; a probe counts as reached for curl exit 0/35/52/56/60 (TCP connected) in both
  `probe_http` and the in-pod `flap` loop.
- `flap` timestamps have 1 s resolution (`date +%s`), so gaps are accurate to about +/- 1 s.
- `ac4` is only as realistic as `SPIKE_LOAD_PODS` (distinct identities in one namespace); raise it to the largest
  customer namespace.
- Not verified when this kit was written (no cluster access): everything that needs a running cluster. See
  `SOURCES.md` for what was checked against upstream source.
