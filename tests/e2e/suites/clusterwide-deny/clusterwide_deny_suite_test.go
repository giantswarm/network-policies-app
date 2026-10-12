package clusterwidedeny

import (
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

					PIt("blocks a probe in an unlabeled namespace from reaching the internet", func() {
						// Probe a public address from deniedNamespace; needs a control
						// from an opted-out namespace proving the cluster has egress.
					})

					PIt("lets a probe in an opted-out namespace reach others, and follows a live label flip without restarting the pod", func() {
						// Flip policy.giantswarm.io/default-deny on a namespace holding a
						// running probe and assert the same pod's result changes.
					})

					PIt("breaks DNS in an unannotated customer namespace while allowDNS is off, and keeps it in kube-system and giantswarm; allow-dns restores it", func() {
					})

					PIt("keeps DNS working in an unannotated customer namespace and in kube-system/giantswarm when allowDNS is on", func() {
						// Needs a second suite or a values flip: allowDNS.enabled: true.
					})

					PIt("denies same-namespace traffic in an unannotated namespace unless allow-same-namespace is set", func() {
					})

					PIt("grants the matching standard allow for each of the six generation annotations and removes it when the annotation is removed", func() {
						// allow-same-namespace, allow-kube-apiserver, allow-webhook-ingress,
						// allow-ingress-controller, allow-metrics-scraping, allow-dns.
					})

					PIt("matches today's behaviour when the clusterwide deny is disabled (per-namespace default-deny-all in kube-system/giantswarm, customer namespaces unaffected)", func() {
						// Needs a values flip or a separate suite with the key set to false.
					})

					PIt("keeps Giant Swarm components healthy with the clusterwide deny on", func() {
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

			deleteNamespaces(ctx, wcClient, deniedNamespace, controlNamespace, targetNamespace)
		}).
		Run(t, "Clusterwide Deny Test")
}
