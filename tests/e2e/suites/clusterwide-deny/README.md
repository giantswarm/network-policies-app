# clusterwide-deny E2E suite

Rung 1 of the environment ladder for the clusterwide deny
(giantswarm/roadmap#4346, plan: cabbage-plans `default-deny-netpol`).
It installs network-policies-app on an ephemeral workload cluster, turns the
clusterwide deny on and asserts on observable connectivity from probe
pods, not on rendered manifests.

## Status

Runs with the clusterwide deny (giantswarm/roadmap#4340) and the label-selected
standard allows (giantswarm/roadmap#4376) in the chart, on CAPA (`capa`), CAPZ
(`capz`, cluster-azure), CAPV (`capv`, cluster-vsphere) and CAPVCD (`capvcd`,
cluster-cloud-director). The other providers are added one at a time, each in
its own PR that only merges once the suite is green on that provider there:
every provider in `config.yaml` becomes a required check on every PR (Heimdall).
AKS (`aks`, cluster-aks) is a separate provider from CAPZ and also needs
`standardAllows.webhookIngress.fromEntities: [cluster]` from its cluster values
(giantswarm/roadmap#4341). The specs run in an `Ordered` container, so after the
first failure the rest are skipped. That includes the deny disabled parity spec:
it runs first, while the deny is still off, so a failure there skips every deny
spec.

The cluster is created with the clusterwide deny off. A deny from the cluster's
first minute stops Kyverno from installing (its jobs cannot reach the API
server), so the default apps never become ready and no spec runs. A `BeforeAll`
in the connectivity specs turns the deny on for the running cluster through the
network-policies values in the cluster app's user config
(`global.apps.networkPolicies.values`), the way a customer would, and waits for
`default-deny-all-namespaces` to exist and the HelmRelease to settle. The
AfterSuite turns it off again before the cluster is deleted, so uninstall hooks
can still reach the API server. The `allowDNS` spec flips
`denyByDefault.clusterWide.allowDNS.enabled` on and off again the same way,
which adds two reconcile round trips (a few minutes) to every run.

Implemented specs: deny disabled parity (before the deny is turned on: no
clusterwide deny, the per-namespace `default-deny-all` in kube-system and
giantswarm, unlabeled customer namespaces reach each other, DNS and the API
server), cross-namespace deny, internet blocked (skipped when the opted-out
control has no direct internet egress: its connection is refused or unreachable,
or it keeps timing out for 50s on a cluster whose values set
`global.connectivity.proxy.enabled`, like the CAPVCD test environment; there it
cannot detect a broken opt-out, which the live label flip and cross-namespace
specs still cover), live opt-out label flip without a pod restart,
Same-namespace policy, DNS with `allow-dns`, DNS with `allowDNS` on (turned on
and off again through the cluster values), `allow-kube-apiserver`,
`allow-webhook-ingress`, `allow-ingress-controller`, `allow-metrics-scraping`,
and all five allow labels set in one request.

The webhook spec scopes a `ValidatingWebhookConfiguration` (failurePolicy
Ignore) to labelled probe ConfigMaps in its own namespace and points it at a
listener pod that counts the connections it accepts. A dry-run ConfigMap CREATE
that adds a connection means the API server reached the pod. It starts and ends
with the namespace opted out as the control.

The ingress controller and metrics scraping specs stand in for the real
sources, which these specs don't test:

- Ingress controller: the spec creates `envoy-gateway-system` itself, opted
  out, with a probe pod as the source, since Envoy Gateway is not a default app
  and the standard allow selects any pod in that namespace. It skips if the
  namespace already exists and the suite does not own it. It assumes nothing
  installs a real Envoy Gateway into the suite's namespace during a run.
- Metrics scraping: the spec creates a probe pod in kube-system with the
  `app.kubernetes.io/instance: alloy-metrics` label the standard allow selects,
  plus a suite-owned egress policy for it, since kube-system is under the deny.
  The pod has no `app.kubernetes.io/name` label, so the real alloy-metrics
  workloads and Service don't select it. Both are removed after the spec and
  in the AfterSuite.

Both only prove the target's ingress side. The real sources also need their
own egress opened under the deny, which no standard allow does.

Pending (`PIt`, reason in the spec): DNS in kube-system/giantswarm (allowDNS off
and on), GS components and Cilium health, kyverno-crds install ordering.

Negative results only count when a probe times out (packets dropped). Refusals
and other errors fail loudly. Label changes take up to about a minute to show
up, so label specs wait up to 2 minutes.

Probe image notes (`gsoci.azurecr.io/giantswarm/alpine:3.18.3`, busybox 1.36.1): `wget`
does https through `ssl_client` and verifies certificates, so the API server
and internet probes pass `--no-check-certificate`; `nslookup -timeout=2
-retry=1` prints "connection timed out; no servers could be reached" on a
dropped DNS query.

## Layout

- `clusterwide_deny_suite_test.go` the suite: the install check, the deny disabled parity spec, then the connectivity specs.
- `probe_test.go` reusable helpers: namespaces and label changes,
  probe and listener pods, HTTP and DNS reachability assertions, the
  Same-namespace policy.
- `webhook_test.go` the webhook listener, its `ValidatingWebhookConfiguration`
  and the webhook reachability assertion.
- `cluster_values_test.go` turns the clusterwide deny on and off through the
  cluster values and waits for the result.
- `values.yaml` chart values for this suite (deny off at creation).
- `config.yaml` provider list (overrides `../../config.yaml` for this suite).

## Running

Same as the `basic` suite. `/run app-test-suites-single PROVIDER=capa TARGET_SUITES=clusterwide-deny`
on a PR runs just this suite on one provider.
