#!/usr/bin/env bash
# Spike kit for giantswarm/roadmap#4339: validates the clusterwide deny, the clusterwide DNS allow and the
# Kyverno GeneratingPolicy standard allows on ONE dedicated test workload cluster.
#
# Only kubectl is used. Everything this script creates is named ddn-spike-* (or lives in a ddn-spike-* namespace)
# and carries the label
#   spike.giantswarm.io/owner=default-deny-netpol
# `cleanup` deletes by that label selector only. Every other delete in this script goes through delete_owned,
# which re-reads the owner label and refuses to delete an object that lacks it. The preflight refuses to run when
# any object the kit would create already exists without the owner label.
#
# WARNING: `setup` applies a CiliumClusterwideNetworkPolicy that denies all traffic of all namespaces
# (kube-system and giantswarm included). Use a dedicated test cluster. See README.md.
set -uo pipefail
# A closed reader (`| tee` killed, terminal gone) must never kill the script half way through a Kyverno restore.
trap '' PIPE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$HERE/manifests"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
OWNER_KEY="spike.giantswarm.io/owner"
OWNER_VAL="default-deny-netpol"
OWNER_SEL="${OWNER_KEY}=${OWNER_VAL}"
KIT="ddn-spike"

KCTX=""
KCFG=""
KARGS=()
PROVIDER="unknown"
ONLY=""
OUTDIR="${SPIKE_OUTDIR:-$PWD/spike-results}"
IMAGE_DEFAULT="nicolaka/netshoot:v0.13"
IMAGE="${SPIKE_IMAGE:-$IMAGE_DEFAULT}"
PAUSE_IMAGE="${SPIKE_PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
CLUSTER_DOMAIN="${SPIKE_CLUSTER_DOMAIN:-cluster.local}"
EXTERNAL_URL="${SPIKE_EXTERNAL_URL:-https://1.1.1.1}"
LOAD_PODS="${SPIKE_LOAD_PODS:-20}"
DROP_WINDOW="${SPIKE_DROP_WINDOW:-30}"
SYNC_TIMEOUT="${SPIKE_SYNC_TIMEOUT:-90}"
FLIP_TIMEOUT="${SPIKE_FLIP_TIMEOUT:-60}"
FLAP_SECONDS="${SPIKE_FLAP_SECONDS:-60}"
BULK_SAMPLES="${SPIKE_BULK_SAMPLES:-5 60 150 240}"   # seconds after the bulk annotation at which the `bulk` check counts the CNPs
CURL_TIMEOUT=3
SETTLE="${SPIKE_SETTLE:-6}"

NS_A=${KIT}-a
NS_B=${KIT}-b
NS_OPTOUT=${KIT}-optout
NS_ALL=${KIT}-all
NS_WEBHOOK=${KIT}-webhook
NS_BULK=${KIT}-bulk   # created and deleted by the `bulk` check itself: always fresh
NS_SEQ=${KIT}-seq     # one-by-one control of the `bulk` check
OPTOUT_LABEL="policy.giantswarm.io/default-deny"

# Kit object names (all ddn-spike-*): one place, used by setup, preflight, checks and cleanup.
DENY_NAME="${KIT}-default-deny-all-namespaces"
DNS_ALLOW_NAME="${KIT}-allow-dns-all-namespaces"
RBAC_NAME="${KIT}-background-controller-ciliumnetworkpolicies"
WEBHOOK_CFG="${KIT}-webhook"
KYV_CM="${KIT}-kyverno-replicas"
DNS_PROBE_POD="${KIT}-dns-probe"
FQDN_CNP="${KIT}-fqdn"
WEBHOOK_CNP="${KIT}-webhook-ingress"

CCNP=ciliumclusterwidenetworkpolicies.cilium.io
CNP=ciliumnetworkpolicies.cilium.io
GPOL=generatingpolicies.policies.kyverno.io
CROLE=clusterroles.rbac.authorization.k8s.io
VWC=validatingwebhookconfigurations.admissionregistration.k8s.io

# One source for the six generation annotations: the manifest file names generatingpolicies/generatingpolicy-<annotation>.yaml.
GEN_ANNOTATIONS=""
for _f in "$M"/generatingpolicies/generatingpolicy-*.yaml; do
  [ -e "$_f" ] || continue
  _b="${_f##*/generatingpolicy-}"
  GEN_ANNOTATIONS="${GEN_ANNOTATIONS:+$GEN_ANNOTATIONS }${_b%.yaml}"
done
unset _f _b
gname() { echo "${KIT}-$1"; } # annotation -> GeneratingPolicy name AND generated CiliumNetworkPolicy name

# One source for the checks: name:function, in run order. `list`, --only validation and the driver derive from it.
CHECKS="same-ns:same_ns_denied_unannotated ac1:ac1_optout_live_flip ac2:ac2_probes_hostnetwork ac3:ac3_aks_support \
dns:ac_dns apiserver:ac_apiserver ac5:ac5_generate_sync ac5b:ac5b_generate_existing flap:ac_flap bulk:ac_bulk restart:ac_restart \
ac6:ac6_webhook_ingress ac7:ac7_l7_dns_interaction ac4:ac4_bpf_map_usage ac8:ac8_drops_gs_namespaces ac9:ac9_record_guidance"
fn_for() { local c; for c in $CHECKS; do [ "${c%%:*}" = "$1" ] && { echo "${c#*:}"; return 0; }; done; return 1; }
all_checks() { local c out=""; for c in $CHECKS; do out="${out:+$out,}${c%%:*}"; done; echo "$out"; }

usage() {
  cat <<EOF
Usage: $0 [options] <command>

Commands:
  run       setup (idempotent), then run the checklist functions (default)
  setup     apply probes, RBAC, GeneratingPolicies and the clusterwide deny
  cleanup   restore Kyverno if scaled down, then delete everything carrying ${OWNER_SEL}, deny first
  list      list the checklist functions

Exit status of run: 0 when no check ended FAIL or ERROR; 1 otherwise; 2 for usage errors and when the safety gate refuses.

Options:
  --kubeconfig PATH   kubeconfig to use (default: \$KUBECONFIG / kubectl default)
  --context NAME      kubectl context (default: the kubeconfig's current context)
  --provider NAME     aws | azure | aks | vsphere | ... (recorded in results; "aks" enables AKS notes)
  --only a,b,c        run only these functions (see 'list')
  --outdir DIR        where evidence files go (default: ./spike-results)

Safety gate: the clusterwide deny is only applied when SPIKE_CONFIRM equals the kubectl context that will
actually be used (resolved with --kubeconfig/--context honoured, printed by the preflight), e.g.
  SPIKE_CONFIRM=my-test-wc $0 --context my-test-wc run

Environment: SPIKE_IMAGE, SPIKE_PAUSE_IMAGE, SPIKE_CLUSTER_DOMAIN, SPIKE_EXTERNAL_URL, SPIKE_LOAD_PODS,
SPIKE_DROP_WINDOW, SPIKE_SYNC_TIMEOUT, SPIKE_FLIP_TIMEOUT, SPIKE_FLAP_SECONDS, SPIKE_BULK_SAMPLES ("5 60 150 240"), SPIKE_SETTLE,
SPIKE_ALLOW_KYVERNO_SCALE=true (opt in to the "Kyverno down" generate-existing test: scales ALL Kyverno
deployments to 0; refused when a Kyverno webhook has failurePolicy Fail unless SPIKE_KYVERNO_SCALE_ALLOW_FAIL_CLOSED=true),
SPIKE_SKIP_KYVERNO_RESTART=true (skip the background-controller restart check),
SPIKE_ALLOW_NO_COREDNS_INGRESS=true (continue although no policy allowing ingress to CoreDNS was found),
SPIKE_CLEANUP_ON_EXIT=true (on any exit, including Ctrl-C, run cleanup; default: leave the deny applied and say so).
EOF
}

CMD="run"
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) KCFG="${2:?--kubeconfig needs a value}"; shift 2 ;;
    --context) KCTX="${2:?--context needs a value}"; shift 2 ;;
    --provider) PROVIDER="${2:?--provider needs a value}"; shift 2 ;;
    --only) ONLY="${2:?--only needs a value}"; shift 2 ;;
    --outdir) OUTDIR="${2:?--outdir needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    run|setup|cleanup|list) CMD="$1"; shift ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

rebuild_kargs() {
  KARGS=()
  [ -n "$KCFG" ] && KARGS+=(--kubeconfig "$KCFG")
  [ -n "$KCTX" ] && KARGS+=(--context "$KCTX")
  return 0
}
rebuild_kargs
K() { kubectl "${KARGS[@]+"${KARGS[@]}"}" "$@"; }

# The context kubectl will really use, with --kubeconfig/--context honoured (config current-context ignores --context).
# Pinned into KARGS afterwards, so a later `kubectl config use-context` elsewhere cannot redirect the run.
resolve_context() {
  local c
  c="$(K config view --minify -o jsonpath='{.contexts[0].name}' 2>/dev/null)"
  if [ -z "$c" ]; then
    echo "cannot determine the kubectl context that will be used (check --kubeconfig / --context)" >&2
    return 1
  fi
  KCTX="$c"
  rebuild_kargs
}

kubectl_prefix() { # printable kubectl command prefix for the targeted cluster
  local p="kubectl"
  [ -n "$KCFG" ] && p="$p --kubeconfig $(printf '%q' "$KCFG")"
  [ -n "$KCTX" ] && p="$p --context $(printf '%q' "$KCTX")"
  echo "$p"
}
cleanup_cmd() {
  local p; p="$(printf '%q' "$SELF")"
  [ -n "$KCFG" ] && p="$p --kubeconfig $(printf '%q' "$KCFG")"
  [ -n "$KCTX" ] && p="$p --context $(printf '%q' "$KCTX")"
  echo "$p cleanup"
}

# ---------------------------------------------------------------------------------------------- bounded execution
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
# Run an EXTERNAL command (not a shell function) for at most $1 seconds. Uses timeout/gtimeout when present, else
# runs the command in its own process group (set -m) and kills the group, so no kubectl exec outlives the window.
run_bounded() {
  local s="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" -k 5 "$s" "$@"; return; fi
  (
    set -m
    "$@" &
    p=$!
    # the watchdog has its own process group and no inherited stdout/stderr, so when the command finishes the whole
    # watchdog (including its sleep) is killed and cannot keep a $(...) pipe open
    ( sleep "$s"; kill -TERM -- "-$p" 2>/dev/null; sleep 2; kill -KILL -- "-$p" 2>/dev/null ) >/dev/null 2>&1 &
    w=$!
    wait "$p"; rc=$?
    kill -TERM -- "-$w" 2>/dev/null; kill "$w" 2>/dev/null
    exit "$rc"
  )
}
kill_tree() { pkill -TERM -P "$1" 2>/dev/null; kill "$1" 2>/dev/null; return 0; }

# ---------------------------------------------------------------------------------------------- state, trap
KYV_SCALED=0
KYV_SAVED=""   # "<deployment> <replicas>" lines of the deployments THIS run scaled down (in-memory copy of the ConfigMap)
DENY_APPLIED=0
DENY_AT_SEC=""
CLEANING=0
TOUCHED=0
BG_PIDS=()
HAVE_GPOL=0
EXT_BASE=""

on_exit() {
  local rc=$?
  # Restore/cleanup work must not be interruptible: a second Ctrl-C would otherwise leave Kyverno scaled down.
  trap '' INT TERM HUP
  trap - EXIT
  local p
  for p in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do kill_tree "$p"; done
  if [ "$KYV_SCALED" = 1 ]; then
    echo "!! exiting while Kyverno is scaled down: restoring the saved replica counts (signals are ignored until this is done)" >&2
    restore_kyverno
  fi
  if [ "$DENY_APPLIED" = 1 ] && [ "$CLEANING" = 0 ]; then
    if [ "${SPIKE_CLEANUP_ON_EXIT:-}" = "true" ]; then
      echo "== SPIKE_CLEANUP_ON_EXIT=true: running cleanup (signals are ignored until it is done)"
      CLEANING=1
      cleanup
    else
      {
        echo
        echo "!! THE CLUSTERWIDE DENY IS STILL APPLIED on context '${KCTX}': ${DENY_NAME} denies all traffic of every"
        echo "!! namespace without the opt-out label (kube-system and giantswarm included)."
        echo "!! Remove it and everything else this kit created with:"
        echo "!!   $(cleanup_cmd)"
        echo "!! Deny only (emergency):"
        echo "!!   $(kubectl_prefix) delete ${CCNP} ${DENY_NAME}"
      } >&2 2>/dev/null || true
    fi
  elif [ "$TOUCHED" = 1 ] && [ "$CLEANING" = 0 ] && [ "$rc" -ne 0 ]; then
    {
      echo
      echo "!! The run stopped (exit ${rc}) after the kit created objects on context '${KCTX}' (probe namespaces/pods, policies):"
      echo "!! they are left behind. Remove them with: $(cleanup_cmd)"
    } >&2 2>/dev/null || true
  fi
  # Kyverno still scaled down after every restore attempt: never exit 0
  if [ "$KYV_SCALED" = 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
on_signal() { echo "!! interrupted (${1})" >&2 2>/dev/null || true; exit "$2"; }

# ---------------------------------------------------------------------------------------------- results
RESULTS=()
result() { # ac status evidence
  RESULTS+=("$1|$2|$3")
  printf '%-9s %-12s %s\n' "$1" "$2" "$3"
}
note() { printf '         .. %s\n' "$*"; }
is_aks() { [ "$PROVIDER" = "aks" ]; }
result_status() { local r; for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do case "$r" in "$1|"*) r="${r#*|}"; echo "${r%%|*}"; return 0 ;; esac; done; echo "not-run"; }

# Evidence accumulator for one check: begin; step ...; finish.
#   OK=0     a definite contradiction (FAIL)     INCONC=1  a probe precondition/exec problem (INCONCLUSIVE)
#   ERR=1    a kit operation failed (ERROR)
EV=""; OK=1; INCONC=0; ERR=0
begin() { # keeps errors recorded by the reset_state that ran right before
  local e="$ERR" v="$EV"
  EV=""; OK=1; INCONC=0; ERR=0
  if [ "$e" = 1 ]; then EV="$v"; ERR=1; fi
}
ev() { [ -n "$*" ] || return 0; EV="${EV:+$EV; }$*"; }
# step PASS-TEXT FAIL-TEXT cmd...  cmd returns 0 (as expected), 1 (contradicts), >=2 (inconclusive).
# @T@ in either text is replaced by the seconds the step took.
step() {
  local p="$1" f="$2" t0=$SECONDS rc t
  shift 2
  "$@"; rc=$?
  t=$((SECONDS - t0)); p="${p//@T@/$t}"; f="${f//@T@/$t}"
  case "$rc" in
    0) ev "$p" ;;
    1) ev "$f"; OK=0 ;;
    *) ev "$f [INCONCLUSIVE: ${P_DETAIL:-rc=$rc}]"; INCONC=1 ;;
  esac
  return "$rc"
}
fail_op() { ev "$*"; ERR=1; }
finish() { # ac [extra evidence]
  [ -n "${2:-}" ] && ev "$2"
  if [ "$ERR" = 1 ]; then result "$1" ERROR "$EV"
  elif [ "$OK" = 0 ]; then result "$1" FAIL "$EV"
  elif [ "$INCONC" = 1 ]; then result "$1" INCONCLUSIVE "$EV"
  else result "$1" PASS "$EV"; fi
}

# ---------------------------------------------------------------------------------------------- helpers
# Poll cmd until it succeeds; returns 0, or the LAST exit code of cmd (1 = contradicts, 2 = inconclusive).
eventually() { # timeout interval cmd...
  local t="$1" i="$2" rc end=$((SECONDS + $1)); shift 2
  while :; do
    "$@" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$SECONDS" -ge "$end" ] && return "$rc"
    sleep "$i"
  done
}

# The CEL generator function is generator.apply() in Kyverno >= 1.18 and generator.Apply() in 1.17
# (pkg/cel/libs/generator/lib.go). The manifests use the 1.18 spelling; preflight picks the one the
# cluster's Kyverno understands. SPIKE_GEN_FN overrides it.
GEN_FN="${SPIKE_GEN_FN:-apply}"
# SPIKE_GPOL_WEBHOOK=finegrained gives every kit GeneratingPolicy its own admission webhook instead of the shared
# basic-path gpol.validate.kyverno.svc-ignore: a policy with webhookConfiguration.timeoutSeconds is fine-grained
# (kyverno pkg/controllers/webhook/validating.go:22-34, v1.17.0 and v1.18.2). Default: shared (as shipped).
GPOL_WEBHOOK="${SPIKE_GPOL_WEBHOOK:-shared}"
GPOL_TIMEOUT="${SPIKE_GPOL_TIMEOUT:-10}"
case "$GPOL_WEBHOOK" in
  shared|finegrained) ;;
  *) echo "SPIKE_GPOL_WEBHOOK must be shared or finegrained, got: $GPOL_WEBHOOK" >&2; exit 2 ;;
