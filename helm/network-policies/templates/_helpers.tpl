{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "labels.selector" -}}
app.kubernetes.io/name: {{ include "name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "labels.common" -}}
{{ include "labels.selector" . }}
app.giantswarm.io/branch: {{ .Chart.Annotations.branch | replace "#" "-" | replace "/" "-" | replace "." "-" | trunc 63 | trimSuffix "-" | quote }}
application.giantswarm.io/commit: {{ .Chart.Annotations.commit | quote }}
application.kubernetes.io/managed-by: {{ .Release.Service | quote }}
application.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
application.giantswarm.io/team: {{ index .Chart.Annotations "io.giantswarm.application.team" | quote }}
giantswarm.io/managed-by: {{ .Release.Name | quote }}
giantswarm.io/service-type: {{ .Values.serviceType }}
helm.sh/chart: {{ include "chart" . | quote }}
{{- end -}}


{{- define "network-policies-app.konnectivityAgent.enabled" -}}
{{- if or .Values.konnectivityAgent.enabled .Values.kamaji.enabled -}}
true
{{- end -}}
{{- end -}}

{{- define "network-policies-app.konnectivityAgent.namespaces" -}}
{{- $namespaces := list -}}
{{- if .Values.konnectivityAgent.enabled -}}
{{- $namespaces = concat $namespaces .Values.konnectivityAgent.namespaces -}}
{{- end -}}
{{- if .Values.kamaji.enabled -}}
{{- $namespaces = concat $namespaces .Values.kamaji.namespaces -}}
{{- end -}}
{{- $namespaces | uniq | toYaml -}}
{{- end -}}

{{/*
Endpoint selector shared by the clusterwide deny and the clusterwide DNS allow, so they cannot drift.
NotIn also selects namespaces that do not carry the label, so unlabeled namespaces are denied.
The opt-out key is fixed: a namespace opts out with policy.giantswarm.io/default-deny: "false".
reserved:health keeps the Cilium health endpoints out. They carry no namespace labels, so the NotIn selects them,
and denying them cut cluster health to 1/6 in the spike.
*/}}
{{- define "network-policies-app.clusterWide.endpointSelector" -}}
matchExpressions:
  - key: io.cilium.k8s.namespace.labels.policy.giantswarm.io/default-deny
    operator: NotIn
    values:
      - "false"
  - key: reserved:health
    operator: DoesNotExist
{{- end -}}

{{/*
Egress to the cluster DNS, L4 only. Shared by the clusterwide DNS allow and the allow-dns standard allow, so they
cannot drift. Never the rules.dns block of allow-dns.yaml: an L4 DNS allow widens customer FQDN allow-lists, and an L7
rule here would put the DNS of every selected namespace through the proxy (enableDefaultDeny false does not cover L7).
*/}}
{{- define "network-policies-app.dnsEgress" -}}
- toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: coredns
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: k8s-dns-node-cache
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns # Used in AKS
  toPorts:
    - ports:
        - port: "1053"
          protocol: UDP
        - port: "1053"
          protocol: TCP
        - port: "53"
          protocol: UDP
        - port: "53"
          protocol: TCP
{{- end -}}

{{/*
Endpoint selector of a standard allow: the namespaces carrying its allow label policy.giantswarm.io/allow-<x>: "true".
Health endpoints carry no namespace labels, so no reserved:health exclusion is needed.
*/}}
{{- define "network-policies-app.standardAllow.endpointSelector" -}}
matchExpressions:
  - key: io.cilium.k8s.namespace.labels.policy.giantswarm.io/allow-{{ . }}
    operator: In
    values:
      - "true"
{{- end -}}
