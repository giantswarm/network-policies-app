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

	// Namespace opt-out label, see the PRD. Provisional until agreed with Shield.
	optOutLabelKey = "policy.giantswarm.io/default-deny"

	// ownerLabelKey marks namespaces created by this suite; only those are
	// ever modified or deleted by it.
	ownerLabelKey   = "e2e.giantswarm.io/owner"
	ownerLabelValue = "network-policies-app-clusterwide-deny"

	// probeTimeoutSeconds is how long a probe waits for a connection.
	probeTimeoutSeconds = 3
)

// outcome is the classified result of one probe.
type outcome string

const (
	// outcomeReachable means the HTTP request to the target succeeded.
	outcomeReachable outcome = "reachable"
	// outcomeTimeout means the connection attempt timed out: packets were
	// silently dropped, which is what a deny policy does.
	outcomeTimeout outcome = "timeout"
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

// ensureNamespace creates the namespace with exactly the given labels (plus
// the owner label), or reconciles an existing one suite-owned namespace to
// them. The opt-out label is removed when it is not in labels. Namespaces not
// carrying the owner label, or already terminating, fail the test.
func ensureNamespace(ctx context.Context, wcClient *client.Client, name string, labels map[string]string) {
	want := map[string]string{ownerLabelKey: ownerLabelValue}
	for key, value := range labels {
		want[key] = value
	}

	namespace := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: want}}
	err := wcClient.Create(ctx, namespace)
	if err == nil {
		return
	}
	Expect(apierrors.IsAlreadyExists(err)).To(BeTrue(), "unexpected error creating namespace %s: %v", name, err)

	// Retry on conflicts: Kyverno and other controllers also write namespaces.
	Eventually(func() error {
		existing := &corev1.Namespace{}
		if err := wcClient.Get(ctx, cr.ObjectKey{Name: name}, existing); err != nil {
			return err
		}
		if existing.DeletionTimestamp != nil || existing.Status.Phase == corev1.NamespaceTerminating {
			return StopTrying(fmt.Sprintf("namespace %s is terminating, a previous run has not finished cleaning up", name))
		}
		if existing.Labels[ownerLabelKey] != ownerLabelValue {
			return StopTrying(fmt.Sprintf("namespace %s already exists and is not owned by this suite", name))
		}
		if existing.Labels == nil {
			existing.Labels = map[string]string{}
		}
		for key, value := range want {
			existing.Labels[key] = value
		}
		if _, wanted := want[optOutLabelKey]; !wanted {
			delete(existing.Labels, optOutLabelKey)
		}
		return wcClient.Update(ctx, existing)
	}).
		WithTimeout(30 * time.Second).
		WithPolling(time.Second).
		Should(Succeed())
}

// ensureProbePod makes sure the namespace holds a Ready pod that the
// reachability helpers can exec into.
func ensureProbePod(ctx context.Context, wcClient *client.Client, namespace string) {
	ensurePod(ctx, wcClient, namespace, probePodName, []string{"sleep", "99999999"})
}

// ensureListenerPod makes sure the namespace holds a Ready pod serving HTTP
// on listenerPort and returns its IP, the target for cross-namespace probes.
// It uses a persistent server (busybox httpd) so that every connection is
// accepted, unlike a restarting one-shot nc listener.
func ensureListenerPod(ctx context.Context, wcClient *client.Client, namespace string) probeTarget {
	script := fmt.Sprintf("mkdir -p /tmp/www && echo ok > /tmp/www/index.html && exec httpd -f -p %d -h /tmp/www", listenerPort)
	ensurePod(ctx, wcClient, namespace, listenerPodName, []string{"sh", "-c", script})

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

	Eventually(func() (bool, error) {
		current := &corev1.Pod{}
		if err := wcClient.Get(ctx, cr.ObjectKeyFromObject(pod), current); err != nil {
			return false, err
		}
		for _, c := range current.Status.Conditions {
			if c.Type == corev1.PodReady {
				return c.Status == corev1.ConditionTrue, nil
			}
		}
		return false, nil
	}).
		WithTimeout(5*time.Minute).
		WithPolling(5*time.Second).
		Should(BeTrue(), "expected pod %s/%s to be Ready", namespace, name)
}

