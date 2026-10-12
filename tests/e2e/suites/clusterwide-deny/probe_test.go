package clusterwidedeny

import (
	"context"
	"fmt"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/giantswarm/apptest-framework/v5/pkg/state"
	"github.com/giantswarm/clustertest/v5/pkg/client"
	"github.com/giantswarm/clustertest/v5/pkg/logger"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	cr "sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	probePodName       = "probe"
	probeContainerName = "probe"
	listenerPodName    = "listener"
	listenerPort       = 8080
	probeImage         = "gsoci.azurecr.io/giantswarm/alpine:latest"

	// inClusterHost is used to tell a DNS failure from a connectivity failure.
	inClusterHost = "kubernetes.default.svc.cluster.local"

	// Namespace opt-out label and generation annotations, see the PRD.
	// Provisional until agreed with Shield.
	optOutLabelKey = "policy.giantswarm.io/default-deny"
)

// probeTarget is where a probe connects to: a host (name or IP) and a TCP port.
type probeTarget struct {
	Host string
	Port int
}

func (t probeTarget) String() string { return fmt.Sprintf("%s:%d", t.Host, t.Port) }

func workloadClusterClient() *client.Client {
	wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
	Expect(err).NotTo(HaveOccurred())
	return wcClient
}

// ensureNamespace creates the namespace with the given labels and annotations,
// or merges them into an existing one. Labels are part of a pod's Cilium
// identity, so set them before creating pods.
func ensureNamespace(ctx context.Context, wcClient *client.Client, name string, labels, annotations map[string]string) {
	namespace := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels, Annotations: annotations},
	}

	err := wcClient.Create(ctx, namespace)
	if err == nil {
		return
	}
	Expect(apierrors.IsAlreadyExists(err)).To(BeTrue(), "unexpected error creating namespace %s: %v", name, err)

	for key, value := range labels {
		setNamespaceLabel(ctx, wcClient, name, key, &value)
	}
	for key, value := range annotations {
		setNamespaceAnnotation(ctx, wcClient, name, key, &value)
	}
}

// setNamespaceLabel sets (value != nil) or removes (value == nil) a namespace
// label without touching pods, so a running probe sees the change live.
func setNamespaceLabel(ctx context.Context, wcClient *client.Client, name, key string, value *string) {
	updateNamespace(ctx, wcClient, name, func(ns *corev1.Namespace) {
		ns.Labels = mutateMap(ns.Labels, key, value)
	})
}

// setNamespaceAnnotation sets (value != nil) or removes (value == nil) a
// namespace annotation, e.g. a generation annotation.
func setNamespaceAnnotation(ctx context.Context, wcClient *client.Client, name, key string, value *string) {
	updateNamespace(ctx, wcClient, name, func(ns *corev1.Namespace) {
		ns.Annotations = mutateMap(ns.Annotations, key, value)
	})
}

func mutateMap(m map[string]string, key string, value *string) map[string]string {
	if m == nil {
		m = map[string]string{}
	}
	if value == nil {
		delete(m, key)
	} else {
		m[key] = *value
	}
	return m
}

func updateNamespace(ctx context.Context, wcClient *client.Client, name string, mutate func(*corev1.Namespace)) {
	// Retry on conflicts: Kyverno and other controllers also write namespaces.
	Eventually(func() error {
		ns := &corev1.Namespace{}
		if err := wcClient.Get(ctx, cr.ObjectKey{Name: name}, ns); err != nil {
			return err
		}
		mutate(ns)
		return wcClient.Update(ctx, ns)
	}).
		WithTimeout(30 * time.Second).
		WithPolling(time.Second).
		Should(Succeed())
}

// ensureProbePod makes sure the namespace holds a running pod that the
// reachability helpers can exec into.
func ensureProbePod(ctx context.Context, wcClient *client.Client, namespace string) {
	ensurePod(ctx, wcClient, namespace, probePodName, []string{"sleep", "99999999"})
}

