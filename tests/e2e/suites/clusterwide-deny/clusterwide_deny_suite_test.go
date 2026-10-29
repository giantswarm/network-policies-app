package clusterwidedeny

import (
	"errors"
	"fmt"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	helmv2 "github.com/fluxcd/helm-controller/api/v2"
	"github.com/giantswarm/apptest-framework/v5/pkg/state"
	"github.com/giantswarm/apptest-framework/v5/pkg/suite"
	"github.com/giantswarm/clustertest/v5/pkg/logger"

	"k8s.io/apimachinery/pkg/types"
)

const (
	isUpgrade = false

	installNamespace = "kube-system"

	// Namespaces created by this suite. The listener (target) lives in
	// targetNamespace and the control probe in controlNamespace; both carry the
	// namespace opt-out label. The deny applies to deniedNamespace, unlabeled.
	targetNamespace  = "cwd-e2e-target"
	controlNamespace = "cwd-e2e-control"
	deniedNamespace  = "cwd-e2e-denied"

	// Each remaining spec gets its own unlabeled namespace, so label state
	// never leaks between specs.
	sameNamespaceNamespace = "cwd-e2e-samens"
	dnsNamespace           = "cwd-e2e-dns"
	apiServerNamespace     = "cwd-e2e-apiserver"
	allAllowsNamespace     = "cwd-e2e-allallows"

	// internetHost is a public HTTPS address, probed by IP so DNS plays no
	// part.
	internetHost = "1.1.1.1"
)

