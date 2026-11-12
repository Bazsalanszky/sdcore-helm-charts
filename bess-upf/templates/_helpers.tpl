{{- /*

# Copyright (c) 2026 Intel Corporation
# Copyright 2020-present Open Networking Foundation
#
# SPDX-License-Identifier: Apache-2.0

*/ -}}

{{/*
Renders a set of standardised labels.
*/}}
{{- define "omec-user-plane.metadata_labels" -}}
{{- $application := index . 0 -}}
{{- $context := index . 1 -}}
release: {{ $context.Release.Name }}
app: {{ $application }}
{{- end -}}

{{/*
Render the given template.
*/}}
{{- define "omec-user-plane.template" -}}
{{- $name := index . 0 -}}
{{- $context := index . 1 -}}
{{- $last := base $context.Template.Name }}
{{- $wtf := $context.Template.Name | replace $last $name -}}
{{ include $wtf $context }}
{{- end -}}

{{/*
Render init container for coredump.
*/}}
{{- define "omec-user-plane.coredump_init" -}}
{{- $pod := index . 0 -}}
{{- $context := index . 1 -}}
- name: {{ $pod }}-coredump-init
  image: {{ $context.Values.images.tags.tools | quote }}
  imagePullPolicy: {{ $context.Values.images.pullPolicy }}
  securityContext:
    privileged: true
    runAsUser: 0
  command: ["sh", "-xc"]
  args:
    - echo '/tmp/coredump/core.%h.%e.%t' > /mnt/host-rootfs/proc/sys/kernel/core_pattern
  volumeMounts:
    - name: host-rootfs
      mountPath: /mnt/host-rootfs
{{- end -}}

{{/*
Render SR-IOV CNI init container. Use mode "init-net" for the init-net DaemonSet,
or "sriov-device-plugin" for the sriov-device-plugin initContainer.
*/}}
{{- define "omec-user-plane.sriov_init_container" -}}
{{- $mode := .mode | default "sriov-device-plugin" -}}
- name: init-sriov-plugin
  image: {{ .Values.images.repository }}{{ .Values.images.tags.sriov }}
  imagePullPolicy: {{ .Values.images.pullPolicy }}
  command: ["bash", "-c"]
{{- if eq $mode "init-net" }}
{{- $commands := list }}
{{- range (list "vfioveth" "jq" "static") }}
{{- $commands = append $commands (printf "yes | cp /tmp/cni/bin/%s /host/opt/cni/bin/" .) }}
{{- end }}
{{- range (list "vfioveth" "static") }}
{{- $commands = append $commands (printf "chmod +x /host/opt/cni/bin/%s" .) }}
{{- end }}
{{- $commands = append $commands "trap : TERM INT" }}
{{- $commands = append $commands "sleep infinity & wait" }}
  args:
    - {{ join "; " $commands | quote }}
{{- else }}
{{- $commands := list }}
{{- range (list "sriov" "vfioveth" "jq" "static" "dhcp") }}
{{- $commands = append $commands (printf "cp /tmp/cni/bin/%s /host/opt/cni/bin/" .) }}
{{- end }}
{{- range (list "vfioveth") }}
{{- $commands = append $commands (printf "chmod +x /host/opt/cni/bin/%s" .) }}
{{- end }}
  args:
    - {{ join "; " $commands | quote }}
{{- end }}
  volumeMounts:
    - name: cni-bin
      mountPath: /host/opt/cni/bin
{{- end -}}

