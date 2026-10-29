package clusterwidedeny

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	. "github.com/onsi/gomega"

	"github.com/giantswarm/apptest-framework/v5/pkg/state"
	"github.com/giantswarm/clustertest/v5/pkg/client"
	"github.com/giantswarm/clustertest/v5/pkg/logger"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	cr "sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	probePodName       = "probe"
	probeContainerName = "probe"
	listenerPodName    = "listener"
	listenerPort       = 8080
	// Pinned: the probes depend on busybox applet output (wget, nslookup).
	// 3.18.3 ships busybox 1.36.1 and was checked for the messages parsed below.
	probeImage = "gsoci.azurecr.io/giantswarm/alpine:3.18.3"

	// Namespace opt-out label, see the PRD. Provisional until agreed with Shield.
	optOutLabelKey = "policy.giantswarm.io/default-deny"

	// Namespaces carrying policy.giantswarm.io/allow-<x>: "true" are selected by
	// the matching standard allow. There is no same-namespace label: that
	// traffic is opened by a Same-namespace policy (see sameNamespacePolicy).
	policyLabelPrefix        = "policy.giantswarm.io/"
	allowDNSLabelKey         = "policy.giantswarm.io/allow-dns"
	allowKubeAPIServerLabel  = "policy.giantswarm.io/allow-kube-apiserver"
	allowWebhookIngressLabel = "policy.giantswarm.io/allow-webhook-ingress"
	allowIngressCtrlLabel    = "policy.giantswarm.io/allow-ingress-controller"
	allowMetricsLabel        = "policy.giantswarm.io/allow-metrics-scraping"

	// labelTimeout bounds how long a label change may take to show up in
	// connectivity (measured up to ~48s, see the PRD).
	labelTimeout = 2 * time.Minute
	// dnsDescription names what the DNS probe resolves: kubernetes.default in
	// the cluster's own domain, read from the pod's resolv.conf search list.
	dnsDescription = "kubernetes.default.svc.<cluster domain>"

	// ownerLabelKey marks namespaces created by this suite; only those are
	// ever modified or deleted by it.
	ownerLabelKey   = "e2e.giantswarm.io/owner"
	ownerLabelValue = "network-policies-app-clusterwide-deny"

	// probeTimeoutSeconds is how long a probe waits for a connection.
	probeTimeoutSeconds = 3

	// execTimeout bounds one probe exec, connection wait included.
	execTimeout = 30 * time.Second
)

// errNoRoute marks a probe that got a refusal or an unreachable network. It is
// still an error for every reachability assertion; only the internet control
// uses it to tell a cluster without direct egress from a broken probe.
var errNoRoute = errors.New("connection refused or network unreachable")

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
// Scheme defaults to http and Path to /. HTTPSAnyAnswer is for targets that
// only need to prove the network path: it skips certificate verification and
// counts an HTTP error status (401, 403, 404...) as reachable, since any
// response means the packets got through.
type probeTarget struct {
	Host           string
	Port           int
	Scheme         string
	Path           string
	HTTPSAnyAnswer bool
}

func (t probeTarget) String() string { return fmt.Sprintf("%s:%d", t.Host, t.Port) }

func (t probeTarget) url() string {
	scheme, path := t.Scheme, t.Path
	if scheme == "" {
		scheme = "http"
	}
	if path == "" {
		path = "/"
	}
	return fmt.Sprintf("%s://%s:%d%s", scheme, t.Host, t.Port, path)
}

func workloadClusterClient() *client.Client {
	wcClient, err := state.GetFramework().WC(state.GetCluster().Name)
	Expect(err).NotTo(HaveOccurred())
	return wcClient
}