esac
case "$GPOL_TIMEOUT" in
  ''|*[!0-9]*) echo "SPIKE_GPOL_TIMEOUT must be a number of seconds (1-30), got: $GPOL_TIMEOUT" >&2; exit 2 ;;
esac
apply_gpol() { # file
  if [ "$GPOL_WEBHOOK" = finegrained ]; then
    sed -e "s/generator\.apply(/generator.${GEN_FN}(/g" \
        -e "s/^spec:\$/spec:\\
  webhookConfiguration:\\
    timeoutSeconds: ${GPOL_TIMEOUT}/" "$1" | K apply -f - >/dev/null
  else
    sed "s/generator\.apply(/generator.${GEN_FN}(/g" "$1" | K apply -f - >/dev/null
  fi
}

apply_manifest() { # file
  if [ "$IMAGE" != "$IMAGE_DEFAULT" ]; then
    sed "s|${IMAGE_DEFAULT}|${IMAGE}|g" "$1" | K apply -f - >/dev/null
  else
    K apply -f "$1" >/dev/null
  fi
}

# Existence that distinguishes NotFound from every other kubectl error: 0 exists, 1 NotFound, 2 error (P_DETAIL set).
kexists() { # kind name [ns]
  local nsarg=() err rc
  [ -n "${3:-}" ] && nsarg=(-n "$3")
  err="$(K "${nsarg[@]+"${nsarg[@]}"}" get "$1" "$2" -o name 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  case "$err" in
    *"(NotFound)"*|*"doesn't have a resource type"*) return 1 ;;
  esac
  P_DETAIL="kubectl get $1/$2 failed: $(echo "$err" | head -n1)"
  return 2
}
gone() { kexists "$@"; case $? in 0) return 1 ;; 1) return 0 ;; *) return 2 ;; esac; }
OWNER_OUT=""
owner_label() { # kind name [ns] -> OWNER_OUT = label value; return 1 NotFound, 2 error (P_DETAIL set). No subshell: P_DETAIL survives.
  local nsarg=() rc
  OWNER_OUT=""
  kexists "$@"; rc=$?
  [ "$rc" -ne 0 ] && return "$rc"
  [ -n "${3:-}" ] && nsarg=(-n "$3")
  OWNER_OUT="$(K "${nsarg[@]+"${nsarg[@]}"}" get "$1" "$2" -o jsonpath='{.metadata.labels.spike\.giantswarm\.io/owner}' 2>/dev/null)" || { P_DETAIL="cannot read the owner label of $1/$2"; return 2; }
  return 0
}
# The only delete-by-name in the kit: refuses when the object exists without the owner label (or cannot be read).
delete_owned() { # kind name [ns]
  local rc nsarg=()
  [ -n "${3:-}" ] && nsarg=(-n "$3")
  owner_label "$@"; rc=$?
  [ "$rc" -eq 1 ] && return 0
  if [ "$rc" -ne 0 ]; then echo "REFUSING to delete $1/$2: cannot read it (${P_DETAIL:-kubectl error})" >&2; return 1; fi
  if [ "$OWNER_OUT" != "$OWNER_VAL" ]; then
    echo "REFUSING to delete $1/$2: it does not carry ${OWNER_SEL}" >&2
    return 1
  fi
  K "${nsarg[@]+"${nsarg[@]}"}" delete "$1" "$2" --ignore-not-found >/dev/null 2>&1
}

pod_ip() { K -n "$1" get pod "$2" -o jsonpath='{.status.podIP}' 2>/dev/null; }
pod_ready() { [ "$(K -n "$1" get pod "$2" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; }

cnp_exists() { kexists "$CNP" "$2" "$1"; }   # ns name -> 0 exists, 1 absent, 2 error
cnp_gone() { gone "$CNP" "$2" "$1"; }        # ns name -> 0 gone, 1 still there, 2 error
cnp_spec_hash() { K -n "$1" get "$CNP" "$2" -o jsonpath='{.spec}' 2>/dev/null | cksum | cut -d' ' -f1; }
cnp_uids() { K -n "$1" get "$CNP" -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null | sort; }
no_generated() { # ns -> 0 none left, 1 some left, 2 error
  local out
  out="$(K -n "$1" get "$CNP" -o name 2>/dev/null)" || { P_DETAIL="cannot list CNPs in $1"; return 2; }
  if echo "$out" | grep -q "/${KIT}-allow-"; then return 1; fi
  return 0
}
ccnp_gone() { gone "$CCNP" "$1"; }

# Label/annotation writes check kubectl's exit code; a failure is recorded as an ERROR in the current check.
annotate() { K annotate namespace "$1" "policy.giantswarm.io/$2=true" --overwrite >/dev/null || { fail_op "annotating namespace $1 with $2 FAILED"; return 1; }; }
# One annotation per request, 2 s apart (SPIKE_ANNOTATE_GAP): what a controller adding the annotations one at a time does.
# flap and ac4 use this, so they test what they claim; the Kyverno 1.17 bulk-annotation behaviour is isolated in `bulk`.
annotate_each() { local a; for a in $GEN_ANNOTATIONS; do annotate "$1" "$a" || return 1; sleep "${SPIKE_ANNOTATE_GAP:-2}"; done; }
# All six annotations in ONE request = ONE Namespace UPDATE (first real run: Kyverno 1.17 generated all six, then deleted
# all six ~2 min later without regenerating them).
annotate_bulk() { # ns
  local a args=()
  for a in $GEN_ANNOTATIONS; do args+=("policy.giantswarm.io/$a=true"); done
  K annotate namespace "$1" "${args[@]}" --overwrite >/dev/null || { fail_op "annotating namespace $1 with all six annotations in one request FAILED"; return 1; }
}
unannotate() { K annotate namespace "$1" "policy.giantswarm.io/$2-" >/dev/null || { fail_op "removing annotation $2 from namespace $1 FAILED"; return 1; }; }
unannotate_all() { # ns: one request, so one Namespace UPDATE
  local a args=()
  for a in $GEN_ANNOTATIONS; do args+=("policy.giantswarm.io/$a-"); done
  K annotate namespace "$1" "${args[@]}" >/dev/null || { fail_op "removing the annotations from namespace $1 FAILED"; return 1; }
}
set_optout() { K label namespace "$1" "${OPTOUT_LABEL}=false" --overwrite >/dev/null || { fail_op "setting the opt-out label on $1 FAILED"; return 1; }; }
unset_optout() { K label namespace "$1" "${OPTOUT_LABEL}-" >/dev/null || { fail_op "removing the opt-out label from $1 FAILED"; return 1; }; }

# ---- generated vs generated-then-deleted --------------------------------------------------------------
# GEN_SEEN records "ns/name@second" for every kit allow that was seen to exist during the current check, so a later
# absence can be told apart from "never generated" (a kit/Kyverno setup problem) and reported as "generated-then-deleted"
# (the Kyverno 1.17 behaviour of the first real run).
GEN_SEEN=""
gen_seen_reset() { GEN_SEEN=""; }
await_generated() { # ns annotation -> 0 generated (and recorded), else the last rc of the poll (1 absent, 2 error)
  local n rc; n="$(gname "$2")"
  eventually "$SYNC_TIMEOUT" 2 cnp_exists "$1" "$n"; rc=$?
  [ "$rc" -eq 0 ] && GEN_SEEN="$GEN_SEEN $1/$n@$SECONDS"
  return "$rc"
}
lost_allows() { # ns -> prints "name(seen +Ts ago)" for allows seen earlier in this check that are absent now; return 0 when any is lost
  local tok key t nsn found=1 out=""
  for tok in $GEN_SEEN; do
    key="${tok%@*}"; t="${tok#*@}"
    [ "${key%%/*}" = "$1" ] || continue
    nsn="${key#*/}"
    if cnp_exists "$1" "$nsn"; then :; else
      [ "$?" -eq 1 ] && { out="$out ${nsn}(seen $((SECONDS - t))s ago)"; found=0; }
    fi
  done
  echo "${out# }"
  return "$found"
}
count_allows() { K -n "$1" get "$CNP" -o name 2>/dev/null | grep -c "/${KIT}-allow-" || true; }
names_allows() { K -n "$1" get "$CNP" -o name 2>/dev/null | grep "/${KIT}-allow-" | sed "s|.*/${KIT}-allow-||" | sort | tr '\n' ',' | sed 's/,$//'; }

# ---- Kyverno UpdateRequests and background-controller log, as evidence ---------------------------------
# UpdateRequests (kyverno.io, namespaced in `kyverno`) are what the admission webhook hands to the background controller.
ur_count() { # -> number, or ? when they cannot be listed
  local out
  out="$(K -n kyverno get updaterequests.kyverno.io -o name 2>&1)" || { echo "?"; return 0; }
  printf '%s\n' "$out" | grep -c '/' || true
}
ur_dump() { # file label: append the current UpdateRequests (name policy state resource) to the evidence file
  {
    echo "--- UpdateRequests in kyverno ($2) at $(date +%H:%M:%S)"
    K -n kyverno get updaterequests.kyverno.io \
      -o jsonpath='{range .items[*]}{.metadata.name}{" policy="}{.spec.policy}{" type="}{.spec.requestType}{" state="}{.status.state}{" resource="}{.spec.resource.kind}{"/"}{.spec.resource.namespace}{"/"}{.spec.resource.name}{" created="}{.metadata.creationTimestamp}{"\n"}{end}' 2>&1
  } >> "$1"
}
# background-controller log lines of the last $3 seconds that mention $2 (the policy name or the kit prefix), appended to $1.
# Echoes the number of matching lines. --tail=-1 because kubectl defaults to 10 lines when a selector is used.
bgc_log_hits() { # file pattern seconds
  local out n
  out="$(K -n kyverno logs -l app.kubernetes.io/component=background-controller --tail=-1 --since="${3}s" --prefix 2>&1)" || { echo "--- background-controller logs unreadable: $(echo "$out" | head -n1)" >> "$1"; echo "?"; return 0; }
  n="$(printf '%s\n' "$out" | grep -cF -- "$2" || true)"
  { echo "--- background-controller log lines matching '$2' in the last ${3}s: ${n}"; printf '%s\n' "$out" | grep -F -- "$2" | tail -n 40; } >> "$1"
  echo "$n"
}

# ---- the one reachability helper -------------------------------------------------------------------
# expect_reach / expect_blocked CLIENT_NS TARGET   (TARGET = namespace of a `server` pod, or a full URL)
# expect_dns_works / expect_dns_blocked NS [POD]
# Return 0 = as expected, 1 = the opposite was observed, 2 = INCONCLUSIVE (pods not Ready, no server IP, curl
# connection refused, kubectl exec/dig failure ...). A probe that could not run is never counted as "blocked".
# Details land in P_DETAIL; the last curl result in P_STATE/P_CODE.
P_DETAIL=""; P_STATE=""; P_CODE=""
probe_http() { # client_ns url -> P_STATE reach|blocked|refused|error
  local out rc
  out="$(K -n "$1" exec client -- curl -s -k -m "$CURL_TIMEOUT" -o /dev/null -w '%{http_code}' "$2" 2>/dev/null)"; rc=$?
  P_CODE="${out:-none}"
  case "$rc" in
    0|35|52|56|60) P_STATE=reach; P_DETAIL="connected (curl rc=$rc http=$P_CODE)" ;;
    28) P_STATE=blocked; P_DETAIL="timeout (curl rc=28)" ;;
    7) P_STATE=refused; P_DETAIL="connection refused (curl rc=7): the peer answered, this is not a policy drop" ;;
    *) P_STATE=error; P_DETAIL="probe could not run (kubectl exec / curl rc=$rc)" ;;
  esac
}
P_URL=""
probe_url() { # client_ns target -> sets P_URL; return 2 + P_DETAIL when a precondition fails
  local cns="$1" t="$2" ip
  P_URL=""
  if ! pod_ready "$cns" client; then P_DETAIL="client pod in $cns not Ready"; return 2; fi
  case "$t" in
    http://*|https://*) P_URL="$t" ;;
    *)
      if ! pod_ready "$t" server; then P_DETAIL="server pod in $t not Ready"; return 2; fi
      ip="$(pod_ip "$t" server)"
      if [ -z "$ip" ]; then P_DETAIL="server pod in $t has no pod IP"; return 2; fi
      P_URL="http://${ip}:8080/" ;;
  esac
}
check_state() { # want cns target
  local want="$1"
  probe_url "$2" "$3" || return 2
  probe_http "$2" "$P_URL"
  case "$P_STATE:$want" in
    reach:reach|blocked:blocked) return 0 ;;
    reach:blocked|blocked:reach) return 1 ;;
    *) return 2 ;;
  esac
}
expect_reach() { check_state reach "$@"; }
expect_blocked() { check_state blocked "$@"; }

DNS_STATE=""; DNS_IP=""
dns_query() { # ns [pod] [name] -> DNS_STATE resolved|timeout|refused|servfail|nxdomain|error, DNS_IP
  local ns="$1" pod="${2:-client}" name="${3:-kubernetes.default.svc.${CLUSTER_DOMAIN}}" out rc
  DNS_IP=""
  if ! pod_ready "$ns" "$pod"; then DNS_STATE=error; P_DETAIL="pod $ns/$pod not Ready"; return 2; fi
  out="$(K -n "$ns" exec "$pod" -- dig +time=2 +tries=1 "$name" 2>&1)"; rc=$?
  DNS_IP="$(echo "$out" | awk '$4=="A" && $5 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $5; exit}')"
  if [ -n "$DNS_IP" ] && echo "$out" | grep -q 'status: NOERROR'; then DNS_STATE=resolved
  elif echo "$out" | grep -q 'no servers could be reached'; then
    # "no servers could be reached" also follows "connection refused" and "unreachable": only an explicit timeout
    # without any refused/unreachable is a drop; anything else is not evidence of a block
    if echo "$out" | grep -q 'timed out' && ! echo "$out" | grep -Eqi 'refused|unreachable'; then DNS_STATE=timeout; else DNS_STATE=unreachable; fi
  elif echo "$out" | grep -q 'status: REFUSED'; then DNS_STATE=refused
  elif echo "$out" | grep -q 'status: SERVFAIL'; then DNS_STATE=servfail
  elif echo "$out" | grep -q 'status: NXDOMAIN'; then DNS_STATE=nxdomain
  else DNS_STATE=error
  fi
  P_DETAIL="dig $name in $ns/$pod: ${DNS_STATE} (rc=$rc)"
  case "$DNS_STATE" in error|unreachable) P_DETAIL="$P_DETAIL, output: $(echo "$out" | head -n3 | tr '\n' ' ')" ;; esac
  return 0
}
expect_dns_works() { # ns [pod]
  dns_query "$1" "${2:-client}" || return 2
  case "$DNS_STATE" in resolved) return 0 ;; timeout|refused|servfail|nxdomain) return 1 ;; *) return 2 ;; esac
}
expect_dns_blocked() { # ns [pod]: needs an explicit timeout; refused/servfail/exec failure/missing dig are inconclusive
  dns_query "$1" "${2:-client}" || return 2
  case "$DNS_STATE" in timeout) return 0 ;; resolved) return 1 ;; *) return 2 ;; esac
}