{{/*
Render a Service's metadata and the spec up to its ports: labels, annotations,
type, IP families, external IPs and selector. The caller adds the ports.
Usage: {{ tuple "upf-http" "upf" . | include "omec-user-plane.service_head" }}
*/}}
{{- define "omec-user-plane.service_head" -}}
{{- $name := index . 0 -}}
{{- $app := index . 1 -}}
{{- $context := index . 2 -}}
metadata:
  name: {{ $name }}
  labels:
{{ tuple $app $context | include "omec-user-plane.metadata_labels" | indent 4 }}
{{- with $context.Values.service.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
{{- end }}
spec:
  type: {{ $context.Values.service.type }}
{{- tuple 2 $context | include "omec-user-plane.service_ip_families" }}
{{- tuple 2 $context.Values.service.externalIp $context.Values.service.externalIPs | include "omec-user-plane.external_ips" }}
  selector:
{{ tuple $app $context | include "omec-user-plane.metadata_labels" | indent 4 }}
{{- end -}}

{{/*
Render one port of the UPF Services. The nodePort is only set when the Service
is of type NodePort.
Usage: {{- tuple "pfcp" "UDP" 8805 .Values.service.nodePort . | include "omec-user-plane.service_port" | nindent 2 }}
*/}}
{{- define "omec-user-plane.service_port" -}}
{{- $name := index . 0 -}}
{{- $protocol := index . 1 -}}
{{- $port := index . 2 -}}
{{- $nodePort := index . 3 -}}
{{- $context := index . 4 -}}
- name: {{ $name }}
  protocol: {{ $protocol }}
  port: {{ $port }}
{{- if and (eq $context.Values.service.type "NodePort") $nodePort }}
  nodePort: {{ $nodePort }}
{{- end }}
{{- end -}}

{{/*
IPv6 and dual-stack, opt-in through global.network (see values.yaml); the same
helpers as in 5g-control-plane. Every helper below renders nothing while
global.network and the IPv6 values under config.upf are unset.

"omec-user-plane.network" returns global.network, validated, as YAML: use it
with fromYaml.
*/}}
{{- define "omec-user-plane.network" -}}
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
"true" when the UPF pod uses IPv6: config.upf.ipv6.enabled when it is set,
else IPv6 in global.network.ipFamilies or as global.network.preferredFamily.
*/}}
{{- define "omec-user-plane.ipv6_enabled" -}}
{{- $ipv6 := .Values.config.upf.ipv6 | default dict -}}
{{- if kindIs "bool" $ipv6.enabled -}}
{{- if $ipv6.enabled }}true{{ end -}}
{{- else -}}
{{- $network := include "omec-user-plane.network" . | fromYaml -}}
{{- if or (has "IPv6" $network.ipFamilies) (eq $network.preferredFamily "IPv6") }}true{{ end -}}
{{- end -}}
{{- end -}}

{{/*
The ipFamilyPolicy and ipFamilies fields of a Service spec, each only when set
in global.network, on new lines at the given indent.
Usage: {{- tuple 2 . | include "omec-user-plane.service_ip_families" }}
*/}}
{{- define "omec-user-plane.service_ip_families" -}}
{{- $indent := index . 0 -}}
{{- $network := include "omec-user-plane.network" (index . 1) | fromYaml -}}
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
The externalIPs field of a Service spec, from a scalar externalIp (kept for
existing values) and a list externalIPs, e.g. one address per family. Nothing
when neither is set.
Usage: {{- tuple 2 .Values.service.externalIp .Values.service.externalIPs | include "omec-user-plane.external_ips" }}
*/}}
{{- define "omec-user-plane.external_ips" -}}
{{- $indent := index . 0 -}}
{{- $ips := list -}}
{{- with index . 1 -}}
{{- $ips = append $ips . -}}
{{- end -}}
{{- range (index . 2 | default list) -}}
{{- $ips = append $ips . -}}
{{- end -}}
{{- if $ips -}}
{{- $lines := list "externalIPs:" -}}
{{- range uniq $ips -}}
{{- $lines = append $lines (printf "  - %v" .) -}}
{{- end -}}
{{- join "\n" $lines | nindent $indent -}}
{{- end -}}
{{- end -}}

{{/*
The addresses of the access or core interface, as the JSON list of Multus's
"ips": ips when it is set (addresses of either family), else ip.
Usage: {{ include "omec-user-plane.interface_ips" .Values.config.upf.access }}
*/}}
{{- define "omec-user-plane.interface_ips" -}}
{{- $ips := .ips | default (list .ip) -}}
{{- $quoted := list -}}
{{- range $ips -}}
{{- $quoted = append $quoted (quote .) -}}
{{- end -}}
{{- join ", " $quoted -}}
{{- end -}}

{{/*
The gateway of the access or core interface for a family, "ipv4" or "ipv6":
gateways.<family>, and for IPv4 the older scalar gateway. Empty when unset.
Usage: {{ tuple .Values.config.upf.core "ipv6" | include "omec-user-plane.gateway" }}
*/}}
{{- define "omec-user-plane.gateway" -}}
{{- $interface := index . 0 -}}
{{- $family := index . 1 -}}
{{- $gateways := $interface.gateways | default dict -}}
{{- if eq $family "ipv6" -}}
{{- get $gateways "ipv6" -}}
{{- else -}}
{{- get $gateways "ipv4" | default $interface.gateway -}}
{{- end -}}
{{- end -}}