// ensureNamespace creates the namespace with the given labels (plus the owner
// label), or reconciles an existing suite-owned one to them. Only
// policy.giantswarm.io/* labels are pruned, so labels of other origins stay.
// A suite-owned namespace that is still terminating from a previous run is
// waited for (up to 2 minutes) and then recreated. A namespace not carrying
// the owner label fails the test.
func ensureNamespace(ctx context.Context, wcClient *client.Client, name string, labels map[string]string) {
	want := map[string]string{ownerLabelKey: ownerLabelValue}
	for key, value := range labels {
		want[key] = value
	}

	// Retry on conflicts: other controllers also write namespaces.
	Eventually(func() error {
		namespace := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: maps.Clone(want)}}
		err := wcClient.Create(ctx, namespace)
		if err == nil {
			return nil
		}
		if !apierrors.IsAlreadyExists(err) {
			return StopTrying(fmt.Sprintf("unexpected error creating namespace %s: %v", name, err))
		}

		existing := &corev1.Namespace{}
		if err := wcClient.Get(ctx, cr.ObjectKey{Name: name}, existing); err != nil {
			return err // gone in the meantime: the next attempt creates it
		}
		if existing.Labels[ownerLabelKey] != ownerLabelValue {
			return StopTrying(fmt.Sprintf("namespace %s already exists and is not owned by this suite", name))
		}
		if existing.DeletionTimestamp != nil || existing.Status.Phase == corev1.NamespaceTerminating {
			return fmt.Errorf("namespace %s is terminating from a previous run, waiting for it to disappear", name)
		}
		for key, value := range want {
			existing.Labels[key] = value
		}
		for key := range existing.Labels {
			if _, wanted := want[key]; !wanted && strings.HasPrefix(key, policyLabelPrefix) {
				delete(existing.Labels, key)
			}
		}
		return wcClient.Update(ctx, existing)
	}).
		WithTimeout(2 * time.Minute).
		WithPolling(2 * time.Second).
		Should(Succeed())
}

// ensureProbePod makes sure the namespace holds a Ready pod that the
// reachability helpers can exec into.
func ensureProbePod(ctx context.Context, wcClient *client.Client, namespace string) {
	ensurePod(ctx, wcClient, namespace, probePodName, []string{"sleep", "99999999"}, 0)
}

// ensureListenerPod makes sure the namespace holds a Ready pod serving a
// fixed HTTP response on listenerPort and returns its IP, the target for
// cross-namespace probes. The image has no httpd applet, so it uses a
// persistent busybox nc (-k) that runs a response script per connection
// (-e must come last).
func ensureListenerPod(ctx context.Context, wcClient *client.Client, namespace string) probeTarget {
	// The response script drains the request headers before answering:
	// closing a socket with unread data makes Linux send RST, which wget
	// reports as an error instead of a response.
	script := fmt.Sprintf(`cat > /tmp/r.sh <<'EOF'
#!/bin/sh
while IFS= read -r l; do
  [ "${#l}" -le 1 ] && break
done
printf 'HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nok\n'
EOF
chmod 755 /tmp/r.sh
exec nc -lk -p %d -e /tmp/r.sh`, listenerPort)
	ensurePod(ctx, wcClient, namespace, listenerPodName, []string{"sh", "-c", script}, listenerPort)

	pod := &corev1.Pod{}
	Expect(wcClient.Get(ctx, cr.ObjectKey{Namespace: namespace, Name: listenerPodName}, pod)).To(Succeed())
	Expect(pod.Status.PodIP).NotTo(BeEmpty())

	return probeTarget{Host: pod.Status.PodIP, Port: listenerPort}
}

// ensurePod creates the pod if needed and waits for it to be Ready. A non-zero
// readinessPort adds a TCP readiness probe, so Ready means the port is bound.
func ensurePod(ctx context.Context, wcClient *client.Client, namespace, name string, args []string, readinessPort int) {
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

	pod.Labels = map[string]string{ownerLabelKey: ownerLabelValue}
	if readinessPort != 0 {
		pod.Spec.Containers[0].ReadinessProbe = &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				TCPSocket: &corev1.TCPSocketAction{Port: intstr.FromInt32(int32(readinessPort))},
			},
			PeriodSeconds: 2,
		}
	}

	recreateUnhealthyPod(ctx, wcClient, pod)

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
		Should(BeTrue(), func() string { return podDiagnostics(ctx, wcClient, pod) })
}

// recreateUnhealthyPod deletes an existing pod that is not owned by this suite,
// has finished, or differs from the desired image/args, and waits until it is
// gone so the caller can create a fresh one.
func recreateUnhealthyPod(ctx context.Context, wcClient *client.Client, desired *corev1.Pod) {
	existing := &corev1.Pod{}
	err := wcClient.Get(ctx, cr.ObjectKeyFromObject(desired), existing)
	if apierrors.IsNotFound(err) {
		return
	}
	Expect(err).NotTo(HaveOccurred())

	healthy := existing.DeletionTimestamp == nil &&
		existing.Labels[ownerLabelKey] == ownerLabelValue &&
		existing.Status.Phase != corev1.PodFailed && existing.Status.Phase != corev1.PodSucceeded &&
		len(existing.Spec.Containers) == 1 &&
		existing.Spec.Containers[0].Image == desired.Spec.Containers[0].Image &&
		slices.Equal(existing.Spec.Containers[0].Args, desired.Spec.Containers[0].Args)
	if healthy {
		return
	}

	logger.Log("Recreating pod %s/%s", existing.Namespace, existing.Name)
	if existing.DeletionTimestamp == nil {
		Expect(cr.IgnoreNotFound(wcClient.Delete(ctx, existing))).To(Succeed())
	}
	Eventually(func() bool {
		err := wcClient.Get(ctx, cr.ObjectKeyFromObject(desired), &corev1.Pod{})
		return apierrors.IsNotFound(err)
	}).
		WithTimeout(2*time.Minute).
		WithPolling(2*time.Second).
		Should(BeTrue(), "expected pod %s/%s to be deleted", desired.Namespace, desired.Name)
}

