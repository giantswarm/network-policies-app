package basic

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	helmv2 "github.com/fluxcd/helm-controller/api/v2"
	"github.com/giantswarm/apptest-framework/v5/pkg/state"
	"github.com/giantswarm/apptest-framework/v5/pkg/suite"
	"github.com/giantswarm/clustertest/v5/pkg/client"
	"github.com/giantswarm/clustertest/v5/pkg/logger"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	cr "sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	isUpgrade = false

	installNamespace = "kube-system"

	policyName = "deny-egress-to-imds"

	imdsAddress = "169.254.169.254"
	imdsPort    = 80

	// Namespaces created by this suite. The policy applies to deniedNamespace,
	// while the other two are exempt: one by name, which must match the
	// excludedNamespaces entry in values.yaml, and one by the namespace label
	// configured in excludedNamespaceLabels.
	deniedNamespace      = "imds-e2e-denied"
	nameExemptNamespace  = "imds-e2e-name-exempt"
	labelExemptNamespace = "imds-e2e-label-exempt"

	exemptLabelKey   = "policy.giantswarm.io/allow-imds"
	exemptLabelValue = "true"

	probePodName       = "imds-probe"
	probeContainerName = "probe"
	probeImage         = "gsoci.azurecr.io/giantswarm/alpine:latest"

	// The API server Service, reached through cluster DNS. Used to prove that
	// in-cluster egress and DNS still work while IMDS is denied.
	inClusterHost = "kubernetes.default.svc.cluster.local"
	inClusterPort = 443
)

var ccnpGVK = schema.GroupVersionKind{
	Group:   "cilium.io",
	Version: "v2",
	Kind:    "CiliumClusterwideNetworkPolicy",
}

// clusterwidePolicy mirrors only the parts of the CiliumClusterwideNetworkPolicy
// this suite asserts on, so the tests don't need to pull in the Cilium API module.
type clusterwidePolicy struct {
	Spec struct {
		EndpointSelector struct {
			MatchExpressions []struct {
				Key      string   `json:"key"`
				Operator string   `json:"operator"`
				Values   []string `json:"values"`
			} `json:"matchExpressions"`
		} `json:"endpointSelector"`
		EnableDefaultDeny struct {
			Egress *bool `json:"egress"`
		} `json:"enableDefaultDeny"`
		EgressDeny []struct {
			ToCIDR []string `json:"toCIDR"`
		} `json:"egressDeny"`
	} `json:"spec"`
	Status struct {
		Conditions []struct {
			Type    string `json:"type"`
			Status  string `json:"status"`
			Message string `json:"message"`
		} `json:"conditions"`
	} `json:"status"`
}