// expectReachability asserts whether the probe in fromNamespace can reach the
// target. For want == false only a connection timeout counts as blocked
// (a deny policy drops packets); a refused connection or any other error is
// reported as an error so the target being down cannot pass as "blocked".
// A negative result must then hold for 30s, so a single dropped packet or a
// policy that is not yet programmed cannot produce a pass.
func expectReachability(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget, want bool) {
	probe := func() (bool, error) {
		result, err := probeHTTP(ctx, wcClient, fromNamespace, target)
		if err != nil {
			return false, err
		}
		return result == outcomeReachable, nil
	}

	description := "unreachable"
	if want {
		description = "reachable"
	}

	Eventually(probe).
		WithTimeout(3*time.Minute).
		WithPolling(10*time.Second).
		Should(Equal(want), "expected %s to be %s from %s", target, description, fromNamespace)

	if !want {
		Consistently(probe).
			WithTimeout(30*time.Second).
			WithPolling(5*time.Second).
			Should(BeFalse(), "expected %s to stay unreachable from %s", target, fromNamespace)
	}
}

// probeHTTP issues one HTTP request from the probe pod in fromNamespace to the
// target and classifies the result as reachable or timeout. A refused
// connection or any other failure returns an error.
func probeHTTP(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget) (outcome, error) {
	// The exit code of wget is captured on purpose: a denied connection is an
	// expected outcome, not an exec failure. stderr distinguishes a timeout
	// (silent drop) from a refusal (target down or reset).
	script := fmt.Sprintf(`out=$(wget -q -T %d -O /dev/null http://%s:%d/ 2>&1); rc=$?; echo "$rc"; echo "$out"`,
		probeTimeoutSeconds, target.Host, target.Port)

	stdout, stderr, err := wcClient.ExecInPod(ctx, probePodName, fromNamespace, probeContainerName, []string{"sh", "-c", script})
	if err != nil {
		return "", fmt.Errorf("failed to run probe in %s/%s: %w (stderr: %q)", fromNamespace, probePodName, err, stderr)
	}

	code, detail, _ := strings.Cut(strings.TrimSpace(stdout), "\n")
	detail = strings.TrimSpace(detail)
	logger.Log("HTTP probe from %s to %s: exit=%s %s", fromNamespace, target, code, detail)

	if code == "0" {
		return outcomeReachable, nil
	}

	lower := strings.ToLower(detail)
	if strings.Contains(lower, "timed out") || strings.Contains(lower, "timeout") {
		return outcomeTimeout, nil
	}
	return "", fmt.Errorf("probe from %s to %s failed without timing out (not counted as blocked): exit=%s %q", fromNamespace, target, code, detail)
}

// deleteNamespaces removes the suite's namespaces, ignoring ones already gone
// and skipping any that do not carry the owner label.
func deleteNamespaces(ctx context.Context, wcClient *client.Client, names ...string) {
	for _, name := range names {
		namespace := &corev1.Namespace{}
		err := wcClient.Get(ctx, cr.ObjectKey{Name: name}, namespace)
		if apierrors.IsNotFound(err) {
			continue
		}
		Expect(err).NotTo(HaveOccurred())
		if namespace.Labels[ownerLabelKey] != ownerLabelValue {
			logger.Log("Not deleting namespace %s, it is not owned by this suite", name)
			continue
		}

		By(fmt.Sprintf("Deleting namespace %s", name))
		Expect(cr.IgnoreNotFound(wcClient.Delete(ctx, namespace))).NotTo(HaveOccurred())
	}
}