// podDiagnostics describes why a pod is not Ready: container states and the
// last log lines.
func podDiagnostics(ctx context.Context, wcClient *client.Client, pod *corev1.Pod) string {
	msg := fmt.Sprintf("expected pod %s/%s to be Ready", pod.Namespace, pod.Name)

	current := &corev1.Pod{}
	if err := wcClient.Get(ctx, cr.ObjectKeyFromObject(pod), current); err != nil {
		return msg + fmt.Sprintf(" (could not get pod: %v)", err)
	}
	msg += fmt.Sprintf("; phase=%s", current.Status.Phase)
	for _, cs := range current.Status.ContainerStatuses {
		switch {
		case cs.State.Waiting != nil:
			msg += fmt.Sprintf("; container %s waiting: %s %s", cs.Name, cs.State.Waiting.Reason, cs.State.Waiting.Message)
		case cs.State.Terminated != nil:
			msg += fmt.Sprintf("; container %s terminated: %s exit=%d", cs.Name, cs.State.Terminated.Reason, cs.State.Terminated.ExitCode)
		case cs.State.Running != nil:
			msg += fmt.Sprintf("; container %s running", cs.Name)
		}
		if cs.LastTerminationState.Terminated != nil {
			t := cs.LastTerminationState.Terminated
			msg += fmt.Sprintf(" (last: %s exit=%d)", t.Reason, t.ExitCode)
		}
	}

	lines := int64(20)
	if logs, err := wcClient.GetLogs(ctx, current, &lines); err == nil && logs != "" {
		msg += "; logs: " + logs
	}
	return msg
}

// expectReachability asserts whether the probe in fromNamespace can reach the
// target. For want == false only a connection timeout counts as blocked
// (a deny policy drops packets); a refused connection or any other error is
// reported as an error so the target being down cannot pass as "blocked".
// A negative result must then hold for 30s, so a single dropped packet or a
// policy that is not yet programmed cannot produce a pass.
func expectReachability(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget, want bool) {
	expectReachabilityWithin(ctx, wcClient, fromNamespace, target, want, 3*time.Minute)
}

// expectReachabilityWithin is expectReachability with its own bound for how
// long the expected state may take to appear.
func expectReachabilityWithin(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget, want bool, within time.Duration) {
	expectState(func() (bool, error) {
		result, err := probeHTTP(ctx, wcClient, fromNamespace, target)
		if err != nil {
			return false, err
		}
		return result == outcomeReachable, nil
	}, fmt.Sprintf("%s from %s", target, fromNamespace), want, within, 30*time.Second)
}

// controlProbe is a probe that must succeed against the same target as a
// blocked probe: pod and namespace to exec from, and an optional host that
// replaces the target's (used to reach the target pod over loopback).
type controlProbe struct {
	Namespace string
	Pod       string
	Host      string
}

// optedOutControl probes from controlNamespace, which carries the opt-out
// label and so has no deny. It is the control for targets that an opted-out
// namespace may reach: pods in other opted-out namespaces, the API server,
// DNS, the internet.
var optedOutControl = controlProbe{Namespace: controlNamespace, Pod: probePodName}

// loopbackControl runs inside the target pod itself and connects over
// loopback, which no network policy touches. It is the control for a target
// in a denied namespace, where no other namespace can reach it.
func loopbackControl(namespace, pod string) controlProbe {
	return controlProbe{Namespace: namespace, Pod: pod, Host: "127.0.0.1"}
}