// ensureListenerPod makes sure the namespace holds a running pod listening on
// listenerPort and returns its IP, the target for cross-namespace probes.
func ensureListenerPod(ctx context.Context, wcClient *client.Client, namespace string) probeTarget {
	ensurePod(ctx, wcClient, namespace, listenerPodName,
		[]string{"sh", "-c", fmt.Sprintf("while true; do nc -l -p %d > /dev/null; done", listenerPort)})

	pod := &corev1.Pod{}
	Expect(wcClient.Get(ctx, cr.ObjectKey{Namespace: namespace, Name: listenerPodName}, pod)).To(Succeed())
	Expect(pod.Status.PodIP).NotTo(BeEmpty())

	return probeTarget{Host: pod.Status.PodIP, Port: listenerPort}
}

func ensurePod(ctx context.Context, wcClient *client.Client, namespace, name string, args []string) {
	nonRoot := true
	allowPrivilegeEscalation := false
	userAndGroup := int64(35)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
		Spec: corev1.PodSpec{
			SecurityContext: &corev1.PodSecurityContext{
				RunAsUser:      &userAndGroup,
				RunAsGroup:     &userAndGroup,
				RunAsNonRoot:   &nonRoot,
				SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault},
			},
			Containers: []corev1.Container{{
				Name:  probeContainerName,
				Image: probeImage,
				Args:  args,
				SecurityContext: &corev1.SecurityContext{
					AllowPrivilegeEscalation: &allowPrivilegeEscalation,
					Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
				},
			}},
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
		Should(Equal(corev1.PodRunning), "expected pod %s/%s to be running", namespace, name)
}

// tcpReachable reports whether the probe pod in fromNamespace can open a TCP
// connection to the target.
func tcpReachable(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget) (bool, error) {
	output, err := runProbe(ctx, wcClient, fromNamespace, fmt.Sprintf("nc -w 3 %s %d < /dev/null", target.Host, target.Port))
	if err != nil {
		return false, err
	}
	logger.Log("TCP probe from %s to %s: %s", fromNamespace, target, output)
	return output == "OK", nil
}

// dnsResolves reports whether the probe pod in fromNamespace can resolve host.
func dnsResolves(ctx context.Context, wcClient *client.Client, fromNamespace, host string) (bool, error) {
	output, err := runProbe(ctx, wcClient, fromNamespace, fmt.Sprintf("nslookup %s", host))
	if err != nil {
		return false, err
	}
	logger.Log("DNS probe from %s for %s: %s", fromNamespace, host, output)
	return output == "OK", nil
}

// expectReachable waits until the probe in fromNamespace can reach the target.
func expectReachable(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget) {
	Eventually(func() (bool, error) {
		return tcpReachable(ctx, wcClient, fromNamespace, target)
	}).
		WithTimeout(3*time.Minute).
		WithPolling(10*time.Second).
		Should(BeTrue(), "expected %s to be reachable from %s", target, fromNamespace)
}

// expectNotReachable waits until the probe in fromNamespace cannot reach the
// target. Pair it with expectReachable on a control probe, or a "not
// reachable" result could just mean the target is down.
func expectNotReachable(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget) {
	Eventually(func() (bool, error) {
		return tcpReachable(ctx, wcClient, fromNamespace, target)
	}).
		WithTimeout(3*time.Minute).
		WithPolling(10*time.Second).
		Should(BeFalse(), "expected %s to be unreachable from %s", target, fromNamespace)
}

// runProbe execs a command in the probe pod and reports whether it succeeded.
// The command's exit code is swallowed on purpose: a denied connection is an
// expected outcome, not an exec failure.
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

// deleteNamespaces removes the suite's namespaces, ignoring ones already gone.
func deleteNamespaces(ctx context.Context, wcClient *client.Client, names ...string) {
	for _, name := range names {
		By(fmt.Sprintf("Deleting namespace %s", name))
		namespace := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name}}
		Expect(cr.IgnoreNotFound(wcClient.Delete(ctx, namespace))).NotTo(HaveOccurred())
	}
}
