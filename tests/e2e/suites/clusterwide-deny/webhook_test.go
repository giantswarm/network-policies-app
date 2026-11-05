package clusterwidedeny

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	. "github.com/onsi/gomega"

	"github.com/giantswarm/clustertest/v5/pkg/client"
	"github.com/giantswarm/clustertest/v5/pkg/logger"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	cr "sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	// webhookName names the listener pod, its Service and the
	// ValidatingWebhookConfiguration.
	webhookName = "cwd-e2e-webhook"
	// webhookPort is one of the ports of the standard allow-webhook-ingress
	// (443, 4443, 8443, 9443, 10250).
	webhookPort = 8443
	// webhookCallsFile counts the connections the listener accepted, one line
	// each.
	webhookCallsFile = "/tmp/webhook-calls"
	// webhookTimeoutSeconds bounds how long the API server waits for the
	// webhook. failurePolicy Ignore lets the request through after that, so a
	// blocked webhook only slows down ConfigMap creation in webhookNamespace.
	webhookTimeoutSeconds = 3
)

// ensureWebhookListener makes sure webhookNamespace holds a pod that accepts
// TCP connections on webhookPort and records each one in webhookCallsFile,
// plus a Service in front of it. The listener closes every connection right
// away: only the arrival of the API server's connection is under test, not the
// TLS handshake or the AdmissionReview. It has no readiness probe, since the
// kubelet's probe connections would be counted as calls.
func ensureWebhookListener(ctx context.Context, wcClient *client.Client) {
	script := fmt.Sprintf(`cat > /tmp/r.sh <<'EOF'
#!/bin/sh
echo . >> %s
EOF
chmod 755 /tmp/r.sh
exec nc -lk -p %d -e /tmp/r.sh`, webhookCallsFile, webhookPort)
	ensurePod(ctx, wcClient, webhookNamespace, webhookName, []string{"sh", "-c", script}, 0)

	// The suite gives every pod only the owner label, and the listener is the
	// only pod in webhookNamespace, so the owner label selects it.
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webhookName,
			Namespace: webhookNamespace,
			Labels:    map[string]string{ownerLabelKey: ownerLabelValue},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{ownerLabelKey: ownerLabelValue},
			Ports: []corev1.ServicePort{{
				Port:       webhookPort,
				TargetPort: intstr.FromInt32(webhookPort),
				Protocol:   corev1.ProtocolTCP,
			}},
		},
	}
	err := wcClient.Create(ctx, service)
	if err != nil && !apierrors.IsAlreadyExists(err) {
		Expect(err).NotTo(HaveOccurred())
	}
}

// webhookConfiguration calls the listener for every ConfigMap CREATE in
// webhookNamespace and nowhere else. failurePolicy Ignore keeps a blocked or
// failing call from rejecting the ConfigMap.
func webhookConfiguration() *admissionregistrationv1.ValidatingWebhookConfiguration {
	failurePolicy := admissionregistrationv1.Ignore
	sideEffects := admissionregistrationv1.SideEffectClassNone
	timeout := int32(webhookTimeoutSeconds)
	port := int32(webhookPort)
	path := "/validate"
	scope := admissionregistrationv1.NamespacedScope

	return &admissionregistrationv1.ValidatingWebhookConfiguration{
		ObjectMeta: metav1.ObjectMeta{
			Name:   webhookName,
			Labels: map[string]string{ownerLabelKey: ownerLabelValue},
		},
		Webhooks: []admissionregistrationv1.ValidatingWebhook{{
			Name:                    "probe.cwd-e2e.giantswarm.io",
			AdmissionReviewVersions: []string{"v1"},
			SideEffects:             &sideEffects,
			FailurePolicy:           &failurePolicy,
			TimeoutSeconds:          &timeout,
			ClientConfig: admissionregistrationv1.WebhookClientConfig{
				Service: &admissionregistrationv1.ServiceReference{
					Name:      webhookName,
					Namespace: webhookNamespace,
					Port:      &port,
					Path:      &path,
				},
			},
			NamespaceSelector: &metav1.LabelSelector{
				MatchLabels: map[string]string{corev1.LabelMetadataName: webhookNamespace},
			},
			Rules: []admissionregistrationv1.RuleWithOperations{{
				Operations: []admissionregistrationv1.OperationType{admissionregistrationv1.Create},
				Rule: admissionregistrationv1.Rule{
					APIGroups:   []string{""},
					APIVersions: []string{"v1"},
					Resources:   []string{"configmaps"},
					Scope:       &scope,
				},
			}},
		}},
	}
}