// expectBlocked asserts the target is blocked from fromNamespace and then that
// the control reaches it. busybox wget reports "download timed out" for a
// connect that never completes but also for a read that stalls after
// connecting, so a timeout alone cannot tell a dropped packet from a dead or
// slow target. The control proves the target answers when it is allowed to.
func expectBlocked(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget, control controlProbe, within time.Duration) {
	expectReachabilityWithin(ctx, wcClient, fromNamespace, target, false, within)

	controlTarget := target
	if control.Host != "" {
		controlTarget.Host = control.Host
	}
	Eventually(func() (bool, error) {
		result, err := probeHTTPFrom(ctx, wcClient, control.Namespace, control.Pod, controlTarget)
		if err != nil {
			return false, err
		}
		return result == outcomeReachable, nil
	}).
		WithTimeout(time.Minute).
		WithPolling(5*time.Second).
		Should(BeTrue(), "the control in %s/%s cannot reach %s, so the blocked result from %s proves nothing", control.Namespace, control.Pod, target, fromNamespace)
}

// expectDNSBlocked is expectBlocked for DNS: after the blocked result the
// opted-out control namespace must resolve the name, so a dead resolver cannot
// pass as blocked.
func expectDNSBlocked(ctx context.Context, wcClient *client.Client, fromNamespace string, within time.Duration) {
	expectDNS(ctx, wcClient, fromNamespace, false, within)
	expectDNS(ctx, wcClient, controlNamespace, true, time.Minute)
}

// expectDNS asserts whether the probe in fromNamespace can resolve dnsName.
// Same rules as expectReachability: only a DNS timeout counts as blocked.
func expectDNS(ctx context.Context, wcClient *client.Client, fromNamespace string, want bool, within time.Duration) {
	expectState(func() (bool, error) {
		result, err := probeDNS(ctx, wcClient, fromNamespace)
		if err != nil {
			return false, err
		}
		return result == outcomeReachable, nil
	}, fmt.Sprintf("DNS lookup of %s from %s", dnsDescription, fromNamespace), want, within, 30*time.Second)
}

// expectState polls probe until it returns want, within the given time. A
// negative result must then hold for stable, see expectReachability. Probe
// errors are retried while waiting, but fail a stability check.
func expectState(probe func() (bool, error), what string, want bool, within, stable time.Duration) {
	description := "blocked"
	if want {
		description = "reachable"
	}

	Eventually(probe).
		WithTimeout(within).
		WithPolling(5*time.Second).
		Should(Equal(want), "expected %s to be %s", what, description)

	if !want {
		Consistently(probe).
			WithTimeout(stable).
			WithPolling(5*time.Second).
			Should(BeFalse(), "expected %s to stay blocked", what)
	}
}

// probeHTTP issues one HTTP request from the probe pod in fromNamespace to the
// target and classifies the result as reachable or timeout. A refused
// connection or any other failure returns an error.
func probeHTTP(ctx context.Context, wcClient *client.Client, fromNamespace string, target probeTarget) (outcome, error) {
	return probeHTTPFrom(ctx, wcClient, fromNamespace, probePodName, target)
}

// probeHTTPFrom is probeHTTP from a named pod, for controls that run inside
// the target pod itself.
func probeHTTPFrom(ctx context.Context, wcClient *client.Client, fromNamespace, pod string, target probeTarget) (outcome, error) {
	// Bound the exec so a hung connection cannot block the spec.
	ctx, cancel := context.WithTimeout(ctx, execTimeout)
	defer cancel()

	// The exit code of wget is captured on purpose: a denied connection is an
	// expected outcome, not an exec failure. stderr distinguishes a timeout
	// (silent drop) from a refusal (target down or reset).
	flags := ""
	if target.HTTPSAnyAnswer {
		// busybox wget verifies certificates through ssl_client; the cluster
		// CA is not in the image and only the network path is under test.
		flags = "--no-check-certificate "
	}
	script := fmt.Sprintf(`out=$(wget -q -T %d %s-O /dev/null %s 2>&1); rc=$?; echo "$rc"; echo "$out"`,
		probeTimeoutSeconds, flags, target.url())

	stdout, stderr, err := wcClient.ExecInPod(ctx, pod, fromNamespace, probeContainerName, []string{"sh", "-c", script})
	if err != nil {
		return "", fmt.Errorf("failed to run probe in %s/%s: %w (stderr: %q)", fromNamespace, pod, err, stderr)
	}

	code, detail, _ := strings.Cut(strings.TrimSpace(stdout), "\n")
	detail = strings.TrimSpace(detail)
	logger.Log("HTTP probe from %s to %s: exit=%s %s", fromNamespace, target, code, detail)

	if code == "0" {
		return outcomeReachable, nil
	}

	lower := strings.ToLower(detail)
	// An HTTP error status is an answer from the target, so for targets that
	// only prove the network path it counts as reachable.
	if target.HTTPSAnyAnswer && strings.Contains(lower, "server returned error") {
		return outcomeReachable, nil
	}

	// Only busybox wget's own timeout messages count: "wget: download timed
	// out" and the kernel's "Connection timed out". "server returned error"
	// (e.g. an HTTP 504 Gateway Timeout) and refusals are errors.
	if !strings.Contains(lower, "server returned error") &&
		(strings.Contains(lower, "wget: download timed out") || strings.Contains(lower, "connection timed out")) {
		return outcomeTimeout, nil
	}
	// A refusal or an unreachable network means nothing dropped the packets:
	// the target or the route is missing. Wrapped so a caller can tell it from
	// an exec or classification failure.
	if strings.Contains(lower, "connection refused") || strings.Contains(lower, "network unreachable") ||
		strings.Contains(lower, "host unreachable") || strings.Contains(lower, "no route to host") {
		return "", fmt.Errorf("%w: probe from %s to %s (not counted as blocked): exit=%s %q", errNoRoute, fromNamespace, target, code, detail)
	}
	return "", fmt.Errorf("probe from %s to %s failed without timing out (not counted as blocked): exit=%s %q", fromNamespace, target, code, detail)
}

