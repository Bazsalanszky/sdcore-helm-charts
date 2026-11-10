{{- /*

# Copyright 2020-present Open Networking Foundation
#
# SPDX-License-Identifier: Apache-2.0

*/ -}}

{{/*
Renders a set of standardised labels
*/}}
{{- define "omec-sub-provision.metadata_labels" -}}
{{- $application := index . 0 -}}
{{- $context := index . 1 -}}
release: {{ $context.Release.Name }}
app: {{ $application }}
{{- end -}}

{{/*
Render the given template.
*/}}
{{- define "omec-sub-provision.template" -}}
{{- $name := index . 0 -}}
{{- $context := index . 1 -}}
{{- $last := base $context.Template.Name }}
{{- $wtf := $context.Template.Name | replace $last $name -}}
{{ include $wtf $context }}
{{- end -}}

{{/*
Render the ServiceAccount used by network function Pods.
No network function in this chart calls the Kubernetes API, so no Role or
RoleBinding is granted and token automounting is disabled (least privilege).
*/}}
{{- define "omec-sub-provision.service_account" -}}
{{- $context := index . 1 -}}
{{- $saName := index . 0 -}}
{{- $saNamespace := $context.Release.Namespace }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $saName }}
  namespace: {{ $saNamespace }}
  labels:
{{ tuple $saName $context | include "omec-sub-provision.metadata_labels" | indent 4 }}
automountServiceAccountToken: false
{{- end -}}

{{/*
Render init container for coredump.
*/}}
{{- define "omec-sub-provision.coredump_init" -}}
{{- $pod := index . 0 -}}
{{- $context := index . 1 -}}
- name: {{ $pod }}-coredump-init
  image: {{ $context.Values.images.tags.init | quote }}
  imagePullPolicy: {{ $context.Values.images.pullPolicy }}
  securityContext:
    privileged: true
    runAsUser: 0
  command: ["bash", "-xc"]
  args:
    - echo '/tmp/coredump/core.%h.%e.%t' > /mnt/host-rootfs/proc/sys/kernel/core_pattern
  volumeMounts:
    - name: host-rootfs
      mountPath: /mnt/host-rootfs
{{- end -}}