func TestBasic(t *testing.T) {
	suite.New().
		WithInstallNamespace(installNamespace).
		WithIsUpgrade(isUpgrade).
		WithValuesFile("./values.yaml").
		Tests(func() {
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

			It("should create the deny-egress-to-imds policy and have Cilium accept it", func() {
				ctx := state.GetContext()
				wcClient := workloadClusterClient()

				var policy clusterwidePolicy
				Eventually(func() error {
					var err error
					policy, err = getClusterwidePolicy(ctx, wcClient, policyName)
					return err
				}).
					WithTimeout(5 * time.Minute).
					WithPolling(15 * time.Second).
					Should(Succeed())

				By("denying egress to the IMDS address")
				deniedCIDRs := []string{}
				for _, rule := range policy.Spec.EgressDeny {
					deniedCIDRs = append(deniedCIDRs, rule.ToCIDR...)
				}
				Expect(deniedCIDRs).To(ContainElement(fmt.Sprintf("%s/32", imdsAddress)))

				By("leaving egress default deny disabled")
				// This is what keeps the policy's blast radius to IMDS alone. Without
				// it every endpoint in the cluster enters egress default-deny mode.
				Expect(policy.Spec.EnableDefaultDeny.Egress).NotTo(BeNil())
				Expect(*policy.Spec.EnableDefaultDeny.Egress).To(BeFalse())

				By("excluding the platform namespaces and the configured exemptions")
				excluded := map[string][]string{}
				for _, expression := range policy.Spec.EndpointSelector.MatchExpressions {
					Expect(expression.Operator).To(Equal("NotIn"))
					excluded[expression.Key] = expression.Values
				}
				Expect(excluded).To(HaveKey("io.kubernetes.pod.namespace"))
				Expect(excluded["io.kubernetes.pod.namespace"]).To(ContainElements(installNamespace, "giantswarm", nameExemptNamespace))
				Expect(excluded).To(HaveKey(fmt.Sprintf("io.cilium.k8s.namespace.labels.%s", exemptLabelKey)))
				Expect(excluded[fmt.Sprintf("io.cilium.k8s.namespace.labels.%s", exemptLabelKey)]).To(ContainElement(exemptLabelValue))

				By("being marked as valid by Cilium")
				Eventually(func() (string, error) {
					current, err := getClusterwidePolicy(ctx, wcClient, policyName)
					if err != nil {
						return "", err
					}
					for _, condition := range current.Status.Conditions {
						if condition.Type == "Valid" {
							logger.Log("Policy %q Valid=%s: %s", policyName, condition.Status, condition.Message)
							return condition.Status, nil
						}
					}
					return "", fmt.Errorf("policy %q has no Valid condition yet", policyName)
				}).
					WithTimeout(2 * time.Minute).
					WithPolling(10 * time.Second).
					Should(Equal("True"))
			})

			It("should block egress to IMDS from a namespace the policy applies to", func() {
				ctx := state.GetContext()
				wcClient := workloadClusterClient()

				ensureProbePod(ctx, wcClient, deniedNamespace, nil)

				Eventually(func() (bool, error) {
					return tcpReachable(ctx, wcClient, deniedNamespace, imdsAddress, imdsPort)
				}).
					WithTimeout(3*time.Minute).
					WithPolling(15*time.Second).
					Should(BeFalse(), "expected IMDS to be unreachable from %s", deniedNamespace)
			})

			It("should leave all other egress from that namespace working", func() {
				ctx := state.GetContext()
				wcClient := workloadClusterClient()

				ensureProbePod(ctx, wcClient, deniedNamespace, nil)

				// A pure deny policy must not put the endpoint into default-deny mode.
				// If it did, these would fail while the IMDS probe above still passed,
				// so this is the assertion that actually pins down the behaviour.
				By("resolving cluster DNS")
				Eventually(func() (bool, error) {
					return dnsResolves(ctx, wcClient, deniedNamespace, inClusterHost)
				}).
					WithTimeout(2*time.Minute).
					WithPolling(10*time.Second).
					Should(BeTrue(), "expected cluster DNS to keep working in %s", deniedNamespace)

				By("reaching the API server Service")
				Eventually(func() (bool, error) {
					return tcpReachable(ctx, wcClient, deniedNamespace, inClusterHost, inClusterPort)
				}).
					WithTimeout(2*time.Minute).
					WithPolling(10*time.Second).
					Should(BeTrue(), "expected in-cluster egress to keep working in %s", deniedNamespace)
			})

			It("should allow egress to IMDS from a namespace excluded by name", func() {
				ctx := state.GetContext()
				wcClient := workloadClusterClient()

				ensureProbePod(ctx, wcClient, nameExemptNamespace, nil)

				Eventually(func() (bool, error) {
					return tcpReachable(ctx, wcClient, nameExemptNamespace, imdsAddress, imdsPort)
				}).
					WithTimeout(3*time.Minute).
					WithPolling(15*time.Second).
					Should(BeTrue(), "expected IMDS to stay reachable from %s", nameExemptNamespace)
			})

			It("should allow egress to IMDS from a namespace excluded by label", func() {
				ctx := state.GetContext()
				wcClient := workloadClusterClient()

				ensureProbePod(ctx, wcClient, labelExemptNamespace, map[string]string{exemptLabelKey: exemptLabelValue})

				Eventually(func() (bool, error) {
					return tcpReachable(ctx, wcClient, labelExemptNamespace, imdsAddress, imdsPort)
				}).
					WithTimeout(3*time.Minute).
					WithPolling(15*time.Second).
					Should(BeTrue(), "expected IMDS to stay reachable from %s", labelExemptNamespace)
			})
		}).
		AfterSuite(func() {
			ctx := state.GetContext()
			wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
			if err != nil {
				// The workload cluster is about to be deleted anyway, so a client we
				// can't build is not worth failing the suite over.
				logger.Log("Skipping namespace cleanup, no workload cluster client: %s", err)
				return
			}

			for _, name := range []string{deniedNamespace, nameExemptNamespace, labelExemptNamespace} {
				By(fmt.Sprintf("Deleting namespace %s", name))
				namespace := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name}}
				Expect(cr.IgnoreNotFound(wcClient.Delete(ctx, namespace))).NotTo(HaveOccurred())
			}
		}).
		Run(t, "Basic Test")
}

func workloadClusterClient() *client.Client {
	wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
	Expect(err).NotTo(HaveOccurred())
	return wcClient
}

func getClusterwidePolicy(ctx context.Context, wcClient *client.Client, name string) (clusterwidePolicy, error) {
	object := &unstructured.Unstructured{}
	object.SetGroupVersionKind(ccnpGVK)

	if err := wcClient.Get(ctx, types.NamespacedName{Name: name}, object); err != nil {
		return clusterwidePolicy{}, err
	}

	policy := clusterwidePolicy{}
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &policy); err != nil {
		return clusterwidePolicy{}, fmt.Errorf("failed to parse policy %q: %w", name, err)
	}

	return policy, nil
}

