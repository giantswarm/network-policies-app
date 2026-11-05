package clusterwidedeny

import (
	"context"
	"fmt"
	"time"

	. "github.com/onsi/gomega"

	"github.com/giantswarm/apptest-framework/v5/pkg/state"
	"github.com/giantswarm/clustertest/v5/pkg/logger"

	corev1 "k8s.io/api/core/v1"
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

// enableClusterWideDeny turns the clusterwide deny on for the running cluster
// the way a customer would: through the network-policies values in the
// cluster app's user config. The cluster chart then re-renders the
// network-policies HelmRelease with the new values.
//
// The deny is not set in the suite's values.yaml because a default app's
// values apply when the cluster is created, and a clusterwide deny from the
// cluster's first minute stops default apps (Kyverno) from installing before
// the standard allows and the per-app allows exist.
func enableClusterWideDeny(ctx context.Context) {
	cluster := state.GetCluster()
	key := types.NamespacedName{
		Name:      fmt.Sprintf("%s-userconfig", cluster.ClusterApp.InstallName),
		Namespace: cluster.ClusterApp.GetNamespace(),
	}
	logger.Log("Enabling the clusterwide deny in the cluster values %s", key)

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
		if err := unstructured.SetNestedField(values, true, path...); err != nil {
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
	Expect(err).NotTo(HaveOccurred(), "failed to enable the clusterwide deny in the cluster values %s", key)
}

// expectClusterWideDenyPolicy waits until the chart's clusterwide deny CCNP
// exists in the workload cluster. The cluster app and then the
// network-policies HelmRelease both have to reconcile first.
func expectClusterWideDenyPolicy(ctx context.Context) {
	wcClient := workloadClusterClient()
	Eventually(func() error {
		policy := &unstructured.Unstructured{}
		policy.SetAPIVersion("cilium.io/v2")
		policy.SetKind("CiliumClusterwideNetworkPolicy")
		return wcClient.Get(ctx, types.NamespacedName{Name: clusterWideDenyPolicyName}, policy)
	}).
		WithTimeout(15*time.Minute).
		WithPolling(15*time.Second).
		Should(Succeed(), "the CiliumClusterwideNetworkPolicy %s did not appear after enabling the clusterwide deny in the cluster values", clusterWideDenyPolicyName)
}
