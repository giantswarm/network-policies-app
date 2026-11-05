package clusterwidedeny

import (
	"context"
	"fmt"
	"time"

	. "github.com/onsi/gomega"

	helmv2 "github.com/fluxcd/helm-controller/api/v2"
	"github.com/giantswarm/apptest-framework/v5/pkg/state"
	"github.com/giantswarm/clustertest/v5/pkg/logger"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	"sigs.k8s.io/yaml"
)

const (
	// clusterWideDenyPolicyName is the CCNP the chart renders when
	// denyByDefault.clusterWide.enabled is true.
	clusterWideDenyPolicyName = "default-deny-all-namespaces"

	// clusterValuesDataKey is the key of the cluster app's user config
	// ConfigMap that holds its values.
	clusterValuesDataKey = "values"
)

// networkPoliciesValuesPath is where the cluster chart reads the values of the
// network-policies default app: global.apps.<camelCase app name>.values. It is
// the same path clustertest writes a default app's values to when it builds
// the cluster (buildDefaultAppValues).
var networkPoliciesValuesPath = []string{"global", "apps", "networkPolicies", "values"}

// setClusterWideDeny turns the clusterwide deny on or off for the running
// cluster the way a customer would: through the network-policies values in the
// cluster app's user config. The cluster chart then re-renders the
// network-policies HelmRelease with the new values.
//
// The deny is not set in the suite's values.yaml because a default app's
// values apply when the cluster is created, and a clusterwide deny from the
// cluster's first minute stops default apps (Kyverno) from installing before
// the standard allows and the per-app allows exist.
func setClusterWideDeny(ctx context.Context, enabled bool) error {
	cluster := state.GetCluster()
	key := types.NamespacedName{
		Name:      fmt.Sprintf("%s-userconfig", cluster.ClusterApp.InstallName),
		Namespace: cluster.ClusterApp.GetNamespace(),
	}
	logger.Log("Setting denyByDefault.clusterWide.enabled=%t in the cluster values %s", enabled, key)

	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		cm := &corev1.ConfigMap{}
		if err := state.GetFramework().MC().Get(ctx, key, cm); err != nil {
			return err
		}

		values := map[string]any{}
		if err := yaml.Unmarshal([]byte(cm.Data[clusterValuesDataKey]), &values); err != nil {
			return fmt.Errorf("failed to parse the cluster values in %s: %w", key, err)
		}
		path := append(append([]string{}, networkPoliciesValuesPath...), "denyByDefault", "clusterWide", "enabled")
		if err := unstructured.SetNestedField(values, enabled, path...); err != nil {
			return fmt.Errorf("failed to set %v in the cluster values in %s: %w", path, key, err)
		}
		out, err := yaml.Marshal(values)
		if err != nil {
			return err
		}

		if cm.Data == nil {
			cm.Data = map[string]string{}
		}
		cm.Data[clusterValuesDataKey] = string(out)
		return state.GetFramework().MC().Update(ctx, cm)
	})
	if err != nil {
		return fmt.Errorf("failed to set the clusterwide deny in the cluster values %s: %w", key, err)
	}
	return nil
}

// clusterWideDenyPolicyExists reports whether the chart's clusterwide deny
// CCNP exists in the workload cluster.
func clusterWideDenyPolicyExists(ctx context.Context) (bool, error) {
	policy := &unstructured.Unstructured{}
	policy.SetAPIVersion("cilium.io/v2")
	policy.SetKind("CiliumClusterwideNetworkPolicy")
	err := workloadClusterClient().Get(ctx, types.NamespacedName{Name: clusterWideDenyPolicyName}, policy)
	if apierrors.IsNotFound(err) {
		return false, nil
	}
	return err == nil, err
}

// expectClusterWideDenyPolicy waits until the chart's clusterwide deny CCNP
// exists in the workload cluster and the network-policies HelmRelease has
// settled on the new values. The cluster app and then the HelmRelease both
// have to reconcile first. Waiting for the HelmRelease too catches an upgrade
// that renders the CCNP and is then rolled back.
func expectClusterWideDenyPolicy(ctx context.Context) {
	Eventually(func() (bool, error) { return clusterWideDenyPolicyExists(ctx) }).
		WithTimeout(15*time.Minute).
		WithPolling(15*time.Second).
		Should(BeTrue(), "the CiliumClusterwideNetworkPolicy %s did not appear after enabling the clusterwide deny in the cluster values", clusterWideDenyPolicyName)

	Eventually(func() error { return networkPoliciesReleaseSettled(ctx) }).
		WithTimeout(5*time.Minute).
		WithPolling(15*time.Second).
		Should(Succeed(), "the network-policies HelmRelease did not settle after enabling the clusterwide deny")

	Consistently(func() (bool, error) { return clusterWideDenyPolicyExists(ctx) }).
		WithTimeout(time.Minute).
		WithPolling(15*time.Second).
		Should(BeTrue(), "the CiliumClusterwideNetworkPolicy %s went away again after the HelmRelease settled", clusterWideDenyPolicyName)
}

// networkPoliciesReleaseSettled returns nil when the network-policies
// HelmRelease on the management cluster is Ready for its current generation.
func networkPoliciesReleaseSettled(ctx context.Context) error {
	cluster := state.GetCluster()
	key := types.NamespacedName{
		Name:      fmt.Sprintf("%s-network-policies", cluster.Name),
		Namespace: cluster.Organization.GetNamespace(),
	}
	release := &helmv2.HelmRelease{}
	if err := state.GetFramework().MC().Get(ctx, key, release); err != nil {
		return err
	}
	if release.Status.ObservedGeneration != release.Generation {
		return fmt.Errorf("HelmRelease %s observed generation %d, want %d", key, release.Status.ObservedGeneration, release.Generation)
	}
	for _, c := range release.Status.Conditions {
		if c.Type == "Ready" {
			if c.Status == "True" && c.ObservedGeneration == release.Generation {
				return nil
			}
			return fmt.Errorf("HelmRelease %s not ready [%s]: %s", key, c.Reason, c.Message)
		}
	}
	return fmt.Errorf("HelmRelease %s has no Ready condition", key)
}

// denyEnabled records that the suite turned the deny on, so teardown only
// turns it off when there is something to undo.
var denyEnabled bool

// disableClusterWideDeny turns the deny off again before the cluster is torn
// down, so uninstall hooks in denied namespaces can reach the API server.
// Best effort and bounded to 10 minutes: it only logs, since the cluster is
// deleted either way.
func disableClusterWideDeny(ctx context.Context) {
	if !denyEnabled {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	if err := setClusterWideDeny(ctx, false); err != nil {
		logger.Log("Could not turn the clusterwide deny off before teardown: %s", err)
		return
	}
	// A Gomega that only logs, so a timeout here never fails the suite.
	g := NewGomega(func(message string, _ ...int) { logger.Log("%s", message) })
	gone := g.Eventually(ctx, func() (bool, error) { return clusterWideDenyPolicyExists(ctx) }).
		WithPolling(15 * time.Second).
		Should(BeFalse())
	if !gone {
		logger.Log("The CiliumClusterwideNetworkPolicy %s was still there when the teardown budget ran out; tearing down anyway", clusterWideDenyPolicyName)
		return
	}
	logger.Log("The clusterwide deny is off")
}