{{/*
Startup, liveness and readiness probes of a network function container: a TCP
connect to the port the function serves on, the same port its Service
publishes. The startup probe gates the liveness probe: a function that waits
for a peer at start (MongoDB, the NRF) does not open its port until the peer
answers, and must not be restarted for that. Each probe is tuned or turned
off under .Values.probes; every field besides "enabled" is passed to the probe
as it is.
Usage: {{ tuple <port> . | include "omec-sub-provision.probes" | nindent 8 }}
*/}}
{{- define "omec-sub-provision.probes" -}}
{{- $port := index . 0 -}}
{{- $probes := (index . 1).Values.probes -}}
{{- if $probes.startup.enabled }}
startupProbe:
  tcpSocket:
    port: {{ $port }}
{{- toYaml (omit $probes.startup "enabled") | nindent 2 }}
{{- end }}
{{- if $probes.liveness.enabled }}
livenessProbe:
  tcpSocket:
    port: {{ $port }}
{{- toYaml (omit $probes.liveness "enabled") | nindent 2 }}
{{- end }}
{{- if $probes.readiness.enabled }}
readinessProbe:
  tcpSocket:
    port: {{ $port }}
{{- toYaml (omit $probes.readiness "enabled") | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
IPv6 and dual-stack, opt-in through global.network (see values.yaml); the same
helpers as in 5g-control-plane. Every helper below renders nothing while
global.network is unset.

"omec-sub-provision.network" returns global.network, validated, as YAML: use it
with fromYaml.
*/}}
{{- define "omec-sub-provision.network" -}}
{{- $global := .Values.global | default dict -}}
{{- $network := get $global "network" | default dict -}}
{{- $policy := get $network "ipFamilyPolicy" | default "" -}}
{{- $families := get $network "ipFamilies" | default list -}}
{{- $preferred := get $network "preferredFamily" | default "" -}}
{{- if not (has $policy (list "" "SingleStack" "PreferDualStack" "RequireDualStack")) -}}
{{- fail (printf "global.network.ipFamilyPolicy is %q, expected SingleStack, PreferDualStack or RequireDualStack" $policy) -}}
{{- end -}}
{{- if not (kindIs "slice" $families) -}}
{{- fail "global.network.ipFamilies must be a list, such as [IPv6] or [IPv4, IPv6]" -}}
{{- end -}}
{{- if or (gt (len $families) 2) (ne (len $families) (len (uniq $families))) -}}
{{- fail (printf "global.network.ipFamilies is %v, expected one or two distinct families" $families) -}}
{{- end -}}
{{- range $families -}}
{{- if not (has . (list "IPv4" "IPv6")) -}}
{{- fail (printf "global.network.ipFamilies contains %q, expected IPv4 or IPv6" .) -}}
{{- end -}}
{{- end -}}
{{- if and (eq $policy "SingleStack") (gt (len $families) 1) -}}
{{- fail "global.network.ipFamilyPolicy SingleStack takes a single entry in global.network.ipFamilies" -}}
{{- end -}}
{{- if not (has $preferred (list "" "IPv4" "IPv6")) -}}
{{- fail (printf "global.network.preferredFamily is %q, expected IPv4 or IPv6" $preferred) -}}
{{- end -}}
{{- if and $preferred $families (not (has $preferred $families)) -}}
{{- fail (printf "global.network.preferredFamily %s is not in global.network.ipFamilies %v" $preferred $families) -}}
{{- end -}}
{{- toYaml (dict "ipFamilyPolicy" $policy "ipFamilies" $families "preferredFamily" $preferred) -}}
{{- end -}}

{{/*
"true" when global.network sets anything, empty otherwise.
*/}}
{{- define "omec-sub-provision.network_enabled" -}}
{{- $network := include "omec-sub-provision.network" . | fromYaml -}}
{{- if or $network.ipFamilyPolicy $network.ipFamilies $network.preferredFamily -}}
true
{{- end -}}
{{- end -}}

{{/*
The ipFamilyPolicy and ipFamilies fields of a Service spec, each only when set
in global.network, on new lines at the given indent.
Usage: {{- tuple 2 . | include "omec-sub-provision.service_ip_families" }}
*/}}
{{- define "omec-sub-provision.service_ip_families" -}}
{{- $indent := index . 0 -}}
{{- $network := include "omec-sub-provision.network" (index . 1) | fromYaml -}}
{{- $lines := list -}}
{{- with $network.ipFamilyPolicy -}}
{{- $lines = append $lines (printf "ipFamilyPolicy: %s" .) -}}
{{- end -}}
{{- with $network.ipFamilies -}}
{{- $lines = append $lines "ipFamilies:" -}}
{{- range . -}}
{{- $lines = append $lines (printf "  - %s" .) -}}
{{- end -}}
{{- end -}}
{{- if $lines -}}
{{- join "\n" $lines | nindent $indent -}}
{{- end -}}
{{- end -}}

{{/*
POD_IPS, every address of the pod (status.podIPs, comma-separated), next to
POD_IP (status.podIP, the primary family only). Only when global.network is
set, on new lines at the given indent.
Usage: {{- tuple 8 . | include "omec-sub-provision.pod_ips_env" }}
*/}}
{{- define "omec-sub-provision.pod_ips_env" -}}
{{- $indent := index . 0 -}}
{{- if include "omec-sub-provision.network_enabled" (index . 1) -}}
{{- list "- name: POD_IPS" "  valueFrom:" "    fieldRef:" "      fieldPath: status.podIPs" | join "\n" | nindent $indent -}}
{{- end -}}
{{- end -}}
