# clusterwide-deny E2E suite

Rung 1 of the environment ladder for the clusterwide deny
(giantswarm/roadmap#4346, plan: cabbage-plans `default-deny-netpol`).
It installs network-policies-app with the clusterwide deny enabled on an
ephemeral workload cluster and asserts on observable connectivity from probe
pods, not on rendered manifests.

## Status

Implemented, red until the chart features land. The values key
`denyByDefault.clusterWide.enabled` does not exist in the chart yet; it arrives
with giantswarm/roadmap#4340 (the label-selected standard allows come with
#4376). Until then the chart's `values.schema.json` rejects it
(additionalProperties is false), so the HelmRelease install fails and the
suite is expected to fail fast: the specs run in an `Ordered` container, so
everything after the install spec is skipped. Do not wire it into a required
check before #4340 lands.

Implemented specs: cross-namespace deny, internet blocked (skipped when the
opted-out control cannot reach the internet itself), live opt-out label flip
without a pod restart, Same-namespace policy, DNS with `allow-dns`,
`allow-kube-apiserver`, and all five allow labels set in one request.

Pending (`PIt`, reason in the spec): `allow-webhook-ingress`,
`allow-ingress-controller`, `allow-metrics-scraping`, DNS in
kube-system/giantswarm, `allowDNS` on, deny disabled parity, GS components and
Cilium health, kyverno-crds install ordering.

Negative results only count when a probe times out (packets dropped). Refusals
and other errors fail loudly. Label changes take up to about a minute to show
up, so label specs wait up to 2 minutes.

Probe image notes (`gsoci.azurecr.io/giantswarm/alpine:3.18.3`, busybox 1.36.1): `wget`
does https through `ssl_client` and verifies certificates, so the API server
and internet probes pass `--no-check-certificate`; `nslookup -timeout=2
-retry=1` prints "connection timed out; no servers could be reached" on a
dropped DNS query.

## Layout

- `clusterwide_deny_suite_test.go` the suite and one `Describe` per behaviour.
- `probe_test.go` reusable helpers: namespaces and label changes,
  probe and listener pods, HTTP and DNS reachability assertions, the
  Same-namespace policy.
- `values.yaml` chart values for this suite.
- `config.yaml` provider list (overrides `../../config.yaml` for this suite).

## Running

Same as the `basic` suite. `/run app-test-suites-single PROVIDER=capa TARGET_SUITES=clusterwide-deny`
on a PR runs just this suite on one provider.