func TestClusterwideDeny(t *testing.T) {
	suite.New().
		WithInstallNamespace(installNamespace).
		WithIsUpgrade(isUpgrade).
		WithValuesFile("./values.yaml").
		Tests(func() {
			// Ordered: when the install spec fails, the rest are skipped rather
			// than reporting misleading connectivity failures.
			Describe("clusterwide deny", Ordered, func() {
				It("should deploy the HelmRelease", func() {
					Eventually(func() (bool, error) {
						appNamespace := state.GetCluster().Organization.GetNamespace()
						appName := fmt.Sprintf("%s-network-policies", state.GetCluster().Name)

						logger.Log("HelmRelease: %s/%s", appNamespace, appName)

						release := &helmv2.HelmRelease{}
						err := state.GetFramework().MC().Get(state.GetContext(), types.NamespacedName{Name: appName, Namespace: appNamespace}, release)
						if err != nil {
							return false, err
						}

						for _, c := range release.Status.Conditions {
							if c.Type == "Ready" {
								if c.Status == "True" {
									return true, nil
								}
								return false, fmt.Errorf("HelmRelease not ready [%s]: %s", c.Reason, c.Message)
							}
						}

						return false, fmt.Errorf("HelmRelease not ready")
					}).
						WithTimeout(5 * time.Minute).
						WithPolling(15 * time.Second).
						Should(BeTrue())
				})

				Describe("connectivity", func() {
					It("blocks a probe in an unlabeled namespace from reaching another namespace", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						// The listener and the control probe sit in two different
						// opted-out namespaces, so the control proves cross-namespace
						// reachability and only the denied probe's egress can be what
						// blocks the connection.
						ensureNamespace(ctx, wcClient, targetNamespace, map[string]string{optOutLabelKey: "false"})
						target := ensureListenerPod(ctx, wcClient, targetNamespace)

						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)

						ensureNamespace(ctx, wcClient, deniedNamespace, nil)
						ensureProbePod(ctx, wcClient, deniedNamespace)

						By("reaching the target from the other opted-out namespace (control)")
						expectReachability(ctx, wcClient, controlNamespace, target, true)

						By("not reaching the target from the unlabeled namespace")
						expectReachability(ctx, wcClient, deniedNamespace, target, false)

						By("still reaching the target from the control, so the target is up")
						expectReachability(ctx, wcClient, controlNamespace, target, true)
					})

					It("blocks a probe in an unlabeled namespace from reaching the internet", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()
						internet := probeTarget{Host: internetHost, Port: 443, Scheme: "https", HTTPSAnyAnswer: true}

						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)
						ensureNamespace(ctx, wcClient, deniedNamespace, nil)
						ensureProbePod(ctx, wcClient, deniedNamespace)

						// The control proves the cluster has direct egress. An opted-out
						// namespace has no deny, so a timeout there is a failure. A
						// refusal or unreachable network is what a proxy-only cluster
						// gives: skip, since a blocked result would prove nothing. Any
						// other error (exec, unknown output) is retried and fails the
						// spec if it persists, so it can never turn into a skip.
						By("reaching the internet from the opted-out namespace (control)")
						const noRoute = "no-route"
						var noRouteErr error
						Eventually(func() (string, error) {
							noRouteErr = nil
							result, err := probeHTTP(ctx, wcClient, controlNamespace, internet)
							if errors.Is(err, errNoRoute) {
								noRouteErr = err
								return noRoute, nil
							}
							if err != nil {
								return "", err
							}
							return string(result), nil
						}).
							WithTimeout(time.Minute).
							WithPolling(10*time.Second).
							Should(Or(Equal(string(outcomeReachable)), Equal(noRoute)), "the opted-out control did not reach %s: opted-out namespaces must have egress", internet)
						if noRouteErr != nil {
							Skip(fmt.Sprintf("the opted-out control has no route to %s: the cluster has no direct internet egress, so a blocked result would prove nothing (%v)", internet, noRouteErr))
						}

						By("not reaching the internet from the unlabeled namespace")
						expectBlocked(ctx, wcClient, deniedNamespace, internet, optedOutControl, 3*time.Minute)
					})

					It("lets a probe follow a live opt-out label flip without restarting the pod", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						ensureNamespace(ctx, wcClient, targetNamespace, map[string]string{optOutLabelKey: "false"})
						target := ensureListenerPod(ctx, wcClient, targetNamespace)
						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)
						ensureNamespace(ctx, wcClient, deniedNamespace, nil)
						ensureProbePod(ctx, wcClient, deniedNamespace)

						// Leave the shared namespace unlabeled for later specs, also
						// when this one fails half way.
						DeferCleanup(func() {
							setNamespaceLabels(ctx, wcClient, deniedNamespace, nil, optOutLabelKey)
						})

						By("not reaching the target before the flip")
						expectBlocked(ctx, wcClient, deniedNamespace, target, optedOutControl, 3*time.Minute)
						before := getPodIdentity(ctx, wcClient, deniedNamespace, probePodName)

						By("reaching the target after adding default-deny=false")
						setNamespaceLabels(ctx, wcClient, deniedNamespace, map[string]string{optOutLabelKey: "false"})
						expectReachabilityWithin(ctx, wcClient, deniedNamespace, target, true, labelTimeout)
						Expect(getPodIdentity(ctx, wcClient, deniedNamespace, probePodName)).To(Equal(before), "the probe pod was replaced or restarted by the label change")

						By("not reaching the target after removing the label")
						setNamespaceLabels(ctx, wcClient, deniedNamespace, nil, optOutLabelKey)
						expectBlocked(ctx, wcClient, deniedNamespace, target, optedOutControl, labelTimeout)
						Expect(getPodIdentity(ctx, wcClient, deniedNamespace, probePodName)).To(Equal(before), "the probe pod was replaced or restarted by the label change")
					})

					It("denies same-namespace traffic until the namespace owner applies a Same-namespace policy", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						// Cross-namespace target in an opted-out namespace, to show the
						// Same-namespace policy opens nothing beyond the namespace.
						ensureNamespace(ctx, wcClient, targetNamespace, map[string]string{optOutLabelKey: "false"})
						other := ensureListenerPod(ctx, wcClient, targetNamespace)
						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)

						ensureNamespace(ctx, wcClient, sameNamespaceNamespace, nil)
						sameNamespaceTarget := ensureListenerPod(ctx, wcClient, sameNamespaceNamespace)
						ensureProbePod(ctx, wcClient, sameNamespaceNamespace)
						// No other namespace can reach a pod here, so the listener
						// proves it is serving by probing itself over loopback.
						selfControl := loopbackControl(sameNamespaceNamespace, listenerPodName)

						DeferCleanup(func() {
							deleteSameNamespacePolicy(ctx, wcClient, sameNamespaceNamespace)
						})
						// A leftover policy from an earlier run would hide the first step.
						deleteSameNamespacePolicy(ctx, wcClient, sameNamespaceNamespace)

						By("not reaching a pod in the same namespace without the policy")
						expectBlocked(ctx, wcClient, sameNamespaceNamespace, sameNamespaceTarget, selfControl, 3*time.Minute)

						By("reaching a pod in the same namespace with the policy")
						applySameNamespacePolicy(ctx, wcClient, sameNamespaceNamespace)
						expectReachabilityWithin(ctx, wcClient, sameNamespaceNamespace, sameNamespaceTarget, true, labelTimeout)

						By("still not reaching another namespace with the policy")
						expectBlocked(ctx, wcClient, sameNamespaceNamespace, other, optedOutControl, 3*time.Minute)

						By("not reaching a pod in the same namespace after deleting the policy")
						deleteSameNamespacePolicy(ctx, wcClient, sameNamespaceNamespace)
						expectBlocked(ctx, wcClient, sameNamespaceNamespace, sameNamespaceTarget, selfControl, labelTimeout)
					})

					It("breaks DNS in an unlabeled namespace and restores it with allow-dns", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)
						ensureNamespace(ctx, wcClient, dnsNamespace, nil)
						ensureProbePod(ctx, wcClient, dnsNamespace)

						By("not resolving a cluster name without the label")
						expectDNSBlocked(ctx, wcClient, dnsNamespace, 3*time.Minute)

						By("resolving it after adding allow-dns=true")
						setNamespaceLabels(ctx, wcClient, dnsNamespace, map[string]string{allowDNSLabelKey: "true"})
						expectDNS(ctx, wcClient, dnsNamespace, true, labelTimeout)

						By("not resolving it after removing the label")
						setNamespaceLabels(ctx, wcClient, dnsNamespace, nil, allowDNSLabelKey)
						expectDNSBlocked(ctx, wcClient, dnsNamespace, labelTimeout)
					})

					PIt("keeps DNS working in kube-system and giantswarm while allowDNS is off", func() {
						// Pending on purpose: it needs a probe pod in system namespaces,
						// and creating pods there is intrusive.
					})

					PIt("keeps DNS working in an unlabeled customer namespace and in kube-system/giantswarm when allowDNS is on", func() {
						// Needs a second suite or a values flip: allowDNS.enabled: true.
					})

					It("grants API server access with allow-kube-apiserver and removes it with the label", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()
						apiServer := kubernetesServiceTarget(ctx, wcClient)

						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)
						ensureNamespace(ctx, wcClient, apiServerNamespace, nil)
						ensureProbePod(ctx, wcClient, apiServerNamespace)

						By("not reaching the API server without the label")
						expectBlocked(ctx, wcClient, apiServerNamespace, apiServer, optedOutControl, 3*time.Minute)

						By("getting an HTTPS answer after adding allow-kube-apiserver=true")
						setNamespaceLabels(ctx, wcClient, apiServerNamespace, map[string]string{allowKubeAPIServerLabel: "true"})
						expectReachabilityWithin(ctx, wcClient, apiServerNamespace, apiServer, true, labelTimeout)

						By("not reaching the API server after removing the label")
						setNamespaceLabels(ctx, wcClient, apiServerNamespace, nil, allowKubeAPIServerLabel)
						expectBlocked(ctx, wcClient, apiServerNamespace, apiServer, optedOutControl, labelTimeout)
					})

					// Covers the DNS and API server allows. webhook-ingress,
					// ingress-controller and metrics-scraping are labelled too but
					// verified by their own pending specs.
					It("keeps the DNS and API server allows working when all five allow labels are set in one request", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()
						apiServer := kubernetesServiceTarget(ctx, wcClient)

						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)
						ensureNamespace(ctx, wcClient, allAllowsNamespace, nil)
						ensureProbePod(ctx, wcClient, allAllowsNamespace)

						By("starting with DNS and the API server blocked")
						expectDNSBlocked(ctx, wcClient, allAllowsNamespace, 3*time.Minute)
						expectBlocked(ctx, wcClient, allAllowsNamespace, apiServer, optedOutControl, 3*time.Minute)

						By("setting all five allow labels in one update")
						setNamespaceLabels(ctx, wcClient, allAllowsNamespace, map[string]string{
							allowDNSLabelKey:         "true",
							allowKubeAPIServerLabel:  "true",
							allowWebhookIngressLabel: "true",
							allowIngressCtrlLabel:    "true",
							allowMetricsLabel:        "true",
						})

						By("resolving DNS and reaching the API server")
						expectDNS(ctx, wcClient, allAllowsNamespace, true, labelTimeout)
						expectReachabilityWithin(ctx, wcClient, allAllowsNamespace, apiServer, true, labelTimeout)

						By("keeping both working")
						dns := func() (bool, error) {
							result, err := probeDNS(ctx, wcClient, allAllowsNamespace)
							return result == outcomeReachable, err
						}
						api := func() (bool, error) {
							result, err := probeHTTP(ctx, wcClient, allAllowsNamespace, apiServer)
							return result == outcomeReachable, err
						}
						Consistently(dns).WithTimeout(30*time.Second).WithPolling(5*time.Second).Should(BeTrue(), "DNS stopped working with all five labels set")
						Consistently(api).WithTimeout(30*time.Second).WithPolling(5*time.Second).Should(BeTrue(), "the API server became unreachable with all five labels set")
					})

					PIt("grants webhook ingress with allow-webhook-ingress", func() {
						// The source is per provider and needs a webhook configuration
						// pointing at a pod in the namespace; AKS needs `cluster`.
					})

					PIt("grants ingress from the ingress controller with allow-ingress-controller", func() {
						// Needs envoy-gateway on the cluster.
					})

					PIt("grants metrics scraping with allow-metrics-scraping", func() {
						// Needs a Giant Swarm metrics scraper on the cluster.
					})

					PIt("matches today's behaviour when the clusterwide deny is disabled (per-namespace default-deny-all in kube-system/giantswarm, customer namespaces unaffected)", func() {
						// Needs a values flip or a separate suite with the key set to false.
					})

					PIt("keeps Giant Swarm components healthy and Cilium reporting healthy with the clusterwide deny on", func() {
						// Needs a per-provider list of GS components to check, plus the
						// Cilium agent health.
					})

					PIt("installs after kyverno-crds is Ready on a fresh cluster created with the clusterwide deny on, without failing on missing Kyverno CRDs", func() {
						// Install ordering is decided at cluster creation, so this needs
						// the cluster values to carry the key from the start (giantswarm/roadmap#4341).
					})
				})
			})
		}).
		AfterSuite(func() {
			cluster := state.GetCluster()
			if cluster == nil {
				logger.Log("Skipping namespace cleanup, no cluster in state")
				return
			}

			ctx := state.GetContext()
			wcClient, err := state.GetFramework().WC(cluster.Name)
			if err != nil {
				// The workload cluster is about to be deleted anyway.
				logger.Log("Skipping namespace cleanup, no workload cluster client: %s", err)
				return
			}

			deleteNamespaces(ctx, wcClient, deniedNamespace, controlNamespace, targetNamespace,
				sameNamespaceNamespace, dnsNamespace, apiServerNamespace, allAllowsNamespace)
		}).
		Run(t, "Clusterwide Deny Test")
}