# ---- cilium agent exec ------------------------------------------------------------------------------
agent_pods() { K -n kube-system get pods -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.name} {.status.hostIP}{"\n"}{end}' 2>/dev/null; }
first_agent() { agent_pods | head -n1 | cut -d' ' -f1; }
agent_on_node() { # node name -> the cilium agent pod running on that node (empty when none)
  K -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$1" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1
}
# `cilium-dbg status` "Cluster health: N/M reachable" of one agent -> prints "N M" (nothing when it cannot be read).
# The output is captured first and parsed afterwards: no early-closing pipe reader.
cluster_health_of() { # agent pod
  local out line
  out="$(agent_exec "$1" status)" || return 1
  line="$(printf '%s\n' "$out" | grep -i 'cluster health' | head -n1)"
  printf '%s\n' "$line" | sed -n 's/.*[Cc]luster health:[[:space:]]*\([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\1 \2/p'
}
# Does an identity block of `cilium-dbg identity list [--endpoints]` output carry BOTH the pod-namespace label of $2 AND the
# namespace opt-out label? Output format (cilium pkg/identity/cache/cache.go:36-55 FormatIdentities, labels printed as
# `<source>:<key>[=<value>]` sorted, pkg/labels/labels.go:469-474; --endpoints adds a REFCOUNT column on the first line,
# pkg/identity/identitymanager/manager.go:244-263):
#   ID      LABELS
#   12345   k8s:app=client
#           k8s:io.cilium.k8s.namespace.labels.policy.giantswarm.io/default-deny=false
#           k8s:io.kubernetes.pod.namespace=ddn-spike-a
# A block starts at a line whose first field is a number; the following lines belong to it. Namespace labels are part of
# the default identity label set (pkg/labelsfilter/filter.go:229), so the label shows up as
# `k8s:io.cilium.k8s.namespace.labels.<namespace label key>=<value>`.
identity_carries_optout() { # file namespace
  awk -v ns="$2" -v opt="io.cilium.k8s.namespace.labels.${OPTOUT_LABEL}=false" '
    function flush() { if (hasns && hasopt) found = 1; hasns = 0; hasopt = 0 }
    { lab = $1
      if ($1 ~ /^[0-9]+$/ && NF >= 2) { flush(); lab = $2 }
      sub(/^[^:=]+:/, "", lab)          # drop the label source (k8s:, reserved:, ...)
      if (lab == "io.kubernetes.pod.namespace=" ns) hasns = 1
      if (lab == opt) hasopt = 1 }
    END { flush(); exit !found }' "$1"
}
AC1_ID_FILE=""; AC1_ID_MODE=""
# 0 = found; 1 = identities were read but none carries both labels; 2 = no identity output could be read.
# The agent output is captured into a variable and written to the evidence file BEFORE it is searched. (The first real run
# piped `agent_exec ... | grep -q`; with `set -o pipefail` an early-closing grep can fail the whole pipeline when the exec'd
# command is still writing, which reads as "label not found". Whether that happened there cannot be proven offline.)
ac1_read_identity() { # agent
  local ag="$1" out mode rc=2
  : > "$AC1_ID_FILE"
  for mode in "identity list --endpoints" "identity list"; do
    # shellcheck disable=SC2086 # mode is intentionally word-split
    out="$(agent_exec "$ag" $mode)" || continue
    [ -n "$out" ] || continue
    { echo "### $ag: cilium-dbg $mode"; printf '%s\n' "$out"; } >> "$AC1_ID_FILE"
    rc=1
    if printf '%s\n' "$out" > "$AC1_ID_FILE.cur" && identity_carries_optout "$AC1_ID_FILE.cur" "$NS_A"; then AC1_ID_MODE="$mode"; rm -f "$AC1_ID_FILE.cur"; return 0; fi
  done
  rm -f "$AC1_ID_FILE.cur"
  return $rc
}
# The single place that knows how to reach the cilium CLI in an agent pod (cilium-dbg with/without -c, old `cilium`).
# AGENT_TIMEOUT=N bounds both the in-container command (timeout N) and the local kubectl exec, so nothing outlives N s.
agent_exec() { # pod args...
  local pod="$1" v cflag bin lim="${AGENT_TIMEOUT:-}" rc w wraps="plain" wrap=()
  shift
  [ -n "$lim" ] && wraps="remote plain"
  for w in $wraps; do
    wrap=()
    [ "$w" = remote ] && wrap=(timeout "$lim")
    for v in "-c cilium-agent|cilium-dbg" "|cilium-dbg" "-c cilium-agent|cilium"; do
      cflag="${v%%|*}"; bin="${v##*|}"
      # shellcheck disable=SC2086 # cflag is intentionally word-split ("-c cilium-agent" or empty)
      if [ -n "$lim" ]; then
        run_bounded $((lim + 5)) kubectl "${KARGS[@]+"${KARGS[@]}"}" -n kube-system exec "$pod" $cflag -- ${wrap[@]+"${wrap[@]}"} "$bin" "$@" 2>/dev/null
      else
        kubectl "${KARGS[@]+"${KARGS[@]}"}" -n kube-system exec "$pod" $cflag -- "$bin" "$@" 2>/dev/null
      fi
      rc=$?
      # 124/137/143 = the bound fired on a command that was running: that is a successful capture
      case "$rc" in 0|124|137|143) return 0 ;; esac
    done
  done
  return 1
}
agent_exec_all() { # outfile args... -> "### agent <pod> (<ip>)" sections; return 0 if at least one agent answered
  local out="$1" pod ip dump any=1
  shift
  : > "$out"
  while read -r pod ip; do
    [ -z "$pod" ] && continue
    dump="$(agent_exec "$pod" "$@")" || continue
    { echo "### agent $pod ($ip)"; echo "$dump"; } >> "$out"
    any=0
  done < <(agent_pods)
  return "$any"
}

snapshot_hostnetwork() {
  K get pods -A -o jsonpath='{range .items[?(@.spec.hostNetwork==true)]}{.metadata.namespace}/{.metadata.name} {.status.phase} ready={.status.containerStatuses[*].ready} restarts={.status.containerStatuses[*].restartCount}{"\n"}{end}' \
    2>/dev/null | sort > "$1"
}
not_ready_names() { # snapshot file -> sorted pod names that are not Running+ready (completed pods ignored)
  awk '$2=="Succeeded"{next} $2!="Running"{print $1; next} {l=$0; sub(/ restarts=.*/,"",l); if (l ~ /false/) print $1}' "$1" | sort -u
}

# Remove annotations/labels/policies that a previous function left behind so each function starts clean, and wait
# until the generated CNPs are really gone (Kyverno synchronize deletes them asynchronously).
reset_state() {
  local ns left rc
  ERR=0; EV=""
  for ns in "$NS_A" "$NS_B" "$NS_ALL" "$NS_WEBHOOK"; do
    kexists namespaces "$ns"; rc=$?
    case "$rc" in
      1) continue ;;
      2) fail_op "reset: $P_DETAIL"; continue ;;
    esac
    unannotate_all "$ns"
    unset_optout "$ns"
  done
  delete_owned "$CCNP" "$DNS_ALLOW_NAME" || fail_op "reset: could not delete $DNS_ALLOW_NAME"
  delete_owned "$CNP" "$FQDN_CNP" "$NS_B" || fail_op "reset: could not delete $FQDN_CNP"
  if [ "$HAVE_GPOL" = 1 ]; then
    for ns in "$NS_A" "$NS_B" "$NS_ALL" "$NS_WEBHOOK"; do
      eventually "$SYNC_TIMEOUT" 2 no_generated "$ns"; rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "WARNING: generated CNPs still present (or unreadable) in $ns after ${SYNC_TIMEOUT}s (is Kyverno healthy?): deleting the kit's own" >&2
        for left in $(K -n "$ns" get "$CNP" -o name 2>/dev/null | grep "/${KIT}-allow-" | sed 's|.*/||'); do delete_owned "$CNP" "$left" "$ns"; done
      fi
    done
  fi
  eventually 60 2 ccnp_gone "$DNS_ALLOW_NAME" || fail_op "reset: $DNS_ALLOW_NAME still present after 60s"
  return 0
}

# ---------------------------------------------------------------------------------------------- Kyverno scale guard
# Kyverno-managed webhooks that would actually get in the way while Kyverno is down: failurePolicy other than Ignore AND
# rules matching Namespaces (the annotation updates of the test), Deployments/scale (the restore itself) or everything.
# Kyverno's own policy/exception/cleanup webhooks are hard-coded Fail (pkg/controllers/webhook/controller.go) but only
# match Kyverno CRDs, so they do not count; the GeneratingPolicy webhook is Ignore (kyverno/api generating_policy.go:60-62).
kyverno_blocking_webhooks() { # prints "<kind>/<webhook>=<failurePolicy>" or "UNKNOWN:<reason>" when the list cannot be read
  local kind out
  for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
    out="$(K get "$kind" -l webhook.kyverno.io/managed-by=kyverno \
      -o jsonpath='{range .items[*]}{range .webhooks[*]}{.name}{"|"}{.failurePolicy}{"|"}{.rules[*].resources}{"\n"}{end}{end}' 2>&1)" \
      || { echo "UNKNOWN:cannot-list-${kind}($(echo "$out" | head -n1))"; continue; }
    # a resource token is "wide" when it starts with * (*, */*, */scale ...) or names Namespaces / Deployments (incl. subresources)
    echo "$out" | awk -F'|' -v k="$kind" 'NF>=3 && $2!="Ignore" { r=$3; gsub(/[^a-z0-9\/*]+/," ",r); n=split(r,a," "); for(i=1;i<=n;i++) if (a[i] ~ /^\*/ || a[i] ~ /^(namespaces|deployments)(\/|$)/) { print k "/" $1 "=" ($2==""?"Fail(default)":$2); break } }'
  done
}
kyverno_state_get() { K -n kyverno get cm "$KYV_CM" -o go-template='{{range $k,$v := .data}}{{$k}} {{$v}}{{"\n"}}{{end}}'; }
kyverno_loud() { # reason
  {
    echo "!! KYVERNO STILL SCALED DOWN ($1)"
    echo "!! recover with: $(cleanup_cmd)"
    echo "!! or by hand: $(kubectl_prefix) -n kyverno scale deploy/<name> --replicas=<n> for every entry of: $(kubectl_prefix) -n kyverno get configmap ${KYV_CM} -o yaml"
  } >&2
}
kyverno_pods_gone() { # 0 no kyverno pod and no ready endpoint address left, 1 still there, 2 error
  local pods eps
  pods="$(K -n kyverno get pods -l app.kubernetes.io/part-of=kyverno -o name 2>/dev/null)" || return 2
  [ -n "$pods" ] && return 1
  eps="$(K -n kyverno get endpoints -l app.kubernetes.io/part-of=kyverno -o jsonpath='{range .items[*]}{.subsets[*].addresses[*].ip}{end}' 2>/dev/null)" || return 2
  [ -n "$eps" ] && return 1
  return 0
}
# Scale ALL Kyverno deployments to 0. Replica counts are stored in an owner-labelled ConfigMap in the kyverno
# namespace, so `cleanup` from any directory/machine restores them. Returns 0 ok, 3 refused by the guard, 4 error.
scale_down_kyverno() {
  local d r bad rc
  kexists configmaps "$KYV_CM" kyverno; rc=$?
  if [ "$rc" -eq 2 ]; then return 4; fi
  if [ "$rc" -eq 0 ]; then
    echo "a previous run left Kyverno scaled down: restoring first"
    restore_kyverno || { P_DETAIL="could not restore the previous scale-down"; return 4; }
  fi
  bad="$(kyverno_blocking_webhooks)"
  if [ -n "$bad" ] && [ "${SPIKE_KYVERNO_SCALE_ALLOW_FAIL_CLOSED:-}" != "true" ]; then
    P_DETAIL="REFUSED to scale Kyverno down: these Kyverno webhooks are not failurePolicy Ignore and match Namespaces/Deployments/wildcards (or could not be read: UNKNOWN), so they would block API requests while Kyverno is down: $(echo "$bad" | head -n5 | tr '\n' ' ')(override: SPIKE_KYVERNO_SCALE_ALLOW_FAIL_CLOSED=true)"
    return 3
  fi
  local data=() list
  list="$(K -n kyverno get deploy -l app.kubernetes.io/part-of=kyverno -o name 2>/dev/null)" || { P_DETAIL="cannot list the kyverno deployments"; return 4; }
  while read -r d; do
    [ -z "$d" ] && continue
    r="$(K -n kyverno get "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || { P_DETAIL="cannot read replicas of $d"; return 4; }
    data+=("--from-literal=${d#*/}=${r:-1}")
  done <<< "$list"
  if [ "${#data[@]}" -eq 0 ]; then P_DETAIL="no kyverno deployments found (label app.kubernetes.io/part-of=kyverno)"; return 4; fi
  KYV_SAVED=""
  for d in "${data[@]}"; do d="${d#--from-literal=}"; KYV_SAVED="${KYV_SAVED}${d%%=*} ${d#*=}"$'\n'; done
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: kyverno\n  labels:\n    %s: %s\ndata:\n' "$KYV_CM" "$OWNER_KEY" "$OWNER_VAL"
    for d in "${data[@]}"; do d="${d#--from-literal=}"; printf '  %s: "%s"\n' "${d%%=*}" "${d#*=}"; done
  } | K create -f - >/dev/null || { P_DETAIL="cannot store the (owner-labelled) replica state"; return 4; }
  KYV_SCALED=1
  while read -r d r; do
    [ -z "$d" ] && continue
    K -n kyverno scale "deploy/$d" --replicas=0 >/dev/null || { P_DETAIL="scaling deploy/$d to 0 failed"; return 4; }
  done <<< "$(kyverno_state_get)"
  return 0
}
# Restore the saved replica counts. Succeeds (and deletes the saved state) only when EVERY saved deployment was scaled
# back; otherwise the state stays, KYV_SCALED stays 1, a loud message with the recovery command is printed, rc 1.
restore_kyverno() {
  local rc v data d r n=0 expect=0 failed=0 have_cm=1 zero
  kexists configmaps "$KYV_CM" kyverno; rc=$?
  if [ "$rc" -eq 2 ]; then KYV_SCALED=1; kyverno_loud "cannot read ConfigMap kyverno/${KYV_CM}: ${P_DETAIL}"; return 1; fi
  if [ "$rc" -eq 1 ]; then
    have_cm=0
    if [ "$KYV_SCALED" != 1 ]; then return 0; fi   # NotFound and this run scaled nothing: nothing was saved
    if [ -n "$KYV_SAVED" ]; then
      echo "ConfigMap kyverno/${KYV_CM} is missing although this run scaled Kyverno down: restoring from the in-memory copy"
      data="$KYV_SAVED"
    else
      zero="$(K -n kyverno get deploy -l app.kubernetes.io/part-of=kyverno -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>&1)" \
        || { kyverno_loud "ConfigMap missing, no in-memory copy, and the deployments cannot be listed: ${zero}"; return 1; }
      if echo "$zero" | awk '$2=="0"{f=1} END{exit !f}'; then
        kyverno_loud "ConfigMap kyverno/${KYV_CM} is missing, there is no in-memory copy, and these deployments are at 0 replicas: $(echo "$zero" | awk '$2=="0"{print $1}' | tr '\n' ' ')"
        return 1
      fi
      KYV_SCALED=0; return 0
    fi
  else
    owner_label configmaps "$KYV_CM" kyverno; rc=$?
    if [ "$rc" -ne 0 ]; then KYV_SCALED=1; kyverno_loud "cannot read the owner label of ConfigMap kyverno/${KYV_CM}: ${P_DETAIL}"; return 1; fi
    v="$OWNER_OUT"
    if [ "$v" != "$OWNER_VAL" ]; then KYV_SCALED=1; kyverno_loud "ConfigMap kyverno/${KYV_CM} exists but is not owned by the kit"; return 1; fi
    data="$(kyverno_state_get)" || { KYV_SCALED=1; kyverno_loud "cannot read the saved replica counts"; return 1; }
  fi
  while read -r d r; do
    [ -z "$d" ] && continue
    expect=$((expect + 1))
    if K -n kyverno scale "deploy/$d" --replicas="$r" >/dev/null; then n=$((n + 1)); else failed=1; echo "failed to scale deploy/$d back to $r" >&2; fi
  done <<< "$data"
  if [ "$failed" -ne 0 ] || [ "$expect" -eq 0 ] || [ "$n" -ne "$expect" ]; then
    KYV_SCALED=1
    kyverno_loud "scaled back ${n} of ${expect} saved deployments"
    return 1
  fi
  # fresh rollout status (observedGeneration / updatedReplicas / available), not a stale Available condition
  while read -r d r; do
    [ -z "$d" ] && continue
    K -n kyverno rollout status "deploy/$d" --timeout=300s >/dev/null 2>&1 || echo "WARNING: deploy/$d not fully rolled out after 300s (replicas restored)" >&2
  done <<< "$data"
  KYV_SCALED=0
  KYV_SAVED=""
  if [ "$have_cm" = 1 ] && ! delete_owned configmaps "$KYV_CM" kyverno; then
    echo "WARNING: Kyverno replicas are restored, but the saved-state ConfigMap kyverno/${KYV_CM} could not be deleted: delete it by hand ($(kubectl_prefix) -n kyverno delete configmap ${KYV_CM}); a stale copy only triggers a harmless re-restore next time" >&2
  fi
  echo "Kyverno replica counts restored (${n} deployments)"
  return 0
}

# ---------------------------------------------------------------------------------------------- setup
# Names the kit creates. Anything that already exists under one of these names WITHOUT the owner label is foreign, and
# an object that cannot be read (kubectl error other than NotFound) is reported too: the preflight refuses on both.
foreign_objects() {
  local a out="" ns
  chk() { # kind name [ns]
    local rc
    owner_label "$@"; rc=$?
    case "$rc" in
      0) [ "$OWNER_OUT" = "$OWNER_VAL" ] || out="$out FOREIGN:${1%%.*}/$2${3:+(ns $3)}" ;;
      2) out="$out UNREADABLE:${1%%.*}/$2${3:+(ns $3)}" ;;
    esac
  }
  chk "$CCNP" "$DENY_NAME"; chk "$CCNP" "$DNS_ALLOW_NAME"
  chk "$CROLE" "$RBAC_NAME"; chk "$VWC" "$WEBHOOK_CFG"
  for ns in "$NS_A" "$NS_B" "$NS_OPTOUT" "$NS_ALL" "$NS_WEBHOOK" "$NS_BULK" "$NS_SEQ"; do chk namespaces "$ns"; done
  chk configmaps "$KYV_CM" kyverno
  chk pods "$DNS_PROBE_POD" kube-system; chk pods "$DNS_PROBE_POD" giantswarm
  for a in $GEN_ANNOTATIONS; do chk "$GPOL" "$(gname "$a")"; done
  echo "$out"
}

