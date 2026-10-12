# clusterwide-deny E2E suite

Rung 1 of the environment ladder for the clusterwide deny
(giantswarm/roadmap#4346, plan: cabbage-plans `default-deny-netpol`).
It installs network-policies-app with the clusterwide deny enabled on an
ephemeral workload cluster and asserts on observable connectivity from probe
pods, not on rendered manifests.

## Status

Scaffold. The values key `denyByDefault.clusterWide.enabled` does not exist in
the chart yet; it arrives with giantswarm/roadmap#4340. Until then the chart
ignores it (or rejects it if the values schema forbids unknown keys), so the
suite is expected to fail. Do not wire it into a required check before #4340
lands. Only the first behaviour is implemented, the rest are pending (`PIt`).

## Layout

- `clusterwide_deny_suite_test.go` the suite and one `Describe` per behaviour.
- `probe_test.go` reusable helpers: namespaces with labels and annotations,
  probe and listener pods, reachability assertions, live label flips.
- `values.yaml` chart values for this suite.
- `config.yaml` provider list (overrides `../../config.yaml` for this suite).

## Running

Same as the `basic` suite. `/run app-test-suites-single PROVIDER=aks TARGET_SUITES=clusterwide-deny`
on a PR runs just this suite on one provider.