// probeDNS resolves dnsName from the probe pod in fromNamespace using busybox
// nslookup against the pod's resolver and classifies the result as resolved
// (outcomeReachable) or timeout. NXDOMAIN, SERVFAIL, REFUSED and exec
// failures return an error: only a timeout is what a deny policy produces.
func probeDNS(ctx context.Context, wcClient *client.Client, fromNamespace string) (outcome, error) {
	ctx, cancel := context.WithTimeout(ctx, execTimeout)
	defer cancel()

	// busybox nslookup does not apply the search list, so the cluster domain
	// is read from the pod's resolv.conf: its search line holds
	// <ns>.svc.<domain>, svc.<domain>, <domain>. nslookup exits 1 on a timeout
	// as well as on NXDOMAIN, so the exit code is captured and the output
	// decides. -retry=1 keeps it to one 2s try.
	script := `d=$(awk '$1=="search"{for(i=2;i<=NF;i++) if($i ~ /^svc\./){print substr($i,5); exit}}' /etc/resolv.conf)
if [ -z "$d" ]; then echo 127; echo "no svc.<domain> entry in the search line of /etc/resolv.conf"; exit 0; fi
out=$(nslookup -timeout=2 -retry=1 "kubernetes.default.svc.$d." 2>&1); rc=$?; echo "$rc"; echo "$out"`

	stdout, stderr, err := wcClient.ExecInPod(ctx, probePodName, fromNamespace, probeContainerName, []string{"sh", "-c", script})
	if err != nil {
		return "", fmt.Errorf("failed to run DNS probe in %s/%s: %w (stderr: %q)", fromNamespace, probePodName, err, stderr)
	}

	code, detail, _ := strings.Cut(strings.TrimSpace(stdout), "\n")
	detail = strings.TrimSpace(detail)
	logger.Log("DNS probe from %s for %s: exit=%s %s", fromNamespace, dnsDescription, code, strings.ReplaceAll(detail, "\n", " | "))

	lower := strings.ToLower(detail)
	if code == "0" && strings.Contains(lower, "name:") && strings.Contains(lower, "address") {
		return outcomeReachable, nil
	}

	// busybox prints ";; connection timed out; no servers could be reached"
	// when the resolver never answers. Refused or unreachable servers print
	// other messages and are not counted. NXDOMAIN is an error too.
	if strings.Contains(lower, "connection timed out; no servers could be reached") &&
		!strings.Contains(lower, "refused") && !strings.Contains(lower, "unreachable") {
		return outcomeTimeout, nil
	}
	return "", fmt.Errorf("DNS probe from %s for %s failed without timing out (not counted as blocked): exit=%s %q", fromNamespace, dnsDescription, code, detail)
}

