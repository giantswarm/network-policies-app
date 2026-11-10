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
	webhookNamespace       = "cwd-e2e-webhook"
	allowDNSNamespace      = "cwd-e2e-allowdns"
	ingressCtrlNamespace   = "cwd-e2e-ingressctl"
	metricsNamespace       = "cwd-e2e-metrics"

	// envoyGatewayNamespace is the source the allow-ingress-controller
	// standard allow selects: any pod in it. The suite creates it with a probe
	// pod, since Envoy Gateway is not a default app, and skips the spec if a
	// real one exists.
	envoyGatewayNamespace = "envoy-gateway-system"

	// Unlabeled namespaces for the deny-disabled spec, which runs before the
	// deny is turned on.
	paritySourceNamespace = "cwd-e2e-parity-src"
	parityTargetNamespace = "cwd-e2e-parity-dst"

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

				// Runs before "connectivity", whose BeforeAll turns the deny on:
				// the cluster is created with the clusterwide deny off, which is
				// the shipped default.
				Describe("deny disabled", func() {
					It("matches today's behaviour when the clusterwide deny is disabled (per-namespace default-deny-all in kube-system/giantswarm, customer namespaces unaffected)", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						DeferCleanup(func() {
							deleteNamespaces(ctx, wcClient, paritySourceNamespace, parityTargetNamespace)
						})

						By("not rendering the clusterwide deny")
						exists, err := clusterWideDenyPolicyExists(ctx)
						Expect(err).NotTo(HaveOccurred())
						Expect(exists).To(BeFalse(), "the CiliumClusterwideNetworkPolicy %s exists although denyByDefault.clusterWide.enabled is false", clusterWideDenyPolicyName)

						By("keeping the per-namespace default-deny-all in kube-system and giantswarm")
						for _, namespace := range perNamespaceDenyNamespaces {
							expectPerNamespaceDenyPolicies(ctx, wcClient, namespace)
						}

						By("leaving traffic between unlabeled customer namespaces open")
						ensureNamespace(ctx, wcClient, parityTargetNamespace, nil)
						target := ensureListenerPod(ctx, wcClient, parityTargetNamespace)
						ensureNamespace(ctx, wcClient, paritySourceNamespace, nil)
						ensureProbePod(ctx, wcClient, paritySourceNamespace)
						expectReachability(ctx, wcClient, paritySourceNamespace, target, true)

						By("resolving DNS and reaching the API server from an unlabeled customer namespace")
						expectDNS(ctx, wcClient, paritySourceNamespace, true, time.Minute)
						expectReachability(ctx, wcClient, paritySourceNamespace, kubernetesServiceTarget(ctx, wcClient), true)
					})
				})

				Describe("connectivity", Ordered, func() {
					// The deny is switched on only now, on the running cluster:
					// set at creation it stops default apps such as Kyverno from
					// installing (see setClusterWideDeny). A BeforeAll, so a
					// focused spec still runs with the deny on.
					BeforeAll(func() {
						ctx := state.GetContext()
						Expect(setClusterWideDeny(ctx, true)).To(Succeed())
						denyEnabled = true
						expectClusterWideDenyPolicy(ctx)
					})

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
						// refusal or unreachable network means no direct egress: skip,
						// since a blocked result would prove nothing. So does a control
						// that keeps timing out for proxyTimeoutGrace on a proxy-only
						// cluster (global.connectivity.proxy.enabled in its values, e.g.
						// the CAPVCD test environment), which may silently drop direct
						// egress. There this spec cannot tell a broken opt-out from a
						// cluster without direct egress; the live opt-out flip and the
						// cross-namespace spec still cover the opt-out. Any other error
						// (exec, unknown output) is retried and fails the spec if it
						// persists, so it can never turn into a skip.
						By("reaching the internet from the opted-out namespace (control)")
						const noDirectEgress = "no-direct-egress"
						const proxyTimeoutGrace = 50 * time.Second
						var noDirectEgressReason string
						var proxyOnly *bool
						start := time.Now()
						Eventually(func() (string, error) {
							noDirectEgressReason = ""
							result, err := probeHTTP(ctx, wcClient, controlNamespace, internet)
							if errors.Is(err, errNoRoute) {
								noDirectEgressReason = err.Error()
								return noDirectEgress, nil
							}
							if err != nil {
								return "", err
							}
							if result == outcomeTimeout && time.Since(start) >= proxyTimeoutGrace {
								if proxyOnly == nil {
									enabled, err := clusterUsesProxy(ctx)
									if err != nil {
										// Never let a values problem turn a failure into a skip.
										logger.Log("Could not read the proxy setting from the cluster values, treating the cluster as not proxy-only: %s", err)
									}
									proxyOnly = &enabled
								}
								if *proxyOnly {
									noDirectEgressReason = fmt.Sprintf("the connection kept timing out for %s and the cluster values set global.connectivity.proxy.enabled", proxyTimeoutGrace)
									return noDirectEgress, nil
								}
							}
							return string(result), nil
						}).
							WithTimeout(70*time.Second).
							WithPolling(10*time.Second).
							Should(Or(Equal(string(outcomeReachable)), Equal(noDirectEgress)), "the opted-out control did not reach %s: opted-out namespaces must have egress", internet)
						if noDirectEgressReason != "" {
							Skip(fmt.Sprintf("the opted-out control cannot reach %s directly: the cluster has no direct internet egress, so a blocked result would prove nothing (%s)", internet, noDirectEgressReason))
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

					PIt("keeps DNS working in kube-system and giantswarm with allowDNS off and on", func() {
						// Not written yet: it needs owned probe pods in kube-system and
						// giantswarm, like the metrics stand-in in kube-system.
					})

					It("resolves DNS in an unlabeled namespace while allowDNS is on and stops when it is turned off", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)
						ensureNamespace(ctx, wcClient, allowDNSNamespace, nil)
						ensureProbePod(ctx, wcClient, allowDNSNamespace)

						// No cleanup on failure: the Ordered container skips the later
						// specs anyway, and the DNS allow only renders while the deny is
						// on, which the AfterSuite turns off.
						By("not resolving a cluster name while allowDNS is off (the default)")
						exists, err := clusterWidePolicyExists(ctx, allowDNSPolicyName)
						Expect(err).NotTo(HaveOccurred())
						Expect(exists).To(BeFalse(), "the CiliumClusterwideNetworkPolicy %s exists although allowDNS is off by default", allowDNSPolicyName)
						expectDNSBlocked(ctx, wcClient, allowDNSNamespace, 3*time.Minute)

						By("resolving it after turning allowDNS on, without any allow label")
						Expect(setClusterWideAllowDNS(ctx, true)).To(Succeed())
						expectClusterWidePolicy(ctx, allowDNSPolicyName, true)
						expectDNS(ctx, wcClient, allowDNSNamespace, true, labelTimeout)

						By("not resolving it after turning allowDNS off again, back to the default for the later specs")
						Expect(setClusterWideAllowDNS(ctx, false)).To(Succeed())
						expectClusterWidePolicy(ctx, allowDNSPolicyName, false)
						expectDNSBlocked(ctx, wcClient, allowDNSNamespace, labelTimeout)
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
					// ingress-controller and metrics-scraping are labelled too and
					// verified by their own specs.
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

					// The webhook source is per provider: the chart default
					// [kube-apiserver, remote-node] covers the providers the
					// spike ran on, AKS needs [cluster] (giantswarm/roadmap#4341).
					It("grants webhook ingress with allow-webhook-ingress and removes it with the label", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						// Starts opted out, so the first step proves the webhook is
						// called and the listener counts the calls.
						ensureNamespace(ctx, wcClient, webhookNamespace, map[string]string{optOutLabelKey: "false"})
						ensureWebhookListener(ctx, wcClient)
						DeferCleanup(func() {
							deleteWebhookConfiguration(ctx, wcClient)
						})
						ensureWebhookConfiguration(ctx, wcClient)

						By("reaching the listener from the API server while the namespace is opted out (control)")
						expectWebhook(ctx, wcClient, true, 3*time.Minute)

						By("not reaching it after removing the opt-out label")
						setNamespaceLabels(ctx, wcClient, webhookNamespace, nil, optOutLabelKey)
						expectWebhook(ctx, wcClient, false, labelTimeout)

						By("reaching it after adding allow-webhook-ingress=true")
						setNamespaceLabels(ctx, wcClient, webhookNamespace, map[string]string{allowWebhookIngressLabel: "true"})
						expectWebhook(ctx, wcClient, true, labelTimeout)

						By("not reaching it after removing the label")
						setNamespaceLabels(ctx, wcClient, webhookNamespace, nil, allowWebhookIngressLabel)
						expectWebhook(ctx, wcClient, false, labelTimeout)

						// Proves the listener still answers, so the last blocked
						// result came from the policy.
						By("reaching it again after opting the namespace out (control)")
						setNamespaceLabels(ctx, wcClient, webhookNamespace, map[string]string{optOutLabelKey: "false"})
						expectWebhook(ctx, wcClient, true, labelTimeout)
					})

					It("grants ingress from the ingress controller with allow-ingress-controller and removes it with the label", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						if namespaceExistsUnowned(ctx, wcClient, envoyGatewayNamespace) {
							Skip(fmt.Sprintf("namespace %s exists and is not owned by this suite, so the suite cannot stand in for Envoy Gateway", envoyGatewayNamespace))
						}

						// The source is opted out, so its own egress is open and only the
						// target's ingress decides.
						ensureNamespace(ctx, wcClient, envoyGatewayNamespace, map[string]string{optOutLabelKey: "false"})
						// Removed right after the spec, so an opted-out namespace with
						// this name never outlives it.
						DeferCleanup(func() {
							deleteNamespaces(ctx, wcClient, envoyGatewayNamespace)
						})
						ensureProbePod(ctx, wcClient, envoyGatewayNamespace)
						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)

						// Starts opted out, so the first step proves the target answers.
						ensureNamespace(ctx, wcClient, ingressCtrlNamespace, map[string]string{optOutLabelKey: "false"})
						target := ensureListenerPod(ctx, wcClient, ingressCtrlNamespace)

						By("reaching the target from the Envoy Gateway namespace while it is opted out (control)")
						expectReachability(ctx, wcClient, envoyGatewayNamespace, target, true)

						By("not reaching it after removing the opt-out label")
						setNamespaceLabels(ctx, wcClient, ingressCtrlNamespace, nil, optOutLabelKey)
						expectBlocked(ctx, wcClient, envoyGatewayNamespace, target, loopbackControl(ingressCtrlNamespace, listenerPodName), labelTimeout)

						By("reaching it from the Envoy Gateway namespace after adding allow-ingress-controller=true")
						setNamespaceLabels(ctx, wcClient, ingressCtrlNamespace, map[string]string{allowIngressCtrlLabel: "true"})
						expectReachabilityWithin(ctx, wcClient, envoyGatewayNamespace, target, true, labelTimeout)

						// The allow selects the source namespace, so another opted-out
						// namespace must stay blocked.
						By("still not reaching it from another namespace, while the Envoy Gateway namespace does")
						expectBlocked(ctx, wcClient, controlNamespace, target, controlProbe{Namespace: envoyGatewayNamespace, Pod: probePodName}, labelTimeout)

						By("not reaching it after removing the label")
						setNamespaceLabels(ctx, wcClient, ingressCtrlNamespace, nil, allowIngressCtrlLabel)
						expectBlocked(ctx, wcClient, envoyGatewayNamespace, target, loopbackControl(ingressCtrlNamespace, listenerPodName), labelTimeout)

						By("reaching it again after opting the namespace out (control)")
						setNamespaceLabels(ctx, wcClient, ingressCtrlNamespace, map[string]string{optOutLabelKey: "false"})
						expectReachabilityWithin(ctx, wcClient, envoyGatewayNamespace, target, true, labelTimeout)
					})

					// The source is a stand-in for the metrics agent in kube-system
					// (see ensureMetricsProbe), since the real one's own egress policies
					// are not what this spec tests.
					It("grants metrics scraping with allow-metrics-scraping and removes it with the label", func() {
						ctx := state.GetContext()
						wcClient := workloadClusterClient()

						DeferCleanup(func() {
							deleteMetricsProbe(ctx, wcClient)
						})
						ensureMetricsProbe(ctx, wcClient)
						ensureNamespace(ctx, wcClient, controlNamespace, map[string]string{optOutLabelKey: "false"})
						ensureProbePod(ctx, wcClient, controlNamespace)

						// Starts opted out, so the first step proves the probe's egress
						// policy works and the target answers.
						ensureNamespace(ctx, wcClient, metricsNamespace, map[string]string{optOutLabelKey: "false"})
						target := ensureListenerPod(ctx, wcClient, metricsNamespace)

						By("reaching the target from the metrics probe while the namespace is opted out (control)")
						expectReachabilityFromPodWithin(ctx, wcClient, metricsScraperNamespace, metricsProbePodName, target, true, 3*time.Minute)

						By("not reaching it after removing the opt-out label")
						setNamespaceLabels(ctx, wcClient, metricsNamespace, nil, optOutLabelKey)
						expectBlockedFromPod(ctx, wcClient, metricsScraperNamespace, metricsProbePodName, target, loopbackControl(metricsNamespace, listenerPodName), labelTimeout)

						By("reaching it from the metrics probe after adding allow-metrics-scraping=true")
						setNamespaceLabels(ctx, wcClient, metricsNamespace, map[string]string{allowMetricsLabel: "true"})
						expectReachabilityFromPodWithin(ctx, wcClient, metricsScraperNamespace, metricsProbePodName, target, true, labelTimeout)

						By("still not reaching it from another namespace, while the metrics probe does")
						expectBlocked(ctx, wcClient, controlNamespace, target, metricsProbeControl, labelTimeout)

						By("still not reaching it from a kube-system pod without the metrics agent label")
						expectBlockedFromPod(ctx, wcClient, metricsScraperNamespace, kubeSystemProbePodName, target, metricsProbeControl, labelTimeout)

						By("not reaching it after removing the label")
						setNamespaceLabels(ctx, wcClient, metricsNamespace, nil, allowMetricsLabel)
						expectBlockedFromPod(ctx, wcClient, metricsScraperNamespace, metricsProbePodName, target, loopbackControl(metricsNamespace, listenerPodName), labelTimeout)

						By("reaching it again after opting the namespace out (control)")
						setNamespaceLabels(ctx, wcClient, metricsNamespace, map[string]string{optOutLabelKey: "false"})
						expectReachabilityFromPodWithin(ctx, wcClient, metricsScraperNamespace, metricsProbePodName, target, true, labelTimeout)
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
				logger.Log("Skipping cleanup (namespaces, webhook configuration), no cluster in state")
				return
			}

			ctx := state.GetContext()
			wcClient, err := state.GetFramework().WC(cluster.Name)
			if err != nil {
				// The workload cluster is about to be deleted anyway.
				logger.Log("Skipping cleanup (namespaces, webhook configuration), no workload cluster client: %s", err)
				return
			}

			// Off before teardown, so uninstall hooks in denied namespaces
			// can still reach the API server.
			disableClusterWideDeny(ctx)

			deleteWebhookConfiguration(ctx, wcClient)
			deleteMetricsProbe(ctx, wcClient)
			deleteNamespaces(ctx, wcClient, deniedNamespace, controlNamespace, targetNamespace,
				sameNamespaceNamespace, dnsNamespace, apiServerNamespace, allAllowsNamespace, webhookNamespace,
				paritySourceNamespace, parityTargetNamespace, allowDNSNamespace, ingressCtrlNamespace, envoyGatewayNamespace, metricsNamespace)
		}).
		Run(t, "Clusterwide Deny Test")
}