// ensureProbePod makes sure the given namespace exists, carries the given
// labels, and holds a running pod that the connectivity probes can exec into.
// Namespace labels are part of a pod's Cilium identity, so they are applied
// before the pod is created.
func ensureProbePod(ctx context.Context, wcClient *client.Client, namespace string, labels map[string]string) {
	ensureNamespace(ctx, wcClient, namespace, labels)

	nonRoot := true
	allowPrivilegeEscalation := false
	userAndGroup := int64(35)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      probePodName,
			Namespace: namespace,
		},
		Spec: corev1.PodSpec{
			SecurityContext: &corev1.PodSecurityContext{
				RunAsUser:    &userAndGroup,
				RunAsGroup:   &userAndGroup,
				RunAsNonRoot: &nonRoot,
				SeccompProfile: &corev1.SeccompProfile{
					Type: corev1.SeccompProfileTypeRuntimeDefault,
				},
			},
			Containers: []corev1.Container{
				{
					Name:  probeContainerName,
					Image: probeImage,
					Args:  []string{"sleep", "99999999"},
					SecurityContext: &corev1.SecurityContext{
						AllowPrivilegeEscalation: &allowPrivilegeEscalation,
						Capabilities: &corev1.Capabilities{
							Drop: []corev1.Capability{"ALL"},
						},
					},
				},
			},
		},
	}

	err := wcClient.Create(ctx, pod)
	if err != nil && !apierrors.IsAlreadyExists(err) {
		Expect(err).NotTo(HaveOccurred())
	}

	Eventually(func() (corev1.PodPhase, error) {
		running := &corev1.Pod{}
		if err := wcClient.Get(ctx, cr.ObjectKeyFromObject(pod), running); err != nil {
			return "", err
		}
		return running.Status.Phase, nil
	}).
		WithTimeout(5*time.Minute).
		WithPolling(5*time.Second).
		Should(Equal(corev1.PodRunning), "expected the probe pod in %s to be running", namespace)
}

func ensureNamespace(ctx context.Context, wcClient *client.Client, name string, labels map[string]string) {
	namespace := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name:   name,
			Labels: labels,
		},
	}

	err := wcClient.Create(ctx, namespace)
	if err == nil {
		return
	}
	if !apierrors.IsAlreadyExists(err) {
		Expect(err).NotTo(HaveOccurred())
	}

	if len(labels) == 0 {
		return
	}

	existing := &corev1.Namespace{}
	Expect(wcClient.Get(ctx, cr.ObjectKeyFromObject(namespace), existing)).To(Succeed())
	if existing.Labels == nil {
		existing.Labels = map[string]string{}
	}
	for key, value := range labels {
		existing.Labels[key] = value
	}
	Expect(wcClient.Update(ctx, existing)).To(Succeed())
}

// tcpReachable reports whether the probe pod can open a TCP connection to
// host:port. The policy denies at L3, so a TCP connect is enough to tell
// allowed from denied, and it avoids depending on IMDSv2 request semantics.
func tcpReachable(ctx context.Context, wcClient *client.Client, namespace, host string, port int) (bool, error) {
	output, err := runProbe(ctx, wcClient, namespace,
		fmt.Sprintf("nc -w 3 %s %d < /dev/null", host, port))
	if err != nil {
		return false, err
	}

	logger.Log("TCP probe from %s to %s:%d: %s", namespace, host, port, output)

	return output == "OK", nil
}

func dnsResolves(ctx context.Context, wcClient *client.Client, namespace, host string) (bool, error) {
	output, err := runProbe(ctx, wcClient, namespace, fmt.Sprintf("nslookup %s", host))
	if err != nil {
		return false, err
	}

	logger.Log("DNS probe from %s for %s: %s", namespace, host, output)

	return output == "OK", nil
}

// runProbe execs a command in the probe pod and reports whether it succeeded.
// The command's own exit code is swallowed on purpose: ExecInPod turns a
// non-zero exit into an error, which would be indistinguishable from a broken
// exec, and a denied connection is an expected outcome here rather than a
// failure.
func runProbe(ctx context.Context, wcClient *client.Client, namespace, command string) (string, error) {
	script := fmt.Sprintf("if %s > /dev/null 2>&1; then echo OK; else echo FAILED; fi", command)

	stdout, stderr, err := wcClient.ExecInPod(ctx, probePodName, namespace, probeContainerName, []string{"sh", "-c", script})
	if err != nil {
		return "", fmt.Errorf("failed to run probe in %s/%s: %w (stderr: %q)", namespace, probePodName, err, stderr)
	}

	output := strings.TrimSpace(stdout)
	if output != "OK" && output != "FAILED" {
		return "", fmt.Errorf("unexpected probe output %q (stderr: %q)", output, stderr)
	}

	return output, nil
}