// setNamespaceLabels sets and removes labels on a suite-owned namespace in a
// single Update, so every change lands in one request.
func setNamespaceLabels(ctx context.Context, wcClient *client.Client, name string, set map[string]string, remove ...string) {
	// Retry on conflicts: other controllers also write namespaces.
	Eventually(func() error {
		namespace := &corev1.Namespace{}
		if err := wcClient.Get(ctx, cr.ObjectKey{Name: name}, namespace); err != nil {
			return err
		}
		if namespace.Labels[ownerLabelKey] != ownerLabelValue {
			return StopTrying(fmt.Sprintf("namespace %s is not owned by this suite", name))
		}
		if namespace.Labels == nil {
			namespace.Labels = map[string]string{}
		}
		for key, value := range set {
			namespace.Labels[key] = value
		}
		for _, key := range remove {
			delete(namespace.Labels, key)
		}
		return wcClient.Update(ctx, namespace)
	}).
		WithTimeout(30 * time.Second).
		WithPolling(time.Second).
		Should(Succeed())
}

// podIdentity identifies one running incarnation of a pod: a different UID or
// a higher restart count means the pod was replaced or restarted.
type podIdentity struct {
	UID      types.UID
	Restarts int32
}

func getPodIdentity(ctx context.Context, wcClient *client.Client, namespace, name string) podIdentity {
	pod := &corev1.Pod{}
	Expect(wcClient.Get(ctx, cr.ObjectKey{Namespace: namespace, Name: name}, pod)).To(Succeed())

	identity := podIdentity{UID: pod.UID}
	for _, cs := range pod.Status.ContainerStatuses {
		identity.Restarts += cs.RestartCount
	}
	return identity
}

const sameNamespacePolicyName = "cwd-e2e-same-namespace"

// sameNamespacePolicy is the Same-namespace policy a namespace owner applies
// to open traffic between the pods of their own namespace under the
// clusterwide deny. Cilium cannot express "own namespace" clusterwide, so this
// is a namespaced CiliumNetworkPolicy, not a standard allow. Purely additive:
// enableDefaultDeny false/false keeps it from locking anything down itself.
func sameNamespacePolicy(namespace string) *unstructured.Unstructured {
	policy := &unstructured.Unstructured{Object: map[string]any{
		"spec": map[string]any{
			"endpointSelector":  map[string]any{},
			"enableDefaultDeny": map[string]any{"ingress": false, "egress": false},
			"ingress":           []any{map[string]any{"fromEndpoints": []any{map[string]any{}}}},
			"egress":            []any{map[string]any{"toEndpoints": []any{map[string]any{}}}},
		},
	}}
	policy.SetAPIVersion("cilium.io/v2")
	policy.SetKind("CiliumNetworkPolicy")
	policy.SetName(sameNamespacePolicyName)
	policy.SetNamespace(namespace)
	policy.SetLabels(map[string]string{ownerLabelKey: ownerLabelValue})
	return policy
}

func applySameNamespacePolicy(ctx context.Context, wcClient *client.Client, namespace string) {
	err := wcClient.Create(ctx, sameNamespacePolicy(namespace))
	if err != nil && !apierrors.IsAlreadyExists(err) {
		Expect(err).NotTo(HaveOccurred())
	}
}

func deleteSameNamespacePolicy(ctx context.Context, wcClient *client.Client, namespace string) {
	Expect(cr.IgnoreNotFound(wcClient.Delete(ctx, sameNamespacePolicy(namespace)))).To(Succeed())
}

// kubernetesServiceTarget returns the API server as reached from pods: the
// ClusterIP and port of the default/kubernetes Service, /version over HTTPS.
func kubernetesServiceTarget(ctx context.Context, wcClient *client.Client) probeTarget {
	service := &corev1.Service{}
	Expect(wcClient.Get(ctx, cr.ObjectKey{Namespace: "default", Name: "kubernetes"}, service)).To(Succeed())
	Expect(service.Spec.ClusterIP).NotTo(BeEmpty())
	Expect(service.Spec.Ports).NotTo(BeEmpty())

	return probeTarget{
		Host:           service.Spec.ClusterIP,
		Port:           int(service.Spec.Ports[0].Port),
		Scheme:         "https",
		Path:           "/version",
		HTTPSAnyAnswer: true,
	}
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
		if err != nil {
			logger.Log("Failed to get namespace %s for cleanup: %s", name, err)
			continue
		}
		if namespace.Labels[ownerLabelKey] != ownerLabelValue {
			logger.Log("Not deleting namespace %s, it is not owned by this suite", name)
			continue
		}

		logger.Log("Deleting namespace %s", name)
		if err := cr.IgnoreNotFound(wcClient.Delete(ctx, namespace)); err != nil {
			logger.Log("Failed to delete namespace %s: %s", name, err)
		}
	}
}