{{/*
The commands of the bess-init container that route the RAN subnets through the
access gateway and the default route through the core gateway, one per entry.
An address with a colon is IPv6 and goes through the gateway of that family.
The IPv4 default route is the one the chart has always added (metric 110 by
default). An IPv6 default route through core is opt-in, with
core.defaultRouteMetric.ipv6: the default route on eth0 that IPv6 CNIs add
usually has metric 1024, and a lower metric here would send N4, DNS and
every other pod-network destination off a route on eth0 through core.
*/}}
{{- define "omec-user-plane.init_routes" -}}
{{- $upf := .Values.config.upf -}}
{{- $accessIf := index .Values.config.upf.cfgFiles "upf.jsonc" "access" "ifname" -}}
{{- $coreIf := index .Values.config.upf.cfgFiles "upf.jsonc" "core" "ifname" -}}
{{- $cmds := list -}}
{{- $subnets := list $upf.ran.subnet -}}
{{- range ($upf.ran.subnets | default list) -}}
{{- $subnets = append $subnets . -}}
{{- end -}}
{{- range $subnets -}}
{{- if contains ":" . -}}
{{- $gw := tuple $upf.access "ipv6" | include "omec-user-plane.gateway" -}}
{{- if not $gw -}}
{{- fail (printf "config.upf.ran subnet %s is IPv6: set config.upf.access.gateways.ipv6" .) -}}
{{- end -}}
{{- $cmds = append $cmds (printf "ip -6 route replace %s via %s dev %s;" . $gw $accessIf) -}}
{{- else -}}
{{- $cmds = append $cmds (printf "ip route replace %s via %s;" . (tuple $upf.access "ipv4" | include "omec-user-plane.gateway")) -}}
{{- end -}}
{{- end -}}
{{- $metric := $upf.core.defaultRouteMetric | default dict -}}
{{- $cmds = append $cmds (printf "ip route replace default via %s metric %v;" (tuple $upf.core "ipv4" | include "omec-user-plane.gateway") (get $metric "ipv4" | default 110)) -}}
{{- with get $metric "ipv6" -}}
{{- $gw := tuple $upf.core "ipv6" | include "omec-user-plane.gateway" -}}
{{- if not $gw -}}
{{- fail "config.upf.core.defaultRouteMetric.ipv6 is set: set config.upf.core.gateways.ipv6" -}}
{{- end -}}
{{- $cmds = append $cmds (printf "ip -6 route replace default via %s dev %s metric %v;" $gw $coreIf .) -}}
{{- end -}}
{{- join "\n" $cmds -}}
{{- end -}}

{{/*
"true" when the UPF has an IPv6 address on access or core (config.upf.access
or config.upf.core ips, or the older scalar ip); empty otherwise.
Usage: {{ include "omec-user-plane.has_ipv6_address" . }}
*/}}
{{- define "omec-user-plane.has_ipv6_address" -}}
{{- $found := false -}}
{{- range (list .Values.config.upf.access .Values.config.upf.core) -}}
{{- range (.ips | default (list .ip)) -}}
{{- if and . (contains ":" (toString .)) -}}
{{- $found = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $found }}true{{ end -}}
{{- end -}}

{{/*
The CNI plugins chained after the access or core interface's own plugin: the
tuning plugin, setting config.upf.ipv6.interfaceSysctls on the interface. It
is chained when the pod uses IPv6, or when the UPF has an IPv6 address on
access or core (unless config.upf.ipv6.enabled is false). Empty otherwise.

net.ipv6.conf.all.forwarding, in the default interfaceSysctls, is kept only
when the UPF has an IPv6 address: IPv6 forwarding in the pod matters only then,
and a UPF without one renders as before. A key set to null is left out, so one
default can be dropped without restating the others.
Usage: {{ include "omec-user-plane.tuning_plugin" . }}
*/}}
{{- define "omec-user-plane.tuning_plugin" -}}
{{- $ipv6 := .Values.config.upf.ipv6 | default dict -}}
{{- $address6 := include "omec-user-plane.has_ipv6_address" . -}}
{{- $optedOut := and (kindIs "bool" $ipv6.enabled) (not $ipv6.enabled) -}}
{{- if or (include "omec-user-plane.ipv6_enabled" .) (and $address6 (not $optedOut)) -}}
{{- $sysctls := dict -}}
{{- range $key, $value := ($ipv6.interfaceSysctls | default dict) -}}
{{- if and (not (kindIs "invalid" $value)) (or $address6 (ne $key "net.ipv6.conf.all.forwarding")) -}}
{{- $_ := set $sysctls $key $value -}}
{{- end -}}
{{- end -}}
{{- with $sysctls -}}
{{- dict "type" "tuning" "sysctl" . | toJson -}}
{{- end -}}
{{- end -}}
{{- end -}}