// ensureWebhookConfiguration creates the ValidatingWebhookConfiguration, or
// leaves a suite-owned one from an earlier run in place. One that is not
// owned by the suite fails the test.
func ensureWebhookConfiguration(ctx context.Context, wcClient *client.Client) {
	err := wcClient.Create(ctx, webhookConfiguration())
	if err == nil {
		return
	}
	Expect(apierrors.IsAlreadyExists(err)).To(BeTrue(), "failed to create the ValidatingWebhookConfiguration %s: %v", webhookName, err)

	existing := &admissionregistrationv1.ValidatingWebhookConfiguration{}
	Expect(wcClient.Get(ctx, cr.ObjectKey{Name: webhookName}, existing)).To(Succeed())
	Expect(existing.Labels[ownerLabelKey]).To(Equal(ownerLabelValue), "the ValidatingWebhookConfiguration %s already exists and is not owned by this suite", webhookName)
}

// deleteWebhookConfiguration removes the suite's ValidatingWebhookConfiguration.
// Best effort: it only logs, so it can run from the AfterSuite too.
func deleteWebhookConfiguration(ctx context.Context, wcClient *client.Client) {
	existing := &admissionregistrationv1.ValidatingWebhookConfiguration{}
	err := wcClient.Get(ctx, cr.ObjectKey{Name: webhookName}, existing)
	if apierrors.IsNotFound(err) {
		return
	}
	if err != nil {
		logger.Log("Failed to get the ValidatingWebhookConfiguration %s for cleanup: %s", webhookName, err)
		return
	}
	if existing.Labels[ownerLabelKey] != ownerLabelValue {
		logger.Log("Not deleting the ValidatingWebhookConfiguration %s, it is not owned by this suite", webhookName)
		return
	}
	if err := cr.IgnoreNotFound(wcClient.Delete(ctx, existing)); err != nil {
		logger.Log("Failed to delete the ValidatingWebhookConfiguration %s: %s", webhookName, err)
	}
}

// webhookCalls returns how many connections the listener has accepted so far.
func webhookCalls(ctx context.Context, wcClient *client.Client) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, execTimeout)
	defer cancel()

	script := fmt.Sprintf(`if [ -f %[1]s ]; then wc -l < %[1]s; else echo 0; fi`, webhookCallsFile)
	stdout, stderr, err := wcClient.ExecInPod(ctx, webhookName, webhookNamespace, probeContainerName, []string{"sh", "-c", script})
	if err != nil {
		return 0, fmt.Errorf("failed to read the webhook calls in %s/%s: %w (stderr: %q)", webhookNamespace, webhookName, err, stderr)
	}
	calls, err := strconv.Atoi(strings.TrimSpace(stdout))
	if err != nil {
		return 0, fmt.Errorf("unexpected webhook call count %q from %s/%s: %w", stdout, webhookNamespace, webhookName, err)
	}
	return calls, nil
}

// webhookReached creates a ConfigMap in webhookNamespace and reports whether
// the API server's webhook call reached the listener. The exec that reads the
// count goes through the API server and the kubelet, so it is not subject to
// the pod's network policy.
func webhookReached(ctx context.Context, wcClient *client.Client) (bool, error) {
	before, err := webhookCalls(ctx, wcClient)
	if err != nil {
		return false, err
	}

	// Create returns once the API server has called the webhook, or given up
	// after webhookTimeoutSeconds when the connection is dropped.
	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: "webhook-probe-",
			Namespace:    webhookNamespace,
			Labels:       map[string]string{ownerLabelKey: ownerLabelValue},
		},
		Data: map[string]string{"probe": "webhook"},
	}
	if err := wcClient.Create(ctx, configMap); err != nil {
		return false, fmt.Errorf("failed to create a ConfigMap in %s: %w", webhookNamespace, err)
	}
	// The listener records a connection right after accepting it; give the
	// write a moment to land.
	time.Sleep(time.Second)

	after, err := webhookCalls(ctx, wcClient)
	if err != nil {
		return false, err
	}
	logger.Log("Webhook probe in %s: %d connection(s) for one ConfigMap CREATE", webhookNamespace, after-before)
	if after < before {
		return false, fmt.Errorf("the webhook call count in %s/%s went down from %d to %d: the listener restarted", webhookNamespace, webhookName, before, after)
	}
	return after > before, nil
}

// expectWebhook asserts whether the API server's webhook call reaches the
// listener. Same rules as expectReachability: a negative result must hold for
// 30s.
func expectWebhook(ctx context.Context, wcClient *client.Client, want bool, within time.Duration) {
	expectState(func() (bool, error) { return webhookReached(ctx, wcClient) },
		fmt.Sprintf("the API server's webhook call to %s/%s", webhookNamespace, webhookName), want, within, 30*time.Second)
}