# Policies that could allow ingress to a set of pods, as "<type>/<name>|<selector>|<ingress>" lines.
policy_lines() { # namespace(or "") ; stdout
  local f='{range .items[*]}{.metadata.name}{"|"}{.spec.SEL}{"|"}{.spec.ingress}{"\n"}{end}' ns="$1"
  if [ -n "$ns" ]; then
    K -n "$ns" get networkpolicies.networking.k8s.io -o jsonpath="${f/SEL/podSelector}" 2>/dev/null | sed 's/^/NetworkPolicy\//'
    K -n "$ns" get "$CNP" -l "!${OWNER_KEY}" -o jsonpath="${f/SEL/endpointSelector}" 2>/dev/null | grep -v '|\[{}\]$' | sed 's/^/CiliumNetworkPolicy\//'
  fi
  K get "$CCNP" -l "!${OWNER_KEY}" -o jsonpath="${f/SEL/endpointSelector}" 2>/dev/null | grep -v '|\[{}\]$' | sed 's/^/CiliumClusterwideNetworkPolicy\//'
}
# ---- parsing the JSON that `kubectl -o jsonpath='{.spec.ingress}'` prints --------------------------------------------------
# awk helpers shared by the two candidate finders below. A policy's ingress is a JSON array of rule objects; each rule is
# examined ON ITS OWN, so a rule's source and its ports always stay together (a CNP rule with several toPorts entries holds
# `]},{` inside it, which a text split on that sequence would cut in the middle).
#   split_rules(s, rules)  splits a top-level JSON array into its object elements (string- and nesting-aware), returns the count
#   ports_state(x, want, named)  1 = the rule's ports cover a wanted port (or the rule has no port restriction),
#                                0 = they do not, 2 = a named port (`"port":"https"`) could not be resolved and nothing else covers
#   `want` is a space separated list of port numbers; `named` is "name=containerPort name=containerPort ..." read from the target
#   pods, so a named port is resolved against the container ports of the pod the policy is meant for.
AWK_JSON_LIB='
function split_rules(s, rules,   i, c, depth, instr, esc, start, n) {
  n = 0; depth = 0; instr = 0; esc = 0; start = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (instr) { if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") instr = 0; continue }
    if (c == "\"") { instr = 1; continue }
    if (c == "[" || c == "{") { depth++; if (depth == 2 && c == "{") start = i; continue }
    if (c == "]" || c == "}") { if (depth == 2 && c == "}") rules[++n] = substr(s, start, i - start + 1); depth--; continue }
  }
  return n
}
function port_cover(x, want, named,   o, v, e, lo, hi, res, k, w, nw, ws, nt, toks, parts, found) {
  res = 0; nw = split(want, ws, " "); nt = split(named, toks, " ")
  while (match(x, /\{[^{}]*"port":[^{}]*\}/)) {
    o = substr(x, RSTART, RLENGTH); x = substr(x, RSTART + RLENGTH)
    if (!match(o, /"port":("[^"]*"|[0-9]+)/)) continue
    v = substr(o, RSTART + 7, RLENGTH - 7); gsub(/"/, "", v)
    e = ""
    if (match(o, /"endPort":[0-9]+/)) e = substr(o, RSTART + 10, RLENGTH - 10)
    if (v ~ /^[0-9]+$/) {
      lo = v + 0; hi = (e == "" ? lo : e + 0)
      for (w = 1; w <= nw; w++) if (ws[w] + 0 >= lo && ws[w] + 0 <= hi) res = 1
    } else {
      found = 0
      for (k = 1; k <= nt; k++) { split(toks[k], parts, "="); if (parts[1] == v) { found = 1; for (w = 1; w <= nw; w++) if (parts[2] + 0 == ws[w] + 0) res = 1 } }
      if (!found) UNRES = 1
    }
  }
  return res
}
function ports_state(x, want, named,   r) {
  if (x !~ /"(toPorts|ports)":/ || x !~ /"port":/) return 1
  UNRES = 0
  r = port_cover(x, want, named)
  if (r == 1) return 1
  return UNRES ? 2 : 0
}
'
# "name=containerPort ..." of the containers of the pods a selector matches (to resolve named ports in policies)
named_ports() { # namespace selector
  K -n "$1" get pods -l "$2" -o jsonpath='{range .items[*]}{range .spec.containers[*]}{range .ports[*]}{.name}{"="}{.containerPort}{"\n"}{end}{end}{end}' 2>/dev/null \
    | awk -F= 'NF==2 && $1!="" {print}' | sort -u | tr '\n' ' '
}
# Does anything allow ingress to the CoreDNS pods? The clusterwide deny selects kube-system including CoreDNS with an
# empty ingress rule and the kit adds no ingress allow for it, so DNS only works if the stack ships one.
# STRONG = selects the CoreDNS/kube-dns/node-cache pods and a rule has no port restriction or covers 53/1053 (numeric, or a
#          named port that resolves to one of them on the CoreDNS pods), or has an empty selector AND such a port restriction.
# WEAK = a selector match without such a rule (empty selector with some other ingress, or a named port that could not be
#        resolved): that is not proof that DNS is allowed.
coredns_ingress_candidates() {
  local named
  named="$(named_ports kube-system 'k8s-app in (coredns,kube-dns,k8s-dns-node-cache)')"
  policy_lines kube-system | awk -F'|' -v named="$named" "$AWK_JSON_LIB"'
    $3 == "" || $3 == "[]" {next}
    { sel = ($2 ~ /coredns|kube-dns|k8s-dns-node-cache/); empty = ($2 == "{}" || $2 == "map[]")
      if (!sel && !empty) next
      n = split_rules($3, rules)
      if (n == 0) { print "WEAK " $1 " (ingress not parsed)"; next }
      strong = 0; unres = 0
      for (i = 1; i <= n; i++) {
        restricted = (rules[i] ~ /"(toPorts|ports)":/ && rules[i] ~ /"port":/)
        st = ports_state(rules[i], "53 1053", named)
        if (st == 1 && (sel || (empty && restricted))) strong = 1
        if (st == 2) unres = 1
      }
      if (strong) print "STRONG " $1
      else print "WEAK " $1 (unres ? " (named port not resolvable on the CoreDNS pods: unconfirmed)" : "") }'
}
# Port the API server really reaches on the Kyverno admission controller. Only the admission service counts (the port
# named "https" of kyverno-svc; never the metrics service that carries the same component label). A named targetPort is
# resolved through the admission-controller container port of that name; default 9443.
kyverno_admission_port() {
  local svc tp p
  svc="$(K -n kyverno get svc -l app.kubernetes.io/component=admission-controller \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .spec.ports[*]}{.name}{":"}{.targetPort}{","}{end}{"\n"}{end}' 2>/dev/null)"
  tp="$(echo "$svc" | awk -F'|' '{n=split($2,a,","); for(i=1;i<=n;i++){split(a[i],b,":"); if(b[1]=="https"){print b[2]; exit}}}')"
  [ -n "$tp" ] || tp="$(echo "$svc" | awk -F'|' '$1=="kyverno-svc"{split($2,a,","); split(a[1],b,":"); print b[2]; exit}')"
  if echo "$tp" | grep -Eq '^[0-9]+$'; then echo "$tp"; return 0; fi
  if [ -n "$tp" ]; then
    p="$(K -n kyverno get deploy -l app.kubernetes.io/component=admission-controller \
      -o jsonpath='{range .items[*].spec.template.spec.containers[*].ports[*]}{.name}{":"}{.containerPort}{"\n"}{end}' 2>/dev/null \
      | awk -F: -v n="$tp" '$1==n{print $2; exit}')"
    if echo "$p" | grep -Eq '^[0-9]+$'; then echo "$p"; return 0; fi
  fi
  echo 9443
}
# Can the API server reach the Kyverno admission controller under the deny? Kyverno's webhook (also the GeneratingPolicy
# one) needs ingress on the admission port from the API server. A rule must cover BOTH the port and a source:
#   CNP: fromEntities kube-apiserver / remote-node / host / cluster / all; or fromCIDR / fromCIDRSet (printed with a note:
#        the CIDR must cover the API server, this is not checked)
#   NetworkPolicy: an ipBlock (same note) or no `from` at all (every source)
# The port is numeric, or named (e.g. "https") and then resolved against the container ports of the admission-controller pods;
# a named port that does not resolve is reported as WEAK (unconfirmed), never as a match.
# The selector must target the admission controller: component admission-controller, the Kyverno name/instance labels when
# no component is given, or an empty selector. kyverno-app ships a CNP for it.
# Output lines: "STRONG <policy> [note]" or "WEAK <policy> <reason>".
kyverno_ingress_candidates() {
  local port named
  port="$(kyverno_admission_port)"
  named="$(named_ports kyverno 'app.kubernetes.io/component=admission-controller')"
  policy_lines kyverno | awk -F'|' -v port="$port" -v named="$named" "$AWK_JSON_LIB"'
    $3 == "" || $3 == "[]" {next}
    { sel = 0
      if ($2 == "{}" || $2 == "map[]") sel = 1
      else if ($2 ~ /"app.kubernetes.io\/component":"[^"]*"/) sel = ($2 ~ /"app.kubernetes.io\/component":"admission-controller"/)
      else sel = ($2 ~ /"app.kubernetes.io\/(name|instance|part-of)":"kyverno"/)
      if (!sel) next
      np = ($1 ~ /^NetworkPolicy\//); n = split_rules($3, rules)
      if (n == 0) { print "WEAK " $1 " (ingress not parsed)"; next }
      ok = 0; cidr = 0; unres = 0
      for (i = 1; i <= n; i++) { x = rules[i]; c = 0
        if (np) { src = (x !~ /"from":/); if (x ~ /"ipBlock"/) { src = 1; c = 1 } }
        else    { src = (x ~ /"fromEntities":\[[^]]*"(kube-apiserver|remote-node|host|cluster|all)"/); if (x ~ /"fromCIDR(Set)?"/) { src = 1; c = 1 } }
        st = ports_state(x, port, named)
        if (src && st == 1) { ok = 1; if (c) cidr = 1 }
        else if (src && st == 2) unres = 1 }
      if (ok) print "STRONG " $1 (cidr ? " (CIDR source: must cover the API server)" : "")
      else if (unres) print "WEAK " $1 " (named port not resolvable on the admission controller pods: unconfirmed)" }'
}

preflight() {
  echo "== preflight"
  resolve_context || return 1
  local server foreign cand strong weak kcand kall kweak rc
  server="$(K config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  echo "context: ${KCTX}   server: ${server:-?}   provider: ${PROVIDER}"
  K get ns kube-system >/dev/null 2>&1 || { echo "cluster unreachable" >&2; return 1; }
  K get crd ciliumclusterwidenetworkpolicies.cilium.io >/dev/null 2>&1 \
    || { echo "CCNP CRD missing: is Cilium installed?" >&2; return 1; }
  if K get crd generatingpolicies.policies.kyverno.io >/dev/null 2>&1; then
    HAVE_GPOL=1
    echo "GeneratingPolicy CRD versions: $(K get crd generatingpolicies.policies.kyverno.io -o jsonpath='{range .spec.versions[*]}{.name}{"(served="}{.served}{",storage="}{.storage}{") "}{end}')"
  else
    HAVE_GPOL=0
    echo "WARNING: GeneratingPolicy CRD missing (kyverno-crds / security-bundle not installed): generate checks will be MANUAL"
  fi
  echo "kyverno image(s): $(K -n kyverno get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{" "}{end}' 2>/dev/null)"
  if [ -z "${SPIKE_GEN_FN:-}" ]; then
    kyv_minor="$(K -n kyverno get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
      | sed -n 's|.*/kyverno:v1\.\([0-9][0-9]*\)\..*|\1|p' | head -n 1)"
    if [ -n "$kyv_minor" ] && [ "$kyv_minor" -lt 18 ]; then GEN_FN=Apply; fi
    echo "kyverno minor version: ${kyv_minor:-unknown} -> CEL generator.${GEN_FN}() (override with SPIKE_GEN_FN)"
  fi
  echo "kyverno CiliumNetworkPolicies: $(K -n kyverno get "$CNP" -o name 2>/dev/null | tr '\n' ' ')"

  foreign="$(foreign_objects)"
  if [ -n "$foreign" ]; then
    echo "REFUSING: objects the kit would create already exist without the owner label ${OWNER_SEL} (FOREIGN) or cannot be read (UNREADABLE):${foreign}" >&2
    echo "         the kit will not touch them: rename or remove them yourself, fix access, or use a different cluster." >&2
    return 1
  fi

  if [ "$HAVE_GPOL" = 1 ]; then
    local fg
    if fg="$(K get "$GPOL" -l "!${OWNER_KEY}" -o name 2>/dev/null)"; then
      fg="$(echo "$fg" | grep '/')"   # only resource names, never kubectl warning lines
      if [ -n "$fg" ]; then
        echo "WARNING: GeneratingPolicies NOT created by the kit exist on this cluster: $(echo "$fg" | sed 's|.*/||' | tr '\n' ' ')" >&2
        echo "         Policies without matchConditions share one basic-path webhook (gpol.validate.kyverno.svc-ignore) with the kit's six;" >&2
        echo "         the kit sets no selector on it, so those policies only ever see MORE Namespace events, never fewer (SOURCES.md)." >&2
      fi
    else
      echo "WARNING: cannot list GeneratingPolicies to look for foreign ones (kubectl get failed)" >&2
    fi
  fi

  cand="$(coredns_ingress_candidates | sort -u)"
  strong="$(echo "$cand" | sed -n 's/^STRONG //p' | tr '\n' ' ')"
  weak="$(echo "$cand" | sed -n 's/^WEAK //p' | tr '\n' ' ')"
  if [ -n "$strong" ]; then
    echo "ingress to CoreDNS: candidate allowing policies found: ${strong}"
  else
    echo "WARNING: no policy allowing ingress to the CoreDNS pods was found (checked NetworkPolicy and CNP in kube-system and all CCNPs)." >&2
    [ -n "$weak" ] && echo "         Found only unconfirmed ones (no matching DNS port, or a named port that does not resolve): ${weak}" >&2
    echo "         The deny selects kube-system including CoreDNS with an empty ingress rule and the kit adds no CoreDNS ingress allow:" >&2
    echo "         cluster DNS would stop working for everybody. coredns-app ships NetworkPolicy kube-system/coredns for this" >&2
    echo "         (helm/coredns-app/templates/np.yaml, see SOURCES.md): is it installed and enabled on this cluster?" >&2
    if [ "${SPIKE_ALLOW_NO_COREDNS_INGRESS:-}" != "true" ]; then
      echo "REFUSING (override with SPIKE_ALLOW_NO_COREDNS_INGRESS=true if you know DNS ingress is allowed some other way)." >&2
      return 1
    fi
  fi
  if K -n kube-system get pods -l k8s-app=k8s-dns-node-cache -o name 2>/dev/null | grep -q .; then
    echo "node-local DNS cache pods present: confirm that an ingress allow for k8s-dns-node-cache exists too (the dns check will show it)"
  fi

  if [ "$HAVE_GPOL" = 1 ] || K -n kyverno get deploy -l app.kubernetes.io/component=admission-controller -o name 2>/dev/null | grep -q .; then
    kall="$(kyverno_ingress_candidates | sort -u)"
    kcand="$(echo "$kall" | sed -n 's/^STRONG //p' | tr '\n' ' ')"
    kweak="$(echo "$kall" | sed -n 's/^WEAK //p' | tr '\n' ';')"
    if [ -n "$kcand" ]; then
      echo "ingress to the Kyverno admission controller: candidate allowing policies: ${kcand}"
    else
      echo "WARNING: no policy was found that lets the API server (kube-apiserver / remote-node / host) reach the Kyverno admission controller in namespace kyverno." >&2
      echo "         Under the deny the GeneratingPolicy webhook (failurePolicy Ignore) would time out and nothing would be generated, which" >&2
      echo "         looks like a failed kit. kyverno-app ships CNP allow-kyverno-admission-controller-talk-to-apiserver for this" >&2
      echo "         (ciliumNetworkPolicy.enabled: true, see SOURCES.md)." >&2
      [ -n "$kweak" ] && echo "         Found only unconfirmed ones (not counted): ${kweak}" >&2
      if [ "${SPIKE_ALLOW_NO_KYVERNO_INGRESS:-}" != "true" ]; then
        echo "REFUSING (override with SPIKE_ALLOW_NO_KYVERNO_INGRESS=true if the API server reaches Kyverno some other way)." >&2
        return 1
      fi
    fi
  fi

  if [ "${SPIKE_CONFIRM:-}" != "$KCTX" ]; then
    echo "REFUSING to apply the clusterwide deny: set SPIKE_CONFIRM=$KCTX to confirm that context '$KCTX' (server ${server:-?}) is a dedicated test cluster." >&2
    return 2
  fi
  return 0
}

setup() {
  preflight; local rc=$?; [ "$rc" -ne 0 ] && return "$rc"
  mkdir -p "$OUTDIR"
  echo "== applying probe workloads"
  TOUCHED=1
  apply_manifest "$M/probes/probes.yaml" || { echo "applying the probe workloads failed" >&2; return 1; }
  local ns f a deny_pre=0 base_taken=0 base_rs="" BASE_HEALTH=""
  for ns in "$NS_A" "$NS_B" "$NS_OPTOUT" "$NS_ALL"; do
    K -n "$ns" wait --for=condition=Ready pod/client pod/server --timeout=180s >/dev/null 2>&1 \
      || { echo "probe pods in $ns not Ready (image pull? set SPIKE_IMAGE)" >&2; return 1; }
  done
  kexists "$CCNP" "$DENY_NAME"; rc=$?
  if [ "$rc" -eq 2 ]; then echo "cannot check for an existing deny: ${P_DETAIL}" >&2; return 1; fi
  if [ "$rc" -eq 0 ]; then
    deny_pre=1
    DENY_APPLIED=1
    echo "== clusterwide deny already applied by a previous run: baseline skipped"
  else
    echo "== baseline (no deny yet): probes must connect"
    expect_reach "$NS_A" "$NS_A" || { echo "baseline probe $NS_A -> $NS_A failed before the deny ($P_DETAIL): fix the cluster first" >&2; return 1; }
    expect_reach "$NS_A" "$NS_B" || { echo "baseline probe $NS_A -> $NS_B failed before the deny ($P_DETAIL)" >&2; return 1; }
    if expect_reach "$NS_A" "$EXTERNAL_URL"; then EXT_BASE=1; else EXT_BASE=0; echo "note: ${EXTERNAL_URL} not reachable even before the deny: the external-blocked assertion will not be made"; fi
    rm -f "$OUTDIR/baseline.meta"
    snapshot_hostnetwork "$OUTDIR/hostnetwork-before.txt"
    BASE_HEALTH="$(capture_cluster_health)"
    echo "cilium cluster health before the deny (agent reachable total): $(echo "$BASE_HEALTH" | tr '\n' ';')"
    base_rs="$(K -n "$NS_A" get pod server -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
    base_taken=1
  fi
  if [ "$HAVE_GPOL" = 1 ]; then
    echo "== applying Kyverno RBAC + GeneratingPolicies"
    K apply -f "$M/kyverno-rbac-ciliumnetworkpolicies.yaml" >/dev/null || { echo "applying the Kyverno RBAC failed" >&2; return 1; }
    for f in "$M"/generatingpolicies/*.yaml; do apply_gpol "$f" || { echo "apply failed: $f" >&2; return 1; }; done
    for a in $GEN_ANNOTATIONS; do
      K wait --for=jsonpath='{.status.conditionStatus.ready}'=true "$GPOL/$(gname "$a")" --timeout=60s >/dev/null 2>&1 \
        || echo "WARNING: GeneratingPolicy $(gname "$a") not ready yet: $(K get "$GPOL" "$(gname "$a")" -o jsonpath='{.status.conditionStatus.message}' 2>/dev/null)"
    done
    echo "GeneratingPolicy webhook mode: ${GPOL_WEBHOOK}; gpol webhooks now: $(K get validatingwebhookconfigurations -o jsonpath='{range .items[*].webhooks[*]}{.name}{"\n"}{end}' 2>/dev/null | grep '^gpol\.' | tr '\n' ' ')"
  fi
  echo "== applying the clusterwide deny (${DENY_NAME})"
  DENY_APPLIED=1
  K apply -f "$M/ccnp-default-deny-all-namespaces.yaml" >/dev/null || { echo "applying the deny failed" >&2; return 1; }
  if [ "$deny_pre" = 0 ]; then
    DENY_AT_SEC=$SECONDS
    if [ "$base_taken" = 1 ]; then
      # ties the pre-deny baseline to THIS deny (uid) and context, so a later run never trusts a stale file
      printf 'ctx=%s\ndenyuid=%s\nserver_restarts=%s\n' "$KCTX" "$(K get "$CCNP" "$DENY_NAME" -o jsonpath='{.metadata.uid}' 2>/dev/null)" "${base_rs:-}" > "$OUTDIR/baseline.meta"
      # one `health=<agent> <reachable> <total>` line per agent that answered before the deny
      echo "$BASE_HEALTH" | sed -n 's/^\([^ ][^ ]*\) \([0-9][0-9]*\) \([0-9][0-9]*\)$/health=\1 \2 \3/p' >> "$OUTDIR/baseline.meta"
    fi
  fi
  sleep "$SETTLE"
  echo "setup done. Rollback of the whole spike: $(cleanup_cmd)"
}

# ---------------------------------------------------------------------------------------------- cleanup
cleanup() {
  CLEANING=1
  trap '' INT TERM HUP   # restore/cleanup must not be interruptible
  resolve_context || return 1
  echo "== cleanup on context ${KCTX}: restoring Kyverno if needed, then deleting only objects labeled ${OWNER_SEL} (clusterwide policies first)"
  local rc=0
  restore_kyverno || rc=1
  local kind ns
  for kind in "$CCNP" "$GPOL" "$VWC" "$CROLE"; do
    K delete "$kind" -l "$OWNER_SEL" --ignore-not-found 2>&1 | sed 's/^/  /'
  done
  for ns in kube-system giantswarm; do
    K -n "$ns" delete pods -l "$OWNER_SEL" --ignore-not-found --wait=false 2>&1 | sed 's/^/  /'
  done
  if [ "$rc" -ne 0 ]; then
    # the saved replica counts are the only way back: keep the ConfigMap (and the namespaces) until Kyverno is restored
    echo "!! Kyverno was NOT restored: keeping ConfigMap kyverno/${KYV_CM} and skipping the namespace deletion. Fix the cause and re-run: $(cleanup_cmd)" >&2
  else
    K -n kyverno delete configmaps -l "$OWNER_SEL" --ignore-not-found 2>&1 | sed 's/^/  /'
    K delete namespaces -l "$OWNER_SEL" --ignore-not-found --wait=true --timeout=300s 2>&1 | sed 's/^/  /'
  fi
  echo "cleanup done. Remaining objects with the owner label (should be none):"
  K get ns,"$CCNP","$GPOL","$CROLE" -l "$OWNER_SEL" --no-headers 2>/dev/null | sed 's/^/  /'
  K get pods -A -l "$OWNER_SEL" --no-headers 2>/dev/null | sed 's/^/  /'
  return "$rc"
}

# ---------------------------------------------------------------------------------------------- functions
# same-namespace traffic denied when unannotated; cross-namespace and internet denied too
same_ns_denied_unannotated() {
  reset_state; begin
  step "same-namespace blocked" "same-namespace NOT blocked" eventually 30 2 expect_blocked "$NS_A" "$NS_A"
  step "cross-namespace blocked" "cross-namespace NOT blocked" eventually 30 2 expect_blocked "$NS_A" "$NS_B"
  if [ "$EXT_BASE" = 1 ]; then
    step "external ${EXTERNAL_URL} blocked" "external ${EXTERNAL_URL} answered" expect_blocked "$NS_A" "$EXTERNAL_URL"
  else
    ev "external ${EXTERNAL_URL} not asserted (no pre-deny baseline proving it was reachable)"
  fi
  step "control: opted-out ns reachable" "control FAILED: opted-out ns not reachable" eventually 30 2 expect_reach "$NS_OPTOUT" "$NS_OPTOUT"
  finish same-ns
}

# ac1: namespace opt-out is kept in Cilium identity labels and a label flip takes effect live, no pod restart
ac1_optout_live_flip() {
  reset_state; begin
  step "unannotated same-namespace denied" "precondition: same-namespace traffic in unannotated $NS_A is not denied (is the clusterwide deny applied? does the selector match?)" \
    eventually 30 2 expect_blocked "$NS_A" "$NS_A" || { finish ac1; return; }
  local uid0 rs0 uid1 rs1 ag node where irc
  uid0="$(K -n "$NS_A" get pod client -o jsonpath='{.metadata.uid}')"; rs0="$(K -n "$NS_A" get pod client -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  set_optout "$NS_A" || { finish ac1; return; }
  step "opt-out label added -> reachable after @T@s" "opt-out label added -> still not reachable after ${FLIP_TIMEOUT}s" eventually "$FLIP_TIMEOUT" 1 expect_reach "$NS_A" "$NS_A"
  uid1="$(K -n "$NS_A" get pod client -o jsonpath='{.metadata.uid}')"; rs1="$(K -n "$NS_A" get pod client -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  # The identity half is checked while the label is set; the label is removed again right after. The identity only exists
  # on nodes that host an endpoint of the namespace, so ask the agent on the node of the probe pod.
  node="$(K -n "$NS_A" get pod client -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
  ag=""; [ -n "$node" ] && ag="$(agent_on_node "$node")"
  where="the agent on the probe pod's node ${node:-?}"
  if [ -z "$ag" ]; then ag="$(first_agent)"; where="the first agent (none found on node ${node:-?}; identities are cluster-global, so this can still work)"; fi
  mkdir -p "$OUTDIR"; AC1_ID_FILE="$OUTDIR/ac1-identity.txt"; AC1_ID_MODE=""
  if [ -n "$ag" ]; then
    eventually 30 2 ac1_read_identity "$ag"; irc=$?
    case "$irc" in
      0) ev "identity of namespace $NS_A on agent $ag (${where}, cilium-dbg ${AC1_ID_MODE}) carries k8s:io.cilium.k8s.namespace.labels.${OPTOUT_LABEL}=false" ;;
      1) ev "agent $ag (${where}): identities were read but none carries both k8s:io.kubernetes.pod.namespace=${NS_A} and k8s:io.cilium.k8s.namespace.labels.${OPTOUT_LABEL}=false (identity half NOT verified; raw output in ${AC1_ID_FILE}; by hand: cilium-dbg endpoint list, then cilium-dbg identity get <id>)"; INCONC=1 ;;
      *) ev "cannot read identities with cilium-dbg identity list on agent $ag: identity half NOT verified (the opt-out label in the identity is only shown behaviourally)"; INCONC=1 ;;
    esac
  else
    ev "no cilium agent exec: identity half NOT verified (the opt-out label in the identity is only shown behaviourally)"; INCONC=1
  fi
  unset_optout "$NS_A" || { finish ac1; return; }
  step "removed -> blocked after @T@s" "label removed -> not blocked within ${FLIP_TIMEOUT}s" eventually "$FLIP_TIMEOUT" 1 expect_blocked "$NS_A" "$NS_A"
  if [ "$uid0" = "$uid1" ] && [ "$rs0" = "$rs1" ]; then ev "pod uid ${uid0} unchanged, restarts ${rs0}->${rs1}"; else ev "pod CHANGED: uid ${uid0}->${uid1} restarts ${rs0}->${rs1}"; OK=0; fi
  finish ac1
}

# The pre-deny baseline (hostnetwork-before.txt, server restart count) is only trusted when baseline.meta ties it to the
# deny that is applied now (same context, same deny uid): never a leftover of an earlier run or another cluster.
BASE_RS=""; BASE_HEALTH=""
# Cilium "Cluster health" of EVERY agent that answers: one "<agent> <reachable> <total>" line each. Taken before the deny (with a
# short wait for N == M, so a freshly started agent is not recorded half way through its first probe round) and again by ac2.
capture_cluster_health() {
  local pod ip h end
  while read -r pod ip; do
    [ -z "$pod" ] && continue
    end=$((SECONDS + ${SPIKE_HEALTH_WAIT:-20}))
    while :; do
      h="$(cluster_health_of "$pod")"
      [ -z "$h" ] && break   # not readable (no exec): nothing to record for this agent
      # shellcheck disable=SC2086 # h is "N M"
      set -- $h
      [ "$1" = "$2" ] && break
      [ "$SECONDS" -ge "$end" ] && break
      sleep 2
    done
    [ -n "$h" ] && echo "$pod $h"
  done < <(agent_pods)
  return 0
}
baseline_valid() { # -> 0 valid (BASE_RS set), 1 not
  local meta="$OUTDIR/baseline.meta" mctx muid cur
  BASE_RS=""
  [ -s "$meta" ] && [ -s "$OUTDIR/hostnetwork-before.txt" ] || return 1
  mctx="$(sed -n 's/^ctx=//p' "$meta")"; muid="$(sed -n 's/^denyuid=//p' "$meta")"
  cur="$(K get "$CCNP" "$DENY_NAME" -o jsonpath='{.metadata.uid}' 2>/dev/null)"
  [ "$mctx" = "$KCTX" ] && [ -n "$muid" ] && [ "$muid" = "$cur" ] || return 1
  BASE_RS="$(sed -n 's/^server_restarts=//p' "$meta")"
  BASE_HEALTH="$(sed -n 's/^health=//p' "$meta")"
  return 0
}

# Compare the Cilium cluster health of every agent with its pre-deny baseline (BASE_HEALTH lines "<agent> <reachable> <total>").
ac2_cluster_health() {
  local now pod ip h n m bn bm base_line report="" worse="" unread="" nobase="" short=0 nag=0 enf=""
  now="$(SPIKE_HEALTH_WAIT=0 capture_cluster_health)"   # no convergence wait: the number now is the number to judge
  while read -r pod n m; do
    [ -z "$pod" ] && continue
    nag=$((nag + 1))
    base_line="$(printf '%s\n' "$BASE_HEALTH" | awk -v p="$pod" '$1==p{print $2, $3; exit}')"
    if [ -z "$base_line" ]; then
      report="${report}${pod} no-baseline->${n}/${m}; "; nobase="${nobase} ${pod}"
      [ "$n" != "$m" ] && short=1
      continue
    fi
    bn="${base_line% *}"; bm="${base_line#* }"
    report="${report}${pod} ${bn}/${bm}->${n}/${m}; "
    # unreachable count before vs after: robust against a node count that changed in between
    if [ $((m - n)) -gt $((bm - bn)) ]; then worse="${worse} ${pod}(${bn}/${bm}->${n}/${m})"; fi
  done <<< "$now"
  while read -r pod ip; do
    [ -z "$pod" ] && continue
    printf '%s\n' "$now" | awk -v p="$pod" '$1==p{f=1} END{exit !f}' || unread="${unread} ${pod}"
  done < <(agent_pods)
  # policy enforcement of the Cilium health endpoint (reserved:health) per agent: Disabled/Disabled = no policy selects it
  while read -r pod ip; do
    [ -z "$pod" ] && continue
    h="$(agent_exec "$pod" endpoint list)" || continue
    h="$(printf '%s\n' "$h" | awk '/reserved:health/{print $2 "/" $3; exit}')"
    [ -n "$h" ] && enf="${enf}${pod}=${h} "
  done < <(agent_pods)
  if [ "$nag" -eq 0 ]; then
    ev "cilium cluster health NOT read on any agent (no exec): health half NOT verified"; INCONC=1; return 0
  fi
  ev "cilium cluster health per agent, before the deny -> now (reachable/total): ${report%; }"
  [ -n "$unread" ] && ev "agents that did not answer now:${unread}"
  ev "health endpoint (reserved:health) policy enforcement ingress/egress per agent: ${enf:-not read} (Disabled/Disabled = no policy selects it)"
  if [ -n "$worse" ]; then
    ev "cilium cluster health DEGRADED versus the pre-deny baseline on:${worse}"; OK=0
  elif [ -n "$nobase" ] && [ "$short" = 1 ]; then
    ev "no pre-deny baseline for:${nobase} and not every node is reachable: cannot tell whether the deny caused it"; INCONC=1
  elif [ -n "$nobase" ]; then
    ev "no pre-deny baseline for:${nobase}; all nodes reachable now"
  else
    ev "cilium cluster health not worse than before the deny on any agent"
  fi
}

# ac2: kubelet / Cilium health probes and hostNetwork pods unaffected
ac2_probes_hostnetwork() {
  reset_state; begin
  local before="$OUTDIR/hostnetwork-before.txt" after="$OUTDIR/hostnetwork-after.txt" ready1 rs rs_start newly nbefore nafter base_ok=0 need=40 left
  mkdir -p "$OUTDIR"
  rs_start="$(K -n "$NS_A" get pod server -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
  # give the deny time to bite (readiness/liveness periods, node-level probes) before the snapshot
  if [ -n "$DENY_AT_SEC" ]; then left=$((need - (SECONDS - DENY_AT_SEC))); else left=$need; fi
  if [ "$left" -gt 0 ]; then note "waiting ${left}s so the snapshot is at least ${need}s after the deny"; sleep "$left"; fi
  ready1="$(K -n "$NS_A" get pod server -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  rs="$(K -n "$NS_A" get pod server -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  snapshot_hostnetwork "$after"
  nafter="$(not_ready_names "$after" | wc -l | tr -d ' ')"
  baseline_valid && base_ok=1
  ev "denied pod $NS_A/server Ready=${ready1} (readiness+liveness tcp probes come from the kubelet)"
  [ "$ready1" = "True" ] || OK=0
  if [ "$base_ok" = 1 ] && [ -n "$BASE_RS" ]; then
    if [ "${rs:-0}" -gt "$BASE_RS" ] 2>/dev/null; then ev "restarts of $NS_A/server rose ${BASE_RS}->${rs} since before the deny (liveness probe failing?)"; OK=0; else ev "restarts ${BASE_RS}->${rs}: no restart since before the deny"; fi
  else
    if [ "${rs:-0}" -gt "${rs_start:-0}" ] 2>/dev/null; then ev "restarts rose ${rs_start}->${rs} during this check"; OK=0; else ev "restarts ${rs_start}->${rs} (this check's window only: no valid pre-deny baseline)"; fi
  fi
  if [ "$base_ok" = 1 ]; then
    nbefore="$(not_ready_names "$before" | wc -l | tr -d ' ')"
    newly="$(comm -13 <(not_ready_names "$before") <(not_ready_names "$after") | tr '\n' ' ')"
    ev "hostNetwork pods not ready before/after the deny: ${nbefore}/${nafter}; newly not ready: ${newly:-none} (snapshots in $OUTDIR/hostnetwork-*.txt)"
    [ -n "$newly" ] && OK=0
  else
    ev "no valid pre-deny baseline (missing, from another context/deny, or the deny pre-dated this run); hostNetwork pods not ready now: ${nafter}"
    [ "$nafter" != 0 ] && INCONC=1
  fi
  # Cilium "Cluster health" on EVERY agent, compared with the same agent before the deny. FAIL only when more nodes are
  # unreachable than before (the first run saw 3/7 and 1/6 under the deny, caused by the health endpoint being selected by the
  # deny; the manifests now exclude reserved:health). Both numbers are reported.
  ac2_cluster_health
  finish ac2
  note "MANUAL extra: 'cilium-dbg status --all-health' on an agent and 'kubectl get nodes' stay green; compare node Ready condition."
}

# ac3: AKS: CCNP and namespace-label selectors, drop signals, effective policy-map size
ac3_aks_support() {
  local sel signals="" ag cm_max pm hub retina drops="" st why=""
  sel="$(result_status ac1)"
  if [ "$sel" = "not-run" ]; then ac1_optout_live_flip >/dev/null; sel="$(result_status ac1)"; fi
  hub="$(K -n kube-system get pods -l k8s-app=hubble-relay -o name 2>/dev/null | tr '\n' ' ')"
  retina="$(K get pods -A -o name 2>/dev/null | grep -i 'retina' | tr '\n' ' ')"
  ag="$(first_agent)"
  [ -n "$ag" ] && drops="$(agent_exec "$ag" metrics list 2>/dev/null | grep -i 'drop_count' | head -n3 | tr '\n' ';')"
  signals="hubble-relay pods: ${hub:-none}; retina pods: ${retina:-none}; agent drop metrics: ${drops:-none/not readable}"
  cm_max="$(K -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-policy-map-max}' 2>/dev/null)"
  pm="${cm_max:-unset in cilium-config (agent default 16384 per cmdref)}"
  if is_aks; then
    result ac3 MANUAL "AKS: selector support (ac1)=${sel}; drop signals: ${signals}; effective bpf-policy-map-max: ${pm}. Confirm ACNS with: az aks show -g <rg> -n <cluster> --query networkProfile.advancedNetworking"
    return
  fi
  # selector support comes from ac1 (auto-run above when it did not run yet); drop signals and map size are judged here
  case "$sel" in
    PASS) st=PASS ;;
    FAIL) st=FAIL ;;
    not-run) st=NOT-RUN ;;
    *) st=INCONCLUSIVE; why="ac1 was ${sel} " ;;
  esac
  if [ "$st" = PASS ]; then
    if [ -z "$hub" ] && [ -z "$retina" ] && [ -z "$drops" ]; then st=INCONCLUSIVE; why="${why}no drop signal found (no hubble-relay, retina or drop metrics readable) "; fi
    if [ -z "$cm_max" ]; then st=INCONCLUSIVE; why="${why}bpf-policy-map-max not set in cilium-config, effective map size unknown "; fi
  fi
  result ac3 "$st" "${why}non-AKS provider ${PROVIDER}: selector support = ac1 outcome (${sel}); drop signals: ${signals}; bpf-policy-map-max: ${pm}. Re-run with --provider aks on the AKS test WC for the AKS-specific answer."
}

# ac4: per-endpoint BPF policy-map usage with deny + DNS allow + all six standard allows
ac4_bpf_map_usage() {
  reset_state; begin; gen_seen_reset
  [ "$HAVE_GPOL" = 1 ] || { result ac4 MANUAL "GeneratingPolicy CRD missing: cannot generate the six standard allows. Apply them by hand then run: cilium-dbg bpf policy get --all -n"; return; }
  K apply -f "$M/ccnp-allow-dns-all-namespaces.yaml" >/dev/null || { result ac4 ERROR "applying the clusterwide DNS allow failed"; return; }
  local a i lost
  # one annotation per request, 2 s apart: the bulk (single-request) annotation has its own check
  annotate_each "$NS_ALL" || { result ac4 ERROR "could not annotate $NS_ALL"; return; }
  for a in $GEN_ANNOTATIONS; do
    await_generated "$NS_ALL" "$a" || { result ac4 FAIL "standard allow $a was NEVER generated in $NS_ALL within ${SYNC_TIMEOUT}s"; return; }
  done
  for i in $(seq 1 "$LOAD_PODS"); do
    cat <<EOF | K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: load-$i
  namespace: $NS_ALL
  labels:
    load: "l$i"
    ${OWNER_KEY}: ${OWNER_VAL}
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: pause
      image: ${PAUSE_IMAGE}
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
EOF
  done
  K -n "$NS_ALL" wait --for=condition=Ready pod --all --timeout=180s >/dev/null 2>&1 || note "not all load pods Ready; continuing"
  sleep 10
  if lost="$(lost_allows "$NS_ALL")"; then
    K -n "$NS_ALL" delete pods -l "load,${OWNER_SEL}" --wait=false >/dev/null 2>&1 || true
    delete_owned "$CCNP" "$DNS_ALLOW_NAME"
    result ac4 FINDING "generated-then-deleted: standard allows that were generated in $NS_ALL are gone again: ${lost} (not regenerated). The map measurement would not include them, so it was not taken: see the bulk check"
    return
  fi
  local limit cm out="$OUTDIR/bpf-policy-maps.txt" best maxn maxwhere pct
  cm="$(K -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-policy-map-max}' 2>/dev/null)"
  limit="${cm:-16384}"
  mkdir -p "$OUTDIR"
  if ! agent_exec_all "$out" bpf policy get --all -n; then
    result ac4 MANUAL "cannot exec into the cilium agent here. Run on every agent: kubectl -n kube-system exec <agent> -c cilium-agent -- cilium-dbg bpf policy get --all -n | awk '/^Endpoint ID:/{id=\$3} /^(Allow|Deny)[ \\t]/{c[id]++} END{for(i in c)print c[i], i}' | sort -rn | head; limit = kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-policy-map-max}' (default 16384). Action only above ~50%."
    return
  fi
  best="$(awk '/^### agent/{ag=$3} /^Endpoint ID:/{id=$3} /^(Allow|Deny)[ \t]/{c[ag " endpoint " id]++} END{for(k in c) print c[k], k}' "$out" | sort -rn | head -n1)"
  maxn="${best%% *}"; maxwhere="${best#* }"
  pct=$((${maxn:-0} * 100 / limit))
  ev "max entries on one endpoint: ${maxn:-0} (agent ${maxwhere}) of limit ${limit} = ${pct}%; ${LOAD_PODS} load pods (distinct identities) + 6 standard allows + DNS CCNP in ${NS_ALL}; raw dump ${out}"
  if [ "$pct" -lt 50 ]; then ev "below the ~50% action threshold"; else ev "ABOVE the ~50% action threshold: act on policyMapMax / fewer-merged policies"; OK=0; fi
  finish ac4
  note "Scale realism: raise SPIKE_LOAD_PODS to the largest identity count per namespace of a real customer cluster and re-run ac4."
  K -n "$NS_ALL" delete pods -l "load,${OWNER_SEL}" --wait=false >/dev/null 2>&1 || true
  delete_owned "$CCNP" "$DNS_ALLOW_NAME"
}

# ac5: GeneratingPolicy: annotation -> CNP, hand edits reverted, annotation removal deletes the CNP
ac5_generate_sync() {
  reset_state; begin
  [ "$HAVE_GPOL" = 1 ] || { result ac5 MANUAL "GeneratingPolicy CRD missing on this cluster"; return; }
  local a=allow-same-namespace n h0 h1
  n="$(gname "$a")"
  step "same-namespace denied before annotating" "precondition: same-namespace not denied before annotating" eventually 30 2 expect_blocked "$NS_A" "$NS_A" || { finish ac5; return; }
  annotate "$NS_A" "$a" || { finish ac5; return; }
  step "CNP generated after @T@s" "CNP $n NOT generated within ${SYNC_TIMEOUT}s" eventually "$SYNC_TIMEOUT" 2 cnp_exists "$NS_A" "$n" || { finish ac5; return; }
  step "same-namespace reachable" "same-namespace STILL blocked" eventually "$SYNC_TIMEOUT" 2 expect_reach "$NS_A" "$NS_A"
  # hand edit must be reverted
  h0="$(cnp_spec_hash "$NS_A" "$n")"
  if ! K -n "$NS_A" patch "$CNP" "$n" --type=merge -p '{"spec":{"ingress":[{"fromEndpoints":[{"matchLabels":{"io.kubernetes.pod.namespace":"nowhere"}}]}]}}' >/dev/null 2>&1; then
    fail_op "hand edit: kubectl patch FAILED (RBAC / admission?): revert behaviour not tested"
  else
    h1="$(cnp_spec_hash "$NS_A" "$n")"
    if [ "$h1" = "$h0" ]; then
      fail_op "hand edit changed nothing (spec hash identical): revert behaviour not tested"
    else
      hash_is_original() { [ "$(cnp_spec_hash "$NS_A" "$n")" = "$h0" ]; }
      step "hand edit reverted after @T@s" "hand edit NOT reverted within ${SYNC_TIMEOUT}s" eventually "$SYNC_TIMEOUT" 2 hash_is_original
    fi
  fi
  # deleting the CNP by hand must recreate it
  delete_owned "$CNP" "$n" "$NS_A" || fail_op "hand delete of $n FAILED"
  step "hand delete recreated" "hand delete NOT recreated" eventually "$SYNC_TIMEOUT" 2 cnp_exists "$NS_A" "$n"
  # annotation removal must delete the CNP
  unannotate "$NS_A" "$a"
  step "annotation removal deleted the CNP after @T@s" "CNP still present ${SYNC_TIMEOUT}s after annotation removal" eventually "$SYNC_TIMEOUT" 2 cnp_gone "$NS_A" "$n"
  step "same-namespace blocked again" "same-namespace NOT blocked again" eventually "$SYNC_TIMEOUT" 2 expect_blocked "$NS_A" "$NS_A"
  finish ac5
}

# ac5b: generate-existing
ac5b_generate_existing() {
  reset_state; begin
  [ "$HAVE_GPOL" = 1 ] || { result ac5b MANUAL "GeneratingPolicy CRD missing on this cluster"; return; }
  local a=allow-kube-apiserver n rc scaled=0 f="$OUTDIR/ac5b-evidence.txt" ur0 ur1 t_apply waited hits
  n="$(gname "$a")"
  mkdir -p "$OUTDIR"; : > "$f"
  # (i) policy created after the namespace was annotated
  delete_owned "$GPOL" "$n" || fail_op "deleting GeneratingPolicy $n FAILED"
  eventually 60 2 cnp_gone "$NS_B" "$n"
  annotate "$NS_B" "$a" || { finish ac5b; return; }
  sleep "$SETTLE"
  cnp_exists "$NS_B" "$n"; rc=$?
  case "$rc" in
    0) ev "unexpected: CNP exists without a policy"; OK=0 ;;
    1) ev "no CNP while the policy is absent" ;;
    *) fail_op "cannot check for the CNP: $P_DETAIL" ;;
  esac
  ur0="$(ur_count)"; ur_dump "$f" "before re-creating $n"
  apply_gpol "$M/generatingpolicies/generatingpolicy-${a}.yaml" || fail_op "re-applying the GeneratingPolicy failed"
  t_apply=$SECONDS
  step "policy (re)created -> CNP generated for the already annotated namespace after @T@s" "policy (re)created but CNP NOT generated within ${SYNC_TIMEOUT}s" eventually "$SYNC_TIMEOUT" 2 cnp_exists "$NS_B" "$n"
  # explicit evidence: how long was waited, was an UpdateRequest created for it, what did the background controller log
  waited=$((SECONDS - t_apply))
  ur1="$(ur_count)"; ur_dump "$f" "after waiting ${waited}s"
  { echo "--- GeneratingPolicy $n status"; K get "$GPOL" "$n" -o jsonpath='ready={.status.conditionStatus.ready} message={.status.conditionStatus.message}{"\n"}' 2>&1; } >> "$f"
  hits="$(bgc_log_hits "$f" "$n" $((waited + 30)))"
  ev "generate-existing (i): waited ${waited}s of max ${SYNC_TIMEOUT}s after re-creating the policy; UpdateRequests in kyverno before/after: ${ur0}/${ur1}; background-controller log lines mentioning ${n} in the last $((waited + 30))s: ${hits} (details: $f)"
  unannotate "$NS_B" "$a"
  eventually "$SYNC_TIMEOUT" 2 cnp_gone "$NS_B" "$n" || true
  # (ii) Kyverno down while the namespace gets annotated
  if [ "${SPIKE_ALLOW_KYVERNO_SCALE:-}" = "true" ]; then
    kyverno_down_test "$a"; rc=$?
    case "$rc" in
      0) ev "Kyverno-down test: CNP generated after Kyverno came back"; scaled=1 ;;
      1) ev "Kyverno-down test: CNP NOT generated after Kyverno came back"; OK=0; scaled=1 ;;
      3) ev "Kyverno-down test NOT run: $P_DETAIL" ;;
      *) fail_op "Kyverno-down test could not be completed: ${P_DETAIL:-error} (see the KYVERNO messages above; Kyverno is restored on exit or by cleanup)" ;;
    esac
  else
    ev "Kyverno-down case NOT run (opt in with SPIKE_ALLOW_KYVERNO_SCALE=true, scales all kyverno deployments to 0 for typically 1-3 min, worst case ~8 min)"
  fi
  if [ "$OK" = 1 ] && [ "$ERR" = 0 ] && [ "$INCONC" = 0 ]; then
    if [ "$scaled" = 1 ]; then finish ac5b
    else result ac5b MANUAL "$EV. Manual: kubectl -n kyverno scale deploy -l app.kubernetes.io/part-of=kyverno --replicas=0; annotate ns; scale back; check CNP."; fi
  else
    finish ac5b
  fi
}

kyverno_down_test() { # annotation -> 0 generated after restore, 1 not generated, 3 refused, 4 error (P_DETAIL)
  local a="$1" n rc=1
  n="$(gname "$a")"
  scale_down_kyverno; rc=$?
  if [ "$rc" -ne 0 ]; then
    # a failure half way (some deployments already at 0) leaves KYV_SCALED=1: put Kyverno back before returning
    if [ "$KYV_SCALED" = 1 ]; then restore_kyverno || P_DETAIL="${P_DETAIL:+$P_DETAIL; }Kyverno could NOT be restored"; fi
    return "$rc"
  fi
  if ! eventually 180 3 kyverno_pods_gone; then
    P_DETAIL="Kyverno pods/endpoints still present 180s after scaling to 0"; restore_kyverno; return 4
  fi
  if ! annotate "$NS_B" "$a"; then P_DETAIL="annotating $NS_B failed while Kyverno was down"; restore_kyverno; return 4; fi
  sleep 5
  restore_kyverno || { P_DETAIL="Kyverno could not be restored"; return 4; }
  rc=1
  eventually 180 3 cnp_exists "$NS_B" "$n" && rc=0
  unannotate "$NS_B" "$a"
  return $rc
}

# flap: Synchronize deletes then regenerates every downstream of a trigger on each Namespace UPDATE
# (kyverno pkg/background/gpol/generate_controller.go:87-93, dynamic_watcher.go:210-248). Measure what that does to
# traffic when the update is unrelated (a dummy label/annotation).
ac_flap() {
  reset_state; begin; gen_seen_reset
  [ "$HAVE_GPOL" = 1 ] || { result flap MANUAL "GeneratingPolicy CRD missing on this cluster"; return; }
  local lost a f_watch="$OUTDIR/flap-watch.txt" f_probe="$OUTDIR/flap-probe.txt" u0="$OUTDIR/flap-uids-before.txt" u1="$OUTDIR/flap-uids-after.txt"
  local srv url end i wpid ppid_ nd ng mg total failhttp faildns changed uperr=0 nexp last now cnt dl settled=""
  mkdir -p "$OUTDIR"; : > "$f_watch"; : > "$f_probe"
  # one annotation per request, 2 s apart, so this check measures the unrelated-update flap and not the bulk-annotation behaviour (`bulk`)
  annotate_each "$NS_A" || { finish flap; return; }
  for a in $GEN_ANNOTATIONS; do
    step "" "standard allow $a was NEVER generated within ${SYNC_TIMEOUT}s" await_generated "$NS_A" "$a" || { finish flap; return; }
  done
  step "" "same-namespace not reachable with all six annotations" eventually "$SYNC_TIMEOUT" 2 expect_reach "$NS_A" "$NS_A" || { finish flap; return; }
  step "" "DNS not working with allow-dns annotated" eventually "$SYNC_TIMEOUT" 2 expect_dns_works "$NS_A" || { finish flap; return; }
  if lost="$(lost_allows "$NS_A")"; then
    ev "generated-then-deleted BEFORE any unrelated update was made: ${lost} (not regenerated), so this is not the unrelated-update flap: see the bulk check"
    result flap FINDING "$EV"
    unannotate_all "$NS_A"
    return
  fi
  srv="$(pod_ip "$NS_A" server)"; url="http://${srv}:8080/"
  set -- $GEN_ANNOTATIONS; nexp=$#
  cnp_uids "$NS_A" > "$u0"
  # watch the generated CNPs with DELETED events, timestamped per second; bounded by timeout and killed as a tree at the end
  ( run_bounded $((FLAP_SECONDS + 90)) kubectl "${KARGS[@]+"${KARGS[@]}"}" -n "$NS_A" get "$CNP" -w --output-watch-events \
      -o jsonpath='{.type} {.object.metadata.name} {.object.metadata.uid} {.object.metadata.creationTimestamp}{"\n"}' 2>/dev/null \
      | while read -r l; do echo "$(date +%s) $l"; done >> "$f_watch" ) &
  wpid=$!; BG_PIDS+=("$wpid")
  # Continuous same-namespace + DNS probe loop inside the client pod (a curl+dig pair per iteration, ~5-10 pairs/s).
  # Same classification as probe_http: curl exit 0/35/52/56/60 = reachable, anything else is a failure; a dig answer
  # needs an A record.
  run_bounded $((FLAP_SECONDS + 80)) kubectl "${KARGS[@]+"${KARGS[@]}"}" -n "$NS_A" exec client -- sh -c \
    'end=$(( $(date +%s) + $1 )); n=0
     while [ "$(date +%s)" -lt "$end" ]; do
       n=$((n+1)); t=$(date +%s)
       curl -s -k -m 1 -o /dev/null "$2"; rc=$?
       case "$rc" in 0|35|52|56|60) ;; 28) echo "FAIL http timeout $t" ;; *) echo "FAIL http rc$rc $t" ;; esac
       o=$(dig +time=1 +tries=1 "$3" 2>&1)
       if echo "$o" | grep -Eq "IN[[:space:]]+A[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then :
       elif echo "$o" | grep -q "no servers could be reached"; then echo "FAIL dns timeout $t"
       else echo "FAIL dns other $t"; fi
       sleep 0.1
     done
     echo "TOTAL $n"' \
    sh "$((FLAP_SECONDS + 30))" "$url" "kubernetes.default.svc.${CLUSTER_DOMAIN}" > "$f_probe" 2>&1 &
  ppid_=$!; BG_PIDS+=("$ppid_")
  sleep 3
  echo "$(date +%s) MARK updates-start" >> "$f_watch"
  end=$((SECONDS + FLAP_SECONDS - 4)); i=0
  note "making unrelated Namespace updates (dummy label + annotation add/remove) on $NS_A for ~${FLAP_SECONDS}s"
  while [ "$SECONDS" -lt "$end" ]; do
    i=$((i + 1))
    K label namespace "$NS_A" "${KIT}-flap=$i" --overwrite >/dev/null 2>&1 || uperr=1; sleep 2
    K label namespace "$NS_A" "${KIT}-flap-" >/dev/null 2>&1 || uperr=1; sleep 2
    K annotate namespace "$NS_A" "${KIT}.giantswarm.io/flap=$i" --overwrite >/dev/null 2>&1 || uperr=1; sleep 2
    K annotate namespace "$NS_A" "${KIT}.giantswarm.io/flap-" >/dev/null 2>&1 || uperr=1; sleep 2
  done
  [ "$uperr" = 1 ] && fail_op "some of the unrelated Namespace updates FAILED (kubectl label/annotate returned an error)"
  # keep observing until the regeneration settles: all CNPs back and no watch event for 10 s (max 30 s)
  dl=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$dl" ]; do
    last="$(awk 'END{print $1}' "$f_watch")"; now="$(date +%s)"
    cnt="$(K -n "$NS_A" get "$CNP" -o name 2>/dev/null | grep -c "/${KIT}-allow-")"
    if [ "${cnt:-0}" = "$nexp" ] && [ -n "$last" ] && [ $((now - last)) -ge 10 ]; then settled="settled"; break; fi
    sleep 2
  done
  [ -n "$settled" ] || settled="NOT settled within 30s (${cnt:-?}/${nexp} CNPs present)"
  wait "$ppid_" 2>/dev/null
  kill_tree "$wpid"
  cnp_uids "$NS_A" > "$u1"
  read -r nd ng mg < <(awk '$2=="MARK"{m=1;next} m&&$2=="DELETED"{nd++; dts[$3]=$1} m&&$2=="ADDED"&&($3 in dts){g=$1-dts[$3]; if(g>mg)mg=g; ng++; delete dts[$3]} END{print nd+0, ng+0, mg+0}' "$f_watch")
  total="$(awk '$1=="TOTAL"{print $2}' "$f_probe")"
  failhttp="$(grep -c '^FAIL http' "$f_probe")"; faildns="$(grep -c '^FAIL dns' "$f_probe")"
  changed="$(diff "$u0" "$u1" | grep -c '^>')"
  ev "${i} rounds of unrelated Namespace updates; CNP DELETED events during the updates: ${nd}; recreated: ${ng}; max delete->recreate gap: ${mg}s (1 s resolution); CNPs whose uid/creationTimestamp changed: ${changed}; ${settled}"
  ev "probe loop: ${total:-?} iterations, failed http: ${failhttp}, failed dns: ${faildns} (raw: $f_probe, $f_watch)"
  if [ "$ERR" = 1 ]; then
    result flap ERROR "$EV"
  elif [ -z "$total" ]; then
    ev "probe loop did not finish: $(head -c 200 "$f_probe" | tr '\n' ' ')"
    result flap INCONCLUSIVE "$EV"
  elif [ "$nd" != 0 ] || [ "$changed" != 0 ]; then
    result flap FINDING "$EV: Synchronize regenerates the generated CNPs on unrelated Namespace updates; size the gap against the SLO of the namespaces that use the standard allows"
  elif [ "$failhttp" != 0 ] || [ "$faildns" != 0 ]; then
    result flap PROBE-FAIL "$EV: probe failures WITHOUT any CNP regeneration, so the cause is not the Synchronize flap (client, DNS or datapath problem): look at $f_probe"
  else
    result flap PASS "$EV: unrelated updates did not regenerate the CNPs"
  fi
  unannotate_all "$NS_A"
}

# bulk: all six annotations in ONE request (one Namespace UPDATE) vs one at a time (control), CNPs counted over time.
# First real run on Kyverno 1.17.2: all six were generated within 5 s, then ~2 min later the background controller processed a
# second set of UpdateRequests (nothing had changed in between) that deleted all six and never regenerated them; annotating
# them one at a time kept all six for 3+ minutes. Fresh namespaces per run, so no state of an earlier check can leak in.
bulk_ns_fresh() { # ns: create an owner-labelled namespace, deleting a leftover of an earlier run first
  local rc
  kexists namespaces "$1"; rc=$?
  case "$rc" in
    2) fail_op "$P_DETAIL"; return 1 ;;
    0) delete_owned namespaces "$1" || { fail_op "cannot delete the leftover namespace $1"; return 1; }
       eventually 180 3 gone namespaces "$1" || { fail_op "leftover namespace $1 still terminating after 180s"; return 1; } ;;
  esac
  cat <<EOF | K apply -f - >/dev/null || { fail_op "creating namespace $1 FAILED"; return 1; }
apiVersion: v1
kind: Namespace
metadata:
  name: $1
  labels:
    ${OWNER_KEY}: ${OWNER_VAL}
EOF
}
# "T:n T:n ..." (seconds after the annotation : kit allows present) -> TS_PEAK, TS_FINAL, TS_FINAL_T, and when the count first
# fell below an earlier peak: TS_DROP_T (that sample), TS_PREV_T (the sample before it), TS_DROP_PEAK (the peak before the fall)
timeline_stats() {
  local p t n prev_t=""
  TS_PEAK=0; TS_FINAL=0; TS_FINAL_T=""; TS_DROP_T=""; TS_PREV_T=""; TS_DROP_PEAK=0
  for p in $1; do
    t="${p%%:*}"; n="${p#*:}"
    if [ -z "$TS_DROP_T" ] && [ "$n" -lt "$TS_PEAK" ]; then TS_DROP_T="$t"; TS_PREV_T="$prev_t"; TS_DROP_PEAK="$TS_PEAK"; fi
    [ "$n" -gt "$TS_PEAK" ] && TS_PEAK="$n"
    TS_FINAL="$n"; TS_FINAL_T="$t"; prev_t="$t"
  done
  return 0
}
# verdict for one timeline -> "<word>|<sentence>": never (0 at every sample), ok (N/N throughout), partial (steady but short
# of N), deleted (fell below an earlier peak and is still below at the last sample), regenerated (fell, and is back at the peak)
timeline_verdict() { # series nexp
  timeline_stats "$1"
  if [ "$TS_PEAK" -eq 0 ]; then echo "never|0/$2 generated at any sample"
  elif [ -n "$TS_DROP_T" ] && [ "$TS_FINAL" -lt "$TS_PEAK" ]; then
    echo "deleted|${TS_DROP_PEAK}/$2 generated then deleted after ~${TS_DROP_T}s (present at ${TS_PREV_T:-the start}s, short at ${TS_DROP_T}s) without regeneration; ${TS_FINAL}/$2 at ${TS_FINAL_T}s"
  elif [ -n "$TS_DROP_T" ]; then echo "regenerated|${TS_DROP_PEAK}/$2 deleted at ~${TS_DROP_T}s and regenerated by ${TS_FINAL_T}s"
  elif [ "$TS_FINAL" -lt "$2" ]; then echo "partial|only ${TS_FINAL}/$2 generated, steady through ${TS_FINAL_T}s"
  else echo "ok|all $2/$2 persisted through ${TS_FINAL_T}s"; fi
}
ac_bulk() {
  reset_state; begin
  [ "$HAVE_GPOL" = 1 ] || { result bulk MANUAL "GeneratingPolicy CRD missing on this cluster"; return; }
  local f="$OUTDIR/bulk-evidence.txt" t0b t0s T cb cs sb="" ss="" nb ns_ nexp ur0 ur1 wins hits vb vs wb ws status last
  mkdir -p "$OUTDIR"; : > "$f"
  set -- $GEN_ANNOTATIONS; nexp=$#
  bulk_ns_fresh "$NS_BULK" || { finish bulk; return; }
  bulk_ns_fresh "$NS_SEQ" || { finish bulk; return; }
  ur0="$(ur_count)"; ur_dump "$f" "before the annotations"
  annotate_bulk "$NS_BULK" || { finish bulk; return; }
  t0b=$SECONDS
  note "bulk: all ${nexp} annotations of $NS_BULK in one request; control: $NS_SEQ one at a time, ${SPIKE_ANNOTATE_GAP:-2}s apart; counting CNPs at ${BULK_SAMPLES// /s, }s"
  annotate_each "$NS_SEQ" || { finish bulk; return; }
  t0s=$((SECONDS - ${SPIKE_ANNOTATE_GAP:-2}))
  for T in $BULK_SAMPLES; do
    while [ "$SECONDS" -lt $((t0b + T)) ]; do sleep 1; done
    cb="$(count_allows "$NS_BULK")"; cs="$(count_allows "$NS_SEQ")"
    nb="$(names_allows "$NS_BULK")"; ns_="$(names_allows "$NS_SEQ")"
    sb="$sb ${T}:${cb:-0}"; ss="$ss ${T}:${cs:-0}"; last="$T"
    echo "t=${T}s (control age $((SECONDS - t0s))s) bulk=${cb:-0}/${nexp} [${nb}] control=${cs:-0}/${nexp} [${ns_}] urs=$(ur_count)" >> "$f"
  done
  ur1="$(ur_count)"; ur_dump "$f" "after the last sample"
  wins=$((SECONDS - t0b + 60))
  hits="$(bgc_log_hits "$f" "${KIT}-allow" "$wins")"
  sb="${sb# }"; ss="${ss# }"
  vb="$(timeline_verdict "$sb" "$nexp")"; vs="$(timeline_verdict "$ss" "$nexp")"
  wb="${vb%%|*}"; ws="${vs%%|*}"
  ev "CNP counts as seconds:allows, bulk (one request) ${sb}, control (one by one) ${ss}; UpdateRequests in kyverno before/after: ${ur0}/${ur1}; background-controller log lines mentioning ${KIT}-allow in the last ${wins}s: ${hits} (details: $f)"
  delete_owned namespaces "$NS_BULK" || fail_op "deleting namespace $NS_BULK FAILED"
  delete_owned namespaces "$NS_SEQ" || fail_op "deleting namespace $NS_SEQ FAILED"
  if [ "$ERR" = 1 ]; then finish bulk; return; fi
  case "$wb:$ws" in
    never:never) result bulk FAIL "$EV; NO allow was generated in either namespace within ${last}s (kit/Kyverno setup problem: see ac5)"; return ;;
    never:*) result bulk FINDING "bulk annotation: ${vb#*|} while the one-by-one control: ${vs#*|}. $EV"; return ;;
  esac
  case "$wb" in
    ok) status=PASS ;;
    *) status=FINDING ;;
  esac
  ev "bulk annotation: ${vb#*|}"
  if [ "$ws" = ok ]; then ev "one-by-one control: ${vs#*|}"; else status=FINDING; ev "one-by-one control ALSO misbehaved (${vs#*|}): not specific to the bulk annotation"; fi
  result bulk "$status" "$EV"
}

# restart: annotate, generate, restart the background controller, remove the annotation: the CNP must go away
ac_restart() {
  reset_state; begin
  [ "$HAVE_GPOL" = 1 ] || { result restart MANUAL "GeneratingPolicy CRD missing on this cluster"; return; }
  [ "${SPIKE_SKIP_KYVERNO_RESTART:-}" = "true" ] && { result restart NOT-RUN "skipped by SPIKE_SKIP_KYVERNO_RESTART=true"; return; }
  local a=allow-same-namespace n d f="$OUTDIR/restart-evidence.txt" ur0 ur1 t_rs t_un waited hits
  n="$(gname "$a")"
  mkdir -p "$OUTDIR"; : > "$f"
  d="$(K -n kyverno get deploy -l app.kubernetes.io/component=background-controller -o name 2>/dev/null | head -n1)"
  [ -n "$d" ] || { result restart INCONCLUSIVE "no background-controller deployment found in namespace kyverno"; return; }
  annotate "$NS_A" "$a" || { finish restart; return; }
  step "CNP generated" "CNP $n NOT generated within ${SYNC_TIMEOUT}s" eventually "$SYNC_TIMEOUT" 2 cnp_exists "$NS_A" "$n" || { finish restart; return; }
  t_rs=$SECONDS
  if K -n kyverno rollout restart "$d" >/dev/null 2>&1 && K -n kyverno rollout status "$d" --timeout=180s >/dev/null 2>&1; then
    ev "restarted $d"
  else
    fail_op "restart of $d failed or did not finish in 180s"; finish restart; return
  fi
  ur0="$(ur_count)"; ur_dump "$f" "after the restart, before removing the annotation"
  unannotate "$NS_A" "$a"
  t_un=$SECONDS
  step "annotation removed after the background controller restart -> CNP deleted after @T@s" "CNP still present 120s after annotation removal following the background controller restart" eventually 120 2 cnp_gone "$NS_A" "$n"
  # explicit evidence: how long was waited, was an UpdateRequest created by the removal, what did the (new) background controller log
  waited=$((SECONDS - t_un))
  ur1="$(ur_count)"; ur_dump "$f" "after waiting ${waited}s"
  hits="$(bgc_log_hits "$f" "$n" $((SECONDS - t_rs + 30)))"
  ev "waited ${waited}s of max 120s after removing the annotation; UpdateRequests in kyverno before/after: ${ur0}/${ur1}; background-controller log lines mentioning ${n} since the restart: ${hits} (details: $f)"
  finish restart
}

# apiserver: allow-kube-apiserver end to end (by ClusterIP, so DNS plays no part)
ac_apiserver() {
  reset_state; begin
  [ "$HAVE_GPOL" = 1 ] || { result apiserver MANUAL "GeneratingPolicy CRD missing on this cluster"; return; }
  local a=allow-kube-apiserver n ip port url
  n="$(gname "$a")"
  ip="$(K -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  port="$(K -n default get svc kubernetes -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)"
  [ -n "$ip" ] || { result apiserver INCONCLUSIVE "cannot read the ClusterIP of default/kubernetes"; return; }
  url="https://${ip}:${port:-443}/version"
  step "without the annotation the API server is blocked" "without the annotation the API server is reachable" eventually 30 2 expect_blocked "$NS_A" "$url" || { finish apiserver; return; }
  annotate "$NS_A" "$a" || { finish apiserver; return; }
  step "" "CNP $n not generated within ${SYNC_TIMEOUT}s" eventually "$SYNC_TIMEOUT" 2 cnp_exists "$NS_A" "$n"
  step "with allow-kube-apiserver: TLS/HTTP answer from ${url} (http=@P@)" "with allow-kube-apiserver the API server is still unreachable (selector/entity wrong for this provider?)" eventually "$SYNC_TIMEOUT" 2 expect_reach "$NS_A" "$url"
  EV="${EV//@P@/$P_CODE}"
  unannotate "$NS_A" "$a"
  eventually "$SYNC_TIMEOUT" 2 cnp_gone "$NS_A" "$n" || true
  step "annotation removed: blocked again" "annotation removed: API server still reachable" eventually "$SYNC_TIMEOUT" 2 expect_blocked "$NS_A" "$url"
  finish apiserver
}

# ac6: narrowest working webhook-ingress source, then the REAL generated allow-webhook-ingress
ac6_webhook_ingress() {
  reset_state; begin
  apply_manifest "$M/probes/webhook-probe.yaml"
  K -n "$NS_WEBHOOK" wait --for=condition=Ready pod/webhook --timeout=180s >/dev/null 2>&1 || { result ac6 FAIL "webhook probe pod not Ready"; return; }
  delete_owned "$CNP" "$WEBHOOK_CNP" "$NS_WEBHOOK"
  eventually 30 2 cnp_gone "$NS_WEBHOOK" "$WEBHOOK_CNP"
  sleep "$SETTLE"
  hits() { K -n "$NS_WEBHOOK" logs webhook 2>/dev/null | grep -c 'length=' || true; }
  # connections the API server made to the listener in response to one ConfigMap CREATE
  delta() { local b a; b="$(hits)"; K -n "$NS_WEBHOOK" create configmap "probe-$RANDOM$RANDOM" --from-literal=a=b >/dev/null 2>&1 || true; sleep 4; a="$(hits)"; echo $((a - b)); }
  local base v name d winner="" tried="" gen=""
  base="$(delta)"
  if [ "$base" -gt 0 ]; then
    result ac6 INCONCLUSIVE "baseline: the API server already reached the listener ${base}x with NO allow in ${NS_WEBHOOK}: the deny does not apply to this namespace/pod, so no candidate can be judged"
    return
  fi
  ev "baseline (no allow): 0 connections"
  for v in "$M"/webhook-variants/*.yaml; do
    name="$(basename "$v" .yaml)"
    K apply -f "$v" >/dev/null
    sleep "$SETTLE"
    d="$(delta)"
    tried="$tried ${name}=${d}"
    [ "$d" -gt 0 ] && [ -z "$winner" ] && winner="$name"
  done
  delete_owned "$CNP" "$WEBHOOK_CNP" "$NS_WEBHOOK"
  ev "per-variant connection delta:${tried}"
  if [ "$HAVE_GPOL" = 1 ]; then
    annotate "$NS_WEBHOOK" allow-webhook-ingress
    if eventually "$SYNC_TIMEOUT" 2 cnp_exists "$NS_WEBHOOK" "$(gname allow-webhook-ingress)"; then
      sleep "$SETTLE"; gen="$(delta)"
      ev "generated $(gname allow-webhook-ingress) (ports 443/4443/8443/9443/10250): delta ${gen}"
      [ "$gen" -gt 0 ] || OK=0
    else
      fail_op "generated allow-webhook-ingress CNP not created within ${SYNC_TIMEOUT}s"
    fi
    unannotate "$NS_WEBHOOK" allow-webhook-ingress
  else
    ev "generated allow-webhook-ingress not tested (no GeneratingPolicy CRD)"
  fi
  if [ -z "$winner" ]; then
    OK=0
    ev "provider ${PROVIDER}: no candidate source let the API server reach the webhook. If the control plane is managed (AKS), see MANUAL: 'hubble observe'/'cilium-dbg monitor -t drop' on the webhook pod's node for the real source identity"
  else
    ev "provider ${PROVIDER}: narrowest working source = ${winner}"
  fi
  finish ac6
  note "The generated allow-webhook-ingress uses [kube-apiserver, remote-node] on ports 443,4443,8443,9443,10250. Update the GeneratingPolicy to the winning source before shipping."
}

# dns: clusterwide DNS allow off vs allow-dns annotation vs clusterwide DNS allow on, plus kube-system / giantswarm
dns_probe_pod() { # ns -> create the owner-labelled probe pod in a system namespace (idempotent), wait for Ready
  pod_ready "$1" "$DNS_PROBE_POD" && return 0
  cat <<EOF | K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${DNS_PROBE_POD}
  namespace: $1
  labels:
    app: ${DNS_PROBE_POD}
    ${OWNER_KEY}: ${OWNER_VAL}
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: probe
      image: ${IMAGE}
      command: ["sleep", "infinity"]
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
EOF
  K -n "$1" wait --for=condition=Ready "pod/${DNS_PROBE_POD}" --timeout=120s >/dev/null 2>&1
}
ac_dns() {
  reset_state; begin
  local ns sysns=() state
  for ns in kube-system giantswarm; do
    K get ns "$ns" >/dev/null 2>&1 || { ev "namespace $ns absent: skipped"; continue; }
    if K -n "$ns" get "$CNP" default-allow-dns >/dev/null 2>&1; then
      ev "$ns: default-allow-dns present"
    else
      ev "$ns: default-allow-dns ABSENT (DNS of the GS components in $ns will break: allowEgressToDNS not enabled)"; OK=0
    fi
    if dns_probe_pod "$ns"; then sysns+=("$ns"); else fail_op "$ns: could not start the DNS probe pod ${DNS_PROBE_POD} (image pull / admission?)"; fi
  done
  sys_dns() { # state label: every system namespace must resolve
    local s r=0
    for s in "${sysns[@]+"${sysns[@]}"}"; do
      step "$s resolves ($1)" "$s DNS FAILS ($1)" eventually 30 2 expect_dns_works "$s" "$DNS_PROBE_POD" || r=1
    done
    return $r
  }
  step "off + unannotated: DNS blocked in $NS_A" "off + unannotated: DNS WORKS or is not cleanly blocked in $NS_A" eventually 30 2 expect_dns_blocked "$NS_A"
  sys_dns "clusterwide allow off"
  if [ "$HAVE_GPOL" = 1 ]; then
    annotate "$NS_A" allow-dns
    step "allow-dns annotation: DNS works" "allow-dns annotation: DNS still fails" eventually "$SYNC_TIMEOUT" 3 expect_dns_works "$NS_A"
    unannotate "$NS_A" allow-dns
    step "annotation removed: DNS blocked again" "annotation removed: DNS still works" eventually "$SYNC_TIMEOUT" 3 expect_dns_blocked "$NS_A"
  else
    ev "allow-dns annotation case skipped (no GeneratingPolicy CRD)"
  fi
  K apply -f "$M/ccnp-allow-dns-all-namespaces.yaml" >/dev/null || fail_op "applying the clusterwide DNS allow failed"
  step "clusterwide allow on: DNS works in unannotated $NS_B" "clusterwide allow on: DNS still fails in $NS_B" eventually 60 3 expect_dns_works "$NS_B"
  sys_dns "clusterwide allow on"
  delete_owned "$CCNP" "$DNS_ALLOW_NAME"
  step "clusterwide allow removed: DNS blocked in $NS_B" "clusterwide allow removed: DNS still works in $NS_B" eventually 60 3 expect_dns_blocked "$NS_B"
  state="kube-system/giantswarm probes ran in: ${sysns[*]:-none}"
  if [ "${#sysns[@]}" -eq 0 ]; then INCONC=1; ev "NO system namespace was probed: the kube-system/giantswarm half of the check did not run"; fi
  finish dns "$state"
}

# ac7: L4-only DNS allow vs a customer L7 DNS rule (FQDN policy)
ac7_l7_dns_interaction() {
  reset_state; begin
  local allowed="${SPIKE_FQDN_ALLOWED:-example.com}" other="${SPIKE_FQDN_OTHER:-giantswarm.io}" a1 o1 a2 o2 widened=0
  cat <<EOF | K apply -f - >/dev/null
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ${FQDN_CNP}
  namespace: ${NS_B}
  labels:
    ${OWNER_KEY}: ${OWNER_VAL}
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels: {io.kubernetes.pod.namespace: kube-system, k8s-app: coredns}
        - matchLabels: {io.kubernetes.pod.namespace: kube-system, k8s-app: k8s-dns-node-cache}
        - matchLabels: {io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns}
      toPorts:
        - ports:
            - {port: "53", protocol: ANY}
            - {port: "1053", protocol: ANY}
          rules:
            dns:
              - matchName: ${allowed}
    - toFQDNs:
        - matchName: ${allowed}
      toPorts:
        - ports:
            - {port: "443", protocol: TCP}
EOF
  has_ip() { dns_query "$NS_B" client "$1" || return 2; [ -n "$DNS_IP" ]; }
  if ! eventually 40 2 has_ip "$allowed"; then
    dns_query "$NS_B" client "$allowed"
    result ac7 INCONCLUSIVE "precondition failed: ${allowed} does not resolve under the L7-only customer policy (state ${DNS_STATE}: L7 DNS proxy not answering, no upstream DNS, or CoreDNS ingress missing). Run the same with 'cilium-dbg monitor -t l7' on the node."
    delete_owned "$CNP" "$FQDN_CNP" "$NS_B"; return
  fi
  a1="$DNS_IP"
  dns_query "$NS_B" client "$other"; o1="$DNS_IP"
  ev "L7-only customer policy: ${allowed} -> '${a1}', ${other} -> '${o1:-no answer}' (${DNS_STATE})"
  if [ "$DNS_STATE" = error ]; then result ac7 INCONCLUSIVE "$EV; probe error: $P_DETAIL"; delete_owned "$CNP" "$FQDN_CNP" "$NS_B"; return; fi
  if [ -n "$o1" ]; then
    result ac7 INCONCLUSIVE "$EV; the L7 rule is not effective on its own (${other} resolves), so widening cannot be judged"
    delete_owned "$CNP" "$FQDN_CNP" "$NS_B"; return
  fi
  if [ "$HAVE_GPOL" != 1 ]; then
    result ac7 MANUAL "$EV; GeneratingPolicy missing, cannot test the generated allow. Apply allow-dns by hand in ${NS_B} and repeat the query for ${other}."
    delete_owned "$CNP" "$FQDN_CNP" "$NS_B"; return
  fi
  annotate "$NS_B" allow-dns || { result ac7 ERROR "$EV"; delete_owned "$CNP" "$FQDN_CNP" "$NS_B"; return; }
  if ! eventually "$SYNC_TIMEOUT" 2 cnp_exists "$NS_B" "$(gname allow-dns)"; then
    result ac7 INCONCLUSIVE "$EV; the generated $(gname allow-dns) CNP did not appear within ${SYNC_TIMEOUT}s"
  else
    eventually 40 2 has_ip "$allowed" || true
    dns_query "$NS_B" client "$allowed"; a2="$DNS_IP"
    for _ in 1 2 3; do
      dns_query "$NS_B" client "$other"; o2="$DNS_IP"
      [ -n "$o2" ] && widened=1
      sleep 2
    done
    ev "plus generated L4-only allow-dns: ${allowed} -> '${a2:-no answer}', ${other} -> '${o2:-no answer/refused}' (3 queries)"
    if [ "$widened" = 1 ]; then
      result ac7 FINDING "the L4-only allow-dns WIDENS the customer L7 DNS rule (other names resolve once it is added). ${EV}. Consequence: document that allow-dns / clusterwide DNS allow override customer FQDN allow-lists, or generate allow-dns with rules.dns matchPattern '*'."
    elif [ -n "$a2" ]; then
      result ac7 PASS "L4-only allow-dns does NOT widen the customer L7 DNS rule. ${EV}"
    else
      result ac7 INCONCLUSIVE "$EV; the allowed name stopped resolving after allow-dns was added, widening cannot be judged"
    fi
  fi
  delete_owned "$CNP" "$FQDN_CNP" "$NS_B"
  unannotate "$NS_B" allow-dns
}

# ac8: drops in kube-system / giantswarm recorded as input for the app coverage audit (giantswarm/roadmap#4375)
ac8_drops_gs_namespaces() {
  mkdir -p "$OUTDIR"
  local pod ip n=0 f ok=0 total p
  local pids=()
  rm -f "$OUTDIR"/drops-*.txt "$OUTDIR"/drops-*.rc
  while read -r pod ip; do
    [ -z "$pod" ] && continue
    f="$OUTDIR/drops-$pod.txt"
    # AGENT_TIMEOUT bounds the in-container command and the local kubectl exec (timeout/gtimeout, else process-group kill)
    ( AGENT_TIMEOUT="$DROP_WINDOW" agent_exec "$pod" monitor --type drop > "$f" 2>&1; echo $? > "$OUTDIR/drops-$pod.rc" ) &
    pids+=("$!"); BG_PIDS+=("$!"); n=$((n + 1))
  done < <(agent_pods)
  if [ "$n" = 0 ]; then
    result ac8 MANUAL "no cilium agent pods found. Use Hubble if present: hubble observe --verdict DROPPED --namespace kube-system --since 15m -o json ; same for giantswarm. Else per node: cilium-dbg monitor --type drop."
    return
  fi
  note "capturing drops on $n agent(s) for ${DROP_WINDOW}s (GS components under the clusterwide deny, no allows added)"
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
  for f in "$OUTDIR"/drops-*.rc; do [ "$(cat "$f" 2>/dev/null)" = 0 ] && ok=$((ok + 1)); done
  if [ "$ok" = 0 ]; then
    result ac8 MANUAL "cannot exec into the cilium agent here. Use Hubble if present: hubble observe --verdict DROPPED --namespace kube-system --since 15m -o json ; same for giantswarm. Else per node: cilium-dbg monitor --type drop."
    return
  fi
  total="$(cat "$OUTDIR"/drops-*.txt 2>/dev/null | grep -ci 'drop')"
  result ac8 MANUAL "captured ${total:-0} drop lines on ${ok}/${n} agents in ${OUTDIR}/drops-*.txt over ${DROP_WINDOW}s (every exec is bounded by that window); triage by namespace (kube-system, giantswarm) and attach to giantswarm/roadmap#4375. Longer window: SPIKE_DROP_WINDOW=600. Hubble: hubble observe --verdict DROPPED -n kube-system -n giantswarm --since 15m"
}

# ac9: guidance recorded upstream
ac9_record_guidance() {
  result ac9 MANUAL "copy the winning webhook source (ac6), the L7/L4 DNS finding (ac7), map headroom (ac4), the sync/generate-existing behavior (ac5, ac5b) and the flap/bulk/restart findings into giantswarm/giantswarm#32658 (CNP guidance)."
}

# ---------------------------------------------------------------------------------------------- driver
print_summary() {
  mkdir -p "$OUTDIR"
  local f r a s e
  f="$OUTDIR/results-$(date +%Y%m%d-%H%M%S).md"
  {
    echo "# Spike results: provider ${PROVIDER}, context ${KCTX}"
    echo
    echo "| Check | Status | Evidence |"
    echo "|---|---|---|"
    for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
      IFS='|' read -r a s e <<< "$r"
      echo "| $a | $s | ${e//|/\\|} |"
    done
  } > "$f"
  echo
  echo "== summary (also in $f)"
  for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do IFS='|' read -r a s e <<< "$r"; printf '%-9s %s\n' "$a" "$s"; done
}

# test hook for the offline mock-kubectl tests: SPIKE_SOURCE_ONLY=1 . ./run-checklist.sh defines everything above and returns
if [ "${SPIKE_SOURCE_ONLY:-}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

case "$CMD" in
  list) for a in $(all_checks | tr ',' ' '); do echo "$a -> $(fn_for "$a")"; done; exit 0 ;;
  cleanup) cleanup; exit $? ;;
  setup|run)
    if [ "$CMD" = run ]; then
      # validate --only BEFORE anything is applied: a typo must never apply the deny
      sel="${ONLY:-$(all_checks)}"
      IFS=',' read -r -a want <<< "$sel"
      for a in "${want[@]}"; do
        fn_for "$a" >/dev/null || { echo "unknown function: $a (see: $0 list)" >&2; exit 2; }
      done
    fi
    trap on_exit EXIT
    trap 'on_signal INT 130' INT
    trap 'on_signal TERM 143' TERM
    setup || exit $?
    if [ "$CMD" = run ]; then
      for a in "${want[@]}"; do
        fn="$(fn_for "$a")"
        echo "== $a ($fn)"
        "$fn"
      done
      reset_state
      print_summary
      # exit status: 1 when any check ended FAIL or ERROR (INCONCLUSIVE/FINDING/PROBE-FAIL/MANUAL do not change it)
      for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
        case "$r" in *"|FAIL|"*|*"|ERROR|"*) exit 1 ;; esac
      done
    fi
    ;;
esac
