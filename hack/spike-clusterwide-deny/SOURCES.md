# Sources

Evidence for every non-obvious field in `manifests/`. Paths are relative to a directory of shallow clones of the upstream repos
(kyverno, kyverno/api, cilium, network-policies-app (this repo), kyverno-app, security-bundle, coredns-app); the kit was
written against clones in the cabbage-plans `default-deny-netpol/.agents_source/` directory. Kyverno is checked out at tag `v1.18.2` (`945ac9ce8546`), the version Giant Swarm deploys.
Cilium is `main` (`c57b662efd03`), so Cilium field names are checked against upstream HEAD, not against the Cilium
version of a given cluster.

Label mode (the default, `SPIKE_ALLOW_MODE=label`) needs none of the Kyverno evidence: its only upstream dependency is Cilium's
`enableDefaultDeny` (section "`enableDefaultDeny`" under Cilium below). The two Kyverno sections are kept for kyverno mode
(historical, reproduces the results on giantswarm/roadmap#4339).

## Which Kyverno Giant Swarm deploys (kyverno mode, historical)

| Fact | Evidence |
|---|---|
| security-bundle pins `kyverno` app `0.25.0` and `kyverno-crds` `1.18.0` | `security-bundle/helm/security-bundle/values.yaml:104-125` (kyverno, `version: 0.25.0` at :125), `:127-136` (kyverno-crds) |
| `kyverno-app` 0.25.0 "Updated `kyverno` to upstream version `v1.18.2`" | `kyverno-app/CHANGELOG.md:31-43` |
| chart `appVersion: v1.18.2`, subchart `kyverno` 3.8.2 | `kyverno-app/helm/kyverno/Chart.yaml:2-12` (current kyverno-app is 0.25.2: `:35`) |
| Kyverno CRDs are installed by `kyverno-crds`, not by the kyverno chart | `kyverno-app/helm/kyverno/values.yaml:26-27` (`crds.install: false`), `security-bundle/.../values.yaml:127-136` |
| kyverno-app ships its own CiliumNetworkPolicies (`ciliumNetworkPolicy.enabled: true`) | `kyverno-app/helm/kyverno/values.yaml:9-10`, `kyverno-app/helm/kyverno/templates/kyverno-cilium/ciliumnetworkpolicy.yaml` |
| That chart's CNP `allow-kyverno-admission-controller-talk-to-apiserver` selects `app.kubernetes.io/component: admission-controller` and allows **ingress** from the `kube-apiserver` and `remote-node` entities on 443/6443/9443 (the webhook path); this is what the preflight looks for so that the API server can reach Kyverno under the deny | `kyverno-app/helm/kyverno/templates/kyverno-cilium/ciliumnetworkpolicy.yaml` (third policy of the file) |

Not verified: that `kyverno-crds` 1.18.0 contains the `policies.kyverno.io` GeneratingPolicy CRD (it is the Kyverno
1.18 CRD bundle, and `run-checklist.sh` preflight prints the served versions from the live cluster).

## GeneratingPolicy (Kyverno v1.18.2; kyverno mode, historical)

| Field / behavior | Evidence |
|---|---|
| group `policies.kyverno.io`, kind GeneratingPolicy, cluster scoped | `kyverno/cmd/cli/kubectl-kyverno/data/crds/policies.kyverno.io_generatingpolicies.yaml:9,19` |
| versions `v1` (:25), `v1alpha1` (:641), `v1beta1` (:1256) all served; **`v1beta1` is the storage version** (:1864) | same file |
| conformance tests and the CLI tests use `policies.kyverno.io/v1beta1` | `kyverno/test/conformance/chainsaw/generating-policies/data/sync/match-namespace-with-ns-selector/policy.yaml:1` |
| `spec.evaluation.synchronize.enabled`, `spec.evaluation.generateExisting.enabled` (default false), `orphanDownstreamOnPolicyDelete` | CRD `:1281-1332` |
| `spec.matchConstraints.resourceRules` (apiGroups/apiVersions/operations/resources), `spec.variables[]{name,expression}`, `spec.generate[]{expression}` | CRD `:1333`, `:1401`, `:1736`; example `test/conformance/chainsaw/generating-policies/existing/basic-generate-data/policy.yaml` |
| Namespace as trigger, `generator.apply(<ns>, <list>)`, `dyn()` around nested literals | `test/conformance/chainsaw/generating-policies/existing/basic-generate-data/policy.yaml`, `test/cli/test-generating-policy/foreach/data-generate-networkpolicy/policy.yaml` |
| `generator.apply(string, list(map))` returns `true`, so `cond ? generator.apply(...) : true` is a valid generation expression | `sdk/extensions/cel/libs/generator/impl.go:15-33` (`kyverno/sdk`, version pinned at `kyverno/go.mod:43`) |
| generation expressions are evaluated for side effects only; the result value is unused | `kyverno/pkg/cel/policies/gpol/compiler/policy.go:99-105` |
| **Annotation removal deletes the CNP** relies on: UPDATE with synchronize enabled creates an UpdateRequest with `Synchronize=true`; the controller first deletes all downstreams of the trigger, then regenerates only if the policy still produces resources | `kyverno/pkg/webhooks/resource/gpol/handler.go:115-125`, `kyverno/pkg/background/gpol/generate_controller.go:87-93` |
| **GeneratingPolicy match conditions DO reach the webhook, and the webhook operations are forced.** The webhook controller builds `ValidatingWebhook`s per policy: a policy with valid `matchConditions`, `matchPolicy: Exact` or a timeout becomes a *fine-grained* webhook that carries its `MatchConditions`; any other policy (the kit's six) goes into the shared *basic* `-ignore`/`-fail` webhook. For a GeneratingPolicy the rule operations are overwritten with CREATE, UPDATE, DELETE and CONNECT, whatever `matchConstraints.resourceRules[].operations` says. `matchConstraints.namespaceSelector` and `objectSelector` are merged with Kyverno's global webhook selectors and set on the webhook, **but in the basic path the one shared `-ignore` webhook gets the selectors of whichever policy the loop sees last, and the loop order is the informer's list order (`controller.go:1433-1443`, only policies with `AdmissionEnabled()`), i.e. not deterministic: a selector on any policy can therefore silently restrict the events that every other basic-path GeneratingPolicy receives. The kit therefore sets NO `objectSelector`/`namespaceSelector` on its six policies (an earlier revision did) and filters on the owner label in CEL only.** The API server evaluates webhook `matchConditions` with `object` and `oldObject`, so the earlier README claim "match conditions see the new object only" was wrong for the API server side. | `kyverno/pkg/controllers/webhook/validating.go:22-75` (fine-grained path, forced operations at `:62-75`), `:138-159` (selectors, fine-grained), `:196-211` (selectors, basic path, last policy wins), `:270-282` (forced operations, basic path); webhook built for GeneratingPolicies at `kyverno/pkg/controllers/webhook/controller.go:1233-1249` (`gpols`, name `gpol.validate.kyverno.svc`, `kyverno/pkg/config/config.go:63`). Kubernetes `matchConditions` variables (`object`, `oldObject`, `request`): upstream Kubernetes documentation, not in the clones. |
| **GeneratingPolicy failurePolicy is hard-coded `Ignore`:** the `GetFailurePolicy` of `GeneratingPolicy` ignores its argument and returns Ignore; the CRD has no `failurePolicy` field (only `webhookConfiguration.timeoutSeconds`). Consequently every GeneratingPolicy ends up in the `-ignore` webhook. Under the deny an unreachable webhook therefore does not block Namespace writes (it times out, default 10 s, and the request goes on) but nothing is generated. | `kyverno/api` module at `7b64bcf` (the version pinned in `kyverno/go.mod:38`, cloned as `api`): `api/policies.kyverno.io/v1beta1/generating_policy.go:60-62`; CRD `policies.kyverno.io_generatingpolicies.yaml` (v1beta1 `webhookConfiguration`, no `failurePolicy`) |
| Kyverno's own policy/exception/cleanup webhooks are `failurePolicy: Fail` (hard-coded) but only match Kyverno CRDs, so they must not trip the scale-down guard; the resource webhooks follow the policies' own failure policy | `kyverno/pkg/controllers/webhook/controller.go:799,865,912` (`FailurePolicy: &fail`); the guard in `run-checklist.sh` (`kyverno_blocking_webhooks`) only counts non-Ignore webhooks whose rules name Namespaces, Deployments(/scale) or `*` |
| **Untraced / inference, not verified in the source:** whether the UpdateRequest is created for UPDATEs that change nothing relevant (this is what `flap` measures). | `run-checklist.sh ac5`, `flap`, `restart` |
| **Synchronize regenerates on every trigger UPDATE:** an UpdateRequest with `Synchronize=true` first calls `DeleteDownstreams` for the trigger, then re-applies; `DeleteDownstreams` deletes every downstream of that policy whose trigger-UID label matches, via the API (not a patch) | `kyverno/pkg/background/gpol/generate_controller.go:87-93`, `kyverno/pkg/background/gpol/dynamic_watcher.go:210-248`; measured by `run-checklist.sh flap`. Whether the UpdateRequest is created for UPDATEs that change nothing relevant was not traced. |
| `status.conditionStatus.ready` (boolean) and `status.conditionStatus.conditions[]` are the status fields in the storage version `v1beta1`; there is no top-level `status.conditions`, so `kubectl wait --for=condition=Ready` can never succeed. The script waits with `--for=jsonpath='{.status.conditionStatus.ready}'=true`. (`v1`: `:556,:622`; `v1alpha1`: `:1172,:1238`) | `kyverno/cmd/cli/kubectl-kyverno/data/crds/policies.kyverno.io_generatingpolicies.yaml:1787` (`conditionStatus`), `:1853` (`ready`). Not verified: that the Kyverno controllers actually populate `ready` for GeneratingPolicies (the script only warns if the wait times out). |
| Kyverno-managed webhook configurations carry the label `webhook.kyverno.io/managed-by=kyverno`; the script lists them to refuse scaling Kyverno down when one has `failurePolicy` other than `Ignore` | `kyverno/api/kyverno/constants.go:10`, `kyverno/pkg/controllers/webhook/utils.go:117-120` |
| Kyverno deployments carry `app.kubernetes.io/component=<name>` (`background-controller`) and `app.kubernetes.io/part-of=kyverno` | `kyverno/charts/kyverno/templates/_helpers/_labels.tpl:37-39`, `kyverno/charts/kyverno/templates/background-controller/_helpers.tpl:18` (`part-of` is the chart's `kyverno.fullname`, `kyverno` by default (`_labels.tpl:33`); if a release overrides the fullname the script finds no deployments and says so instead of scaling anything) |
| generate-existing runs when the policy itself is created/updated (lists all existing triggers and creates an UpdateRequest), not on a Kyverno restart as such | `kyverno/pkg/policy/policy_controller.go:446-452`, `kyverno/pkg/policy/gpol.go:59-80` |
| Background controller ClusterRole aggregates every ClusterRole labeled `rbac.kyverno.io/aggregate-to-background-controller: "true"` | `kyverno/charts/kyverno/templates/background-controller/clusterrole.yaml:9-14` |

Not verified from source (spike answers): whether Kyverno, when it is down while a namespace is annotated, picks the
trigger up on restart (`ac5b`, opt-in); whether `has(object.metadata.annotations) && "k" in ...` evaluates as intended
in the policy engine (it is plain CEL, but no upstream test uses it); the UpdateRequest volume of 6 policies x every
Namespace UPDATE on a busy cluster.

## Cilium

| Field / behavior | Evidence |
|---|---|
| namespace labels are exposed as endpoint labels `io.cilium.k8s.namespace.labels.<label-key>` | `cilium/pkg/k8s/apis/cilium.io/const.go:37-42`, `cilium/Documentation/security/policy/kubernetes.rst:104-113` |
| usable in selectors of CNP and CCNP | same docs (`kubernetes.rst:106-109`); working precedent in network-policies-app: `network-policies-app/helm/network-policies-app/templates/cilium/deny-egress-to-imds.yaml:13-27` (CCNP `endpointSelector.matchExpressions` with `io.cilium.k8s.namespace.labels.<key>` `NotIn`) |
| `NotIn` also matches endpoints whose namespace lacks the label | Kubernetes selector semantics, relied on by the IMDS precedent above; `run-checklist.sh same-ns` and `ac1` verify it live |
| `ingress: [{}]` / `egress: [{}]` = empty rule that enables default deny without allowing anything | existing policy `network-policies-app/helm/network-policies-app/templates/cilium/deny-all.yaml:9-13`; semantics `cilium/pkg/policy/api/rule.go:122-139` |
| entities `kube-apiserver`, `remote-node` (also `host`, `cluster`, `world`) | `cilium/pkg/policy/api/entity.go:58,67` |
| `endpointSelector` of a CCNP is cluster wide, a CNP's is bound to its own namespace; `fromEndpoints`/`toEndpoints` with `io.kubernetes.pod.namespace` select other namespaces | `cilium/Documentation/security/policy/kubernetes.rst:110-118`, `network-policies-app/.../allow-dns.yaml:11-20` |
| `cilium-dbg bpf policy get --all` dumps every endpoint policy map ("Endpoint ID:" header, rows start with `Allow`/`Deny`); `-n` skips identity lookups | `cilium/cilium-dbg/cmd/bpf_policy_get.go:36-53,56-92,155-190` |
| `cilium-dbg endpoint list -o jsonpath` syntax; CiliumEndpoint `status.id` | `cilium/Documentation/cheatsheet.rst:71-73`, `cilium/Documentation/security/policy-creation.rst:90` |
| policy map size flag `--bpf-policy-map-max`, default 16384 per endpoint (docs); hard compile-time upper bound `1<<16` | `cilium/Documentation/cmdref/cilium-agent.md:68`, `cilium/pkg/option/config.go:531-532` |

### `enableDefaultDeny` (label-mode standard allows and Same-namespace policy)

Evidence for `enableDefaultDeny: {ingress: false, egress: false}` in `manifests/standard-allows/*.yaml` and
`manifests/same-namespace-policy.yaml`. Paths are in the cilium clone at
`cabbage-plans/.claude/worktrees/agent-ab055d597bd3432b3/default-deny-netpol/.agents_source/cilium` (Cilium `main`,
`c57b662efd03`, VERSION `1.21.0-dev`), so these are checked against upstream HEAD, not against the Cilium a cluster runs.

| Fact | Evidence |
|---|---|
| `DefaultDenyConfig` has optional `ingress` and `egress` booleans; a `Rule` (so a CNP/CCNP spec) carries it as `enableDefaultDeny` | `cilium/pkg/policy/api/rule.go:32-46` (`DefaultDenyConfig`), `:122-139` (field `EnableDefaultDeny`, json `enableDefaultDeny`), `:199-202` (`WithEnableDefaultDeny`) |
| Semantics: when not specified the default is true for each direction that has rules; if several policies apply, default deny is on when ANY requests it; "useful for broad-based network policies that will not cause endpoints to enter default-deny mode" | `cilium/pkg/policy/api/rule.go:122-138` (field comment) |
| The default is filled in per direction at sanitize time (`len(Ingress)+len(IngressDeny) > 0` for ingress, likewise egress); only when the agent/operator flag is off is it forced to true | `cilium/pkg/policy/api/rule_validation.go:101-118` (`Sanitize`) |
| The flag is `enable-non-default-deny-policies`, **default true**, a hidden flag | `cilium/pkg/option/config.go:935-936,1791-1792`, `cilium/pkg/defaults/defaults.go:518-519`, `cilium/pkg/option/flags.go:25-27` |
| Per endpoint, ingress/egress default deny is set only by the selecting rules whose `DefaultDeny` is true (`r.DefaultDeny` -> `hasIngressDefaultDeny` / `hasEgressDefaultDeny`), so a selecting allow with `false` leaves the endpoint un-denied | `cilium/pkg/policy/repository.go:402-445` (`computePolicyEnforcementAndRules`) |
| Documented: "Rules with `EnableDefaultDeny` disabled are ignored when determining the default mode"; worked example is a CCNP with `enableDefaultDeny: {egress: false, ingress: false}` that "can safely apply cluster-wide" | `cilium/Documentation/security/policy/intro.rst:57-64` and the example at `:71-100` |
| **Does not cover L7:** "`EnableDefaultDeny` does not apply to layer-7 policy ... Adding a layer-7 rule that does not include a layer-7 allow-all will cause drops, even when default-deny is explicitly disabled" | `cilium/Documentation/security/policy/intro.rst:66-69`. This is why the label `allow-dns` is L4 only (no `rules.dns`) |
| CCNP and CNP CRD schemas both define `spec.enableDefaultDeny` (and `specs[].enableDefaultDeny`) with `ingress`/`egress` booleans; the kit's CCNPs and CNP validate against them (checked offline with `jsonschema` after making unknown fields errors, with a negative control) | `cilium/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumclusterwidenetworkpolicies.yaml:1769,5131`, `ciliumnetworkpolicies.yaml:1772,5134` |
| In a CNP the peers `fromEndpoints: [{}]` / `toEndpoints: [{}]` get the policy's own namespace added when the selector names no namespace (`io.kubernetes.pod.namespace`) or namespace labels, so the Same-namespace policy opens only its own namespace; in a CCNP only an "has a namespace label" expression is added | `cilium/pkg/k8s/apis/cilium.io/utils/utils.go:120-152` (`getEndpointSelector`, namespace added at `:146-147`; clusterwide `Exists` at `:139-145`); note `kubernetes.rst:110-118` says the opposite for selectors that DO carry namespace labels (not restricted to the own namespace) |

Verified against upstream tags: `enableDefaultDeny` (`DefaultDenyConfig`) is absent from `pkg/policy/api/rule.go` at `v1.15.0` and
`v1.15.9` and present at `v1.16.0`, so it exists **since Cilium 1.16.0** (the clone itself is a shallow `main` without tags; this
was checked on the upstream tags). cilium-app 1.6.1 ships Cilium appVersion 1.20.2. If a cluster's Cilium is older than 1.16 and
does not know the field, a structural CRD would prune it and every label allow would put labeled namespaces into default deny;
`setup` warns when the field is missing after the apply, the preflight prints the agent image, and `nodeny` fails in that case. On
AKS the Azure-managed Cilium version decides (PRD "AKS caveat"). The label latency (10-35 s) is a measurement from the CAPZ spike,
not source.

### Cilium health endpoint (`reserved:health`) and the deny

First real run: the clusterwide deny also selected each node's health endpoint, so `Cluster health` fell to 3/7 and 1/6. The
manifests exclude it with `matchExpressions: [{key: "reserved:health", operator: DoesNotExist}]` next to the namespace
opt-out `NotIn`, in both CCNPs. This is the form chosen (the alternative, a separate allow CCNP for health traffic, is not
needed because a selector can exclude it). Evidence, Cilium `main` (`c57b662efd03`):

| Fact | Evidence |
|---|---|
| the health endpoint gets exactly the label `reserved:health` (source `reserved`, key `health`, no value) and nothing else; it has no namespace labels, which is why `NotIn` on a namespace label selects it | `cilium/pkg/labels/labels.go:54` (`IDNameHealth`), `:94` (`LabelHealth`), `cilium/pkg/health/health_connectivity_endpoint.go:409` (`ep.UpdateLabels(... labels.LabelHealth ...)`) |
| selector keys may carry a label source (`<source>:<key>`); the CRD schema puts no pattern on `matchExpressions[].key` (plain string) and Cilium's validation accepts one `:` with a source prefix | `cilium/pkg/labels/validation.go:112-135` (`IsValidCiliumLabelKey`), `cilium/pkg/policy/api/selector.go:222-238` (`Validate` / `Sanitize`), `cilium/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumclusterwidenetworkpolicies.yaml:1798-1820` (`spec.endpointSelector.matchExpressions.key: type string`) |
| `Sanitize` keeps an explicit source: only keys without one get the `any:` prefix, so `reserved:health` stays `reserved:health` | `cilium/pkg/labels/labels.go:980-987` (`NewSourceEncodedLabelKey`) |
| `DoesNotExist` is evaluated as "the label array has no label with that key"; a `reserved:` selector key only matches a `reserved:` label (`any:` would match every source) | `cilium/pkg/k8s/slim/k8s/apis/labels/selector.go:247-248`, `cilium/pkg/labels/array.go:148-153` (`LabelArray.Has`), `cilium/pkg/labels/labels.go:434-443` (`Label.HasKey`) |
| Cilium itself selects the health endpoint with a CCNP `matchLabels: {'reserved:health': ''}` (allowing `remote-node` in and out); documented as "Example: Add Health Endpoint" | `cilium/examples/policies/kubernetes/clusterwide/health.yaml:1-13`, `cilium/Documentation/security/policy/kubernetes.rst:247-256` |
| a policy selecting the health endpoint puts it into enforcement (observed in the first run: enforcement "both") | `cilium-dbg endpoint list` columns; first real run, not source |

Not verified offline: that the cluster's Cilium (cilium-app 1.6.1) accepts the expression exactly like `main` does (the selector
parsing above is long-standing, the health.yaml example is old); `ac2` lists the health endpoint's enforcement per agent
(`Disabled/Disabled` expected) and compares `Cluster health` with the pre-deny baseline, which is the live proof. The other
reserved identities without namespace labels (`reserved:init`, `reserved:ingress`, the host endpoint with the host firewall)
are selected by the same `NotIn` and are NOT excluded by the kit.

### `cilium-dbg identity list` output (ac1 identity check)

| Fact | Evidence |
|---|---|
| default output is an `ID` / `LABELS` table: the first label on the ID line, one further label per line below, labels as `<source>:<key>[=<value>]` sorted | `cilium/pkg/identity/cache/cache.go:36-55` (`FormatIdentities`), `cilium/pkg/labels/labels.go:289-307` (`GetPrintableModel`), `:469-474` (`Label.String`) |
| `--endpoints` lists the identities of locally managed endpoints with a third `REFCOUNT` column on the ID line | `cilium/cilium-dbg/cmd/identity_list.go:28-53`, `cilium/pkg/identity/identitymanager/manager.go:244-263` |
| namespace labels are in the default identity label set, printed as `k8s:io.cilium.k8s.namespace.labels.<label key>=<value>`; the pod namespace as `k8s:io.kubernetes.pod.namespace=<ns>` | `cilium/pkg/labelsfilter/filter.go:228-229`, `cilium/pkg/k8s/apis/cilium.io/const.go:37-42` |
| the plain list returns all known global identities of the agent's cache, not only local ones | `cilium/pkg/identity/api/identityapi.go:43-52`, `cilium/pkg/identity/cache/cache.go:104-130` |

So the label text the first version of the kit grepped for was the right one; the check now also anchors it to the identity
block of the probe namespace and asks the agent on the probe pod's node (see README "First real run").

### Kyverno UpdateRequests (evidence of the generation checks)

`kubectl -n kyverno get updaterequests.kyverno.io` (short name `ur`) lists what the admission webhook hands to the background
controller: fields `spec.policy`, `spec.requestType`, `spec.resource.{kind,namespace,name}`, `status.state`
(`kyverno/api/kyverno/v2/updaterequest_types.go:29,46-53,82-85`; identical at tags `v1.17.0` and `v1.18.2`). `ac5b`, `restart`
and `bulk` print the count before and after the wait and dump the list.

The PRD says cilium-app raises `bpf.policyMapMax` to 65536; the script reads the real value from `cm/cilium-config`
key `bpf-policy-map-max` instead of assuming it. Not verified: the ConfigMap key name on AKS-managed Cilium.

## CoreDNS ingress (what lets DNS work under the deny)

The clusterwide deny selects every endpoint of `kube-system`, CoreDNS included, with an empty ingress rule. Nothing in
this kit allows ingress to CoreDNS: the six standard allows and the DNS allows are egress or other ingress. In the Giant
Swarm stack the allow comes from **coredns-app**, which renders a Kubernetes `NetworkPolicy` named after the app
(`name: coredns`, `namespace: kube-system`) selecting `k8s-app: coredns` with ingress on the DNS ports (`ports.dns.targetPort`
and `ports.dns.port`, UDP and TCP) and on the metrics port from any source, plus `egress: [{}]`:
`coredns-app/helm/coredns-app/templates/np.yaml:1-27` (clone at `f3d76c8`, default branch; `values.yaml:2,4` set
`name: coredns`, `namespace: kube-system`). Cilium enforces Kubernetes NetworkPolicies together with CNP/CCNP and unions
their allows, so that policy keeps CoreDNS reachable. Not in the cloned repos: the node-local DNS cache
(`k8s-dns-node-cache`) ingress allow; nothing was found for it, so the preflight prints a confirmation request when
those pods exist. The preflight heuristic (`coredns_ingress_candidates`) lists NetworkPolicies and CNPs in `kube-system`
and all non-kit CCNPs whose selector mentions CoreDNS / kube-dns / node-cache or is `{}` and that have a non-empty
ingress; it is text matching on `kubectl -o jsonpath` output, not a policy evaluator, hence the override
`SPIKE_ALLOW_NO_COREDNS_INGRESS=true`.

## DNS targets

Copied verbatim from `network-policies-app/helm/network-policies-app/templates/cilium/allow-dns.yaml:11-30`:
`k8s-app` = `coredns`, `k8s-dns-node-cache`, `kube-dns` (AKS) in `kube-system`; ports 1053 and 53, UDP and TCP.
The template adds `rules.dns: [{matchPattern: "*"}]` only if `allowEgressToProxy.enabled` (`:31-35`); the spike
manifests are L4 only, matching the PRD.

## Values taken from elsewhere (provisional)

| Value | Source |
|---|---|
| metrics-scraping source = alloy-metrics in `kube-system`, label `app.kubernetes.io/instance: alloy-metrics` | `giantswarm/observability-bundle` `helm/observability-bundle/values.yaml` (`alloyMetrics`, `namespace: kube-system`), and giantswarm/mcp-prometheus `ciliumNetworkPolicy.ingress.metricsScrapers`. Provisional: confirm with the observability team, the PRD says only "GS monitoring agents". |
| ingress-controller source = namespace `envoy-gateway-system` | PRD / glossary |
| webhook ports `443,4443,8443,9443,10250` | assumption: common admission webhook ports, not in the PRD; the PRD says "webhook ports" without a list |
