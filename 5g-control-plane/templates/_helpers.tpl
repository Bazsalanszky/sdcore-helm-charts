{{- /*

# Copyright (c) 2026 Intel Corporation
# Copyright 2020-present Open Networking Foundation
#
# SPDX-License-Identifier: Apache-2.0

*/ -}}

{{/*
Renders a set of standardised labels
*/}}
{{- define "5g-control-plane.metadata_labels" -}}
{{- $application := index . 0 -}}
{{- $context := index . 1 -}}
release: {{ $context.Release.Name }}
app: {{ $application }}
{{- end -}}

{{/*
Render the given template.
*/}}
{{- define "5g-control-plane.template" -}}
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
{{- define "5g-control-plane.service_account" -}}
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
{{ tuple $saName $context | include "5g-control-plane.metadata_labels" | indent 4 }}
automountServiceAccountToken: false
{{- end -}}

{{/*
Render init container for coredump.
*/}}
{{- define "5g-control-plane.coredump_init" -}}
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
Expand the name of the chart.
*/}}
{{- define "5g-control-plane.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Shared public CA secret name.
*/}}
{{- define "5g-control-plane.shared-ca-secret-name" -}}
{{- printf "%s-ca" (include "5g-control-plane.name" .) -}}
{{- end -}}

{{/*
Shared private CA secret name.
*/}}
{{- define "5g-control-plane.shared-ca-private-secret-name" -}}
{{- $config := get .Values "config" | default dict -}}
{{- $certsConfig := get $config "certs" | default dict -}}
{{- $sharedCaConfig := get $certsConfig "sharedCA" | default dict -}}
{{- $existingPrivateSecret := get $sharedCaConfig "existingPrivateSecret" -}}
{{- default (printf "%s-ca-private" (include "5g-control-plane.name" .)) $existingPrivateSecret -}}
{{- end -}}

{{/*
Whether the chart should manage the shared private CA Secret.
*/}}
{{- define "5g-control-plane.manage-shared-ca-private-secret" -}}
{{- $config := get .Values "config" | default dict -}}
{{- $certsConfig := get $config "certs" | default dict -}}
{{- $sharedCaConfig := get $certsConfig "sharedCA" | default dict -}}
{{- if get $sharedCaConfig "existingPrivateSecret" -}}
false
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
Cluster DNS domain to include in service certificate SANs. Empty omits the FQDN SAN.
*/}}
{{- define "5g-control-plane.cluster-domain" -}}
{{- $config := get .Values "config" | default dict -}}
{{- $certsConfig := get $config "certs" | default dict -}}
{{- if hasKey $certsConfig "clusterDomain" -}}
{{- get $certsConfig "clusterDomain" -}}
{{- else -}}
cluster.local
{{- end -}}
{{- end -}}

{{/*
Shared CA certificate validity in days.
*/}}
{{- define "5g-control-plane.shared-ca-validity-days" -}}
{{- $config := get .Values "config" | default dict -}}
{{- $certsConfig := get $config "certs" | default dict -}}
{{- $sharedCaConfig := get $certsConfig "sharedCA" | default dict -}}
{{- get $sharedCaConfig "validityDays" | default 365 | int -}}
{{- end -}}

{{/*
Leaf certificate validity in days.
*/}}
{{- define "5g-control-plane.leaf-cert-validity-days" -}}
{{- $config := get .Values "config" | default dict -}}
{{- $certsConfig := get $config "certs" | default dict -}}
{{- get $certsConfig "leafValidityDays" | default 365 | int -}}
{{- end -}}

{{/*
Whether the init container should append system roots from its own image.
*/}}
{{- define "5g-control-plane.include-system-root-bundle" -}}
{{- $config := get .Values "config" | default dict -}}
{{- $certsConfig := get $config "certs" | default dict -}}
{{- if hasKey $certsConfig "includeSystemRootBundle" -}}
{{- get $certsConfig "includeSystemRootBundle" -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
Annotation key used to mark leaf cert secrets with the shared CA checksum.
*/}}
{{- define "5g-control-plane.shared-ca-checksum-annotation" -}}
sdcore.omec-project.org/shared-ca-sha256
{{- end -}}

{{/*
Annotation key used to mark leaf cert secrets with the leaf generation inputs checksum.
*/}}
{{- define "5g-control-plane.leaf-cert-inputs-checksum-annotation" -}}
sdcore.omec-project.org/leaf-cert-inputs-sha256
{{- end -}}

{{/*
Ensure internal render cache exists.
*/}}
{{- define "5g-control-plane.ensure-render-cache" -}}
{{- $context := . -}}
{{- if not (hasKey $context.Values "_sdcoreInternal") -}}
{{- $_ := set $context.Values "_sdcoreInternal" (dict) -}}
{{- end -}}
{{- end -}}

{{/*
Compute the desired shared CA once per render and cache it.
*/}}
{{- define "5g-control-plane.ensure-shared-ca" -}}
{{- $context := . -}}
{{- include "5g-control-plane.ensure-render-cache" $context -}}
{{- $cache := index $context.Values "_sdcoreInternal" -}}
{{- if not (hasKey $cache "sharedCa") -}}
{{- $privateCaName := include "5g-control-plane.shared-ca-private-secret-name" $context -}}
{{- $managePrivateCaSecret := eq (include "5g-control-plane.manage-shared-ca-private-secret" $context | trim) "true" -}}
{{- $sharedCaValidityDays := include "5g-control-plane.shared-ca-validity-days" $context | int -}}
{{- $existingCaSecret := lookup "v1" "Secret" $context.Release.Namespace $privateCaName -}}
{{- $caCrt := "" -}}
{{- $caKey := "" -}}
{{- if and (not $managePrivateCaSecret) (not $existingCaSecret) -}}
{{- fail (printf "existing private CA Secret %q was configured but not found" $privateCaName) -}}
{{- end -}}
{{- if $existingCaSecret -}}
{{- $hasCaCrt := hasKey $existingCaSecret.data "ca.crt" -}}
{{- $hasCaKey := hasKey $existingCaSecret.data "ca.key" -}}
{{- if ne $hasCaCrt $hasCaKey -}}
{{- fail (printf "existing Secret %q must contain both ca.crt and ca.key or neither" $privateCaName) -}}
{{- end -}}
{{- if and $hasCaCrt $hasCaKey -}}
{{- $caCrt = index $existingCaSecret.data "ca.crt" | default "" | b64dec -}}
{{- $caKey = index $existingCaSecret.data "ca.key" | default "" | b64dec -}}
{{- if or (eq $caCrt "") (eq $caKey "") -}}
{{- fail (printf "existing Secret %q contains empty ca.crt or ca.key data" $privateCaName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and (not $managePrivateCaSecret) (or (eq $caCrt "") (eq $caKey "")) -}}
{{- fail (printf "existing private CA Secret %q must contain non-empty ca.crt and ca.key data" $privateCaName) -}}
{{- end -}}
{{- $ca := "" -}}
{{- if and $caCrt $caKey -}}
{{- $ca = buildCustomCert (index $existingCaSecret.data "ca.crt" | default "") (index $existingCaSecret.data "ca.key" | default "") -}}
{{- else -}}
{{- $ca = genCA $privateCaName $sharedCaValidityDays -}}
{{- end -}}
{{- $_ := set $cache "sharedCa" (dict "object" $ca "cert" $ca.Cert "key" $ca.Key "checksum" ($ca.Cert | sha256sum)) -}}
{{- end -}}
{{- end -}}

{{/*
Return the desired shared CA certificate PEM.
*/}}
{{- define "5g-control-plane.shared-ca-cert" -}}
{{- $context := . -}}
{{- include "5g-control-plane.ensure-shared-ca" $context -}}
{{- $cache := index $context.Values "_sdcoreInternal" -}}
{{- $sharedCa := index $cache "sharedCa" -}}
{{- index $sharedCa "cert" -}}
{{- end -}}

{{/*
Return the desired shared CA private key PEM.
*/}}
{{- define "5g-control-plane.shared-ca-key" -}}
{{- $context := . -}}
{{- include "5g-control-plane.ensure-shared-ca" $context -}}
{{- $cache := index $context.Values "_sdcoreInternal" -}}
{{- $sharedCa := index $cache "sharedCa" -}}
{{- index $sharedCa "key" -}}
{{- end -}}

{{/*
Return the desired shared CA checksum.
*/}}
{{- define "5g-control-plane.shared-ca-checksum" -}}
{{- $context := . -}}
{{- include "5g-control-plane.ensure-shared-ca" $context -}}
{{- $cache := index $context.Values "_sdcoreInternal" -}}
{{- $sharedCa := index $cache "sharedCa" -}}
{{- index $sharedCa "checksum" -}}
{{- end -}}

{{/*
Compute desired leaf certificate material once per render and cache it.
*/}}
{{- define "5g-control-plane.ensure-leaf-cert" -}}
{{- $context := .context -}}
{{- $name := .name -}}
{{- include "5g-control-plane.ensure-shared-ca" $context -}}
{{- $cache := index $context.Values "_sdcoreInternal" -}}
{{- if not (hasKey $cache "leafCerts") -}}
{{- $_ := set $cache "leafCerts" (dict) -}}
{{- end -}}
{{- $leafCerts := index $cache "leafCerts" -}}
{{- if not (hasKey $leafCerts $name) -}}
{{- $sharedCa := index $cache "sharedCa" -}}
{{- $ca := index $sharedCa "object" -}}
{{- $caChecksum := index $sharedCa "checksum" -}}
{{- $leafValidityDays := include "5g-control-plane.leaf-cert-validity-days" $context | int -}}
{{- $namespace := $context.Release.Namespace -}}
{{- $clusterDomain := include "5g-control-plane.cluster-domain" $context | trim -}}
{{- $leafInputsChecksum := printf "%s|%s|%s|%d" $name $namespace $clusterDomain $leafValidityDays | sha256sum -}}
{{- $secretName := printf "%s-certs" $name -}}
{{- $existingSecret := lookup "v1" "Secret" $namespace $secretName -}}
{{- $tlsCrt := "" -}}
{{- $tlsKey := "" -}}
{{- if $existingSecret -}}
{{- $hasTlsCrt := hasKey $existingSecret.data "tls.crt" -}}
{{- $hasTlsKey := hasKey $existingSecret.data "tls.key" -}}
{{- if ne $hasTlsCrt $hasTlsKey -}}
{{- fail (printf "existing Secret %q must contain both tls.crt and tls.key or neither" $secretName) -}}
{{- end -}}
{{- if and $hasTlsCrt $hasTlsKey -}}
{{- $tlsCrt = index $existingSecret.data "tls.crt" | default "" -}}
{{- $tlsKey = index $existingSecret.data "tls.key" | default "" -}}
{{- $annotations := default dict $existingSecret.metadata.annotations -}}
{{- $existingCaChecksum := index $annotations (include "5g-control-plane.shared-ca-checksum-annotation" $context) | default "" -}}
{{- $existingLeafInputsChecksum := index $annotations (include "5g-control-plane.leaf-cert-inputs-checksum-annotation" $context) | default "" -}}
{{- if or (eq $tlsCrt "") (eq $tlsKey "") -}}
{{- fail (printf "existing Secret %q contains empty tls.crt or tls.key data" $secretName) -}}
{{- end -}}
{{- if or (ne $existingCaChecksum $caChecksum) (ne $existingLeafInputsChecksum $leafInputsChecksum) -}}
{{- $tlsCrt = "" -}}
{{- $tlsKey = "" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $tlsCrt $tlsKey -}}
{{- $_ := set $leafCerts $name (dict "data" (printf "tls.crt: %s\ntls.key: %s" $tlsCrt $tlsKey) "checksum" (printf "%s%s" $tlsCrt $tlsKey | sha256sum)) -}}
{{- else -}}
{{- $altNames := list
  $name
  ( printf "%s.%s" $name $namespace )
  ( printf "%s.%s.svc" $name $namespace ) -}}
{{- if $clusterDomain -}}
{{- $altNames = append $altNames (printf "%s.%s.svc.%s" $name $namespace $clusterDomain) -}}
{{- end -}}
{{- $cert := genSignedCert $name nil $altNames $leafValidityDays $ca -}}
{{- $tlsCrt = $cert.Cert | b64enc -}}
{{- $tlsKey = $cert.Key | b64enc -}}
{{- $_ := set $leafCerts $name (dict "data" (printf "tls.crt: %s\ntls.key: %s" $tlsCrt $tlsKey) "checksum" (printf "%s%s" $tlsCrt $tlsKey | sha256sum)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return desired leaf certificate input checksum.
*/}}
{{- define "5g-control-plane.leaf-cert-inputs-checksum" -}}
{{- $context := .context -}}
{{- $name := .name -}}
{{- $namespace := $context.Release.Namespace -}}
{{- $clusterDomain := include "5g-control-plane.cluster-domain" $context | trim -}}
{{- $leafValidityDays := include "5g-control-plane.leaf-cert-validity-days" $context | int -}}
{{- printf "%s|%s|%s|%d" $name $namespace $clusterDomain $leafValidityDays | sha256sum -}}
{{- end -}}

{{/*
Return desired leaf certificate Secret data.
*/}}
{{- define "5g-control-plane.gen-certs" -}}
{{- $context := .context -}}
{{- $name := .name -}}
{{- include "5g-control-plane.ensure-leaf-cert" (dict "context" $context "name" $name) -}}
{{- $cache := index $context.Values "_sdcoreInternal" -}}
{{- $leafCerts := index $cache "leafCerts" -}}
{{- $leafCert := index $leafCerts $name -}}
{{- index $leafCert "data" -}}
{{- end -}}

{{/*
Return desired leaf certificate checksum.
*/}}
{{- define "5g-control-plane.leaf-cert-checksum" -}}
{{- $context := .context -}}
{{- $name := .name -}}
{{- include "5g-control-plane.ensure-leaf-cert" (dict "context" $context "name" $name) -}}
{{- $cache := index $context.Values "_sdcoreInternal" -}}
{{- $leafCerts := index $cache "leafCerts" -}}
{{- $leafCert := index $leafCerts $name -}}
{{- index $leafCert "checksum" -}}
{{- end -}}

{{/*
Render init container that waits for webui to accept connections on the REST
port. The network functions poll webui for their configuration (webuiUri) and
back off exponentially while it is down, and the TCP probes on their SBI ports
pass long before that, so without this wait they start serving late (e.g. UDM
registers with the NRF only after its retry timer expires and AUSF finds no UDM).
Usage: {{ tuple . | include "5g-control-plane.wait_webui" | nindent 6 }}
*/}}
{{- define "5g-control-plane.wait_webui" -}}
{{- $context := index . 0 -}}
- name: wait-webui-config
  image: {{ $context.Values.images.repository }}{{ $context.Values.images.tags.init }}
  imagePullPolicy: {{ $context.Values.images.pullPolicy }}
  command: ['sh', '-c', 'until nslookup webui && nc -z -w 2 webui {{ $context.Values.config.webui.rest.port }}; do echo waiting for webui config port; sleep 4; done;']
{{- end -}}

{{/*
Render init container that builds a CA bundle with system roots plus the shared CA.
*/}}
{{- define "5g-control-plane.certs_init" -}}
{{- $pod := index . 0 -}}
{{- $context := index . 1 -}}
{{- $includeSystemRootBundle := eq (include "5g-control-plane.include-system-root-bundle" $context | trim) "true" -}}
- name: {{ $pod }}-certs-init
  image: {{ $context.Values.images.repository }}{{ $context.Values.images.tags.init }}
  imagePullPolicy: {{ $context.Values.images.pullPolicy }}
  command: ["sh", "-ec"]
  args:
    - |
      set -e
      umask 077
{{ if $includeSystemRootBundle }}
      root_bundle=""
      for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
        if [ -f "$candidate" ]; then
          root_bundle="$candidate"
          break
        fi
      done
{{ end }}
      cp /certs-src/tls.crt /work/tls.crt
      cp /certs-src/tls.key /work/tls.key
      cp /certs-src/ca.crt /work/ca.crt
{{ if $includeSystemRootBundle }}
      if [ -n "$root_bundle" ]; then
        cat "$root_bundle" /certs-src/ca.crt > /work/ca-bundle.crt
      else
        cp /certs-src/ca.crt /work/ca-bundle.crt
      fi
{{ else }}
      cp /certs-src/ca.crt /work/ca-bundle.crt
{{ end }}
        chmod 0644 /work/tls.crt /work/ca.crt /work/ca-bundle.crt
        chmod 0644 /work/tls.key
  volumeMounts:
    - name: certs-src
      mountPath: /certs-src
      readOnly: true
    - name: certs
      mountPath: /work
{{- end -}}

{{/*
Render trust-store environment variables for runtimes using the default system CA loader.
*/}}
{{- define "5g-control-plane.certs_env" -}}
- name: SSL_CERT_FILE
  value: /etc/ssl/certs/ca-certificates.crt
- name: SSL_CERT_DIR
  value: /etc/ssl/certs
{{- end -}}

{{/*
Render volume mounts for leaf certs plus standard trust-store locations.
*/}}
{{- define "5g-control-plane.certs_volume_mounts" -}}
- name: certs
  mountPath: /var/run/certs
  readOnly: true
- name: certs
  mountPath: /etc/ssl/certs/ca-certificates.crt
  subPath: ca-bundle.crt
  readOnly: true
- name: certs
  mountPath: /etc/ssl/cert.pem
  subPath: ca-bundle.crt
  readOnly: true
{{- end -}}

{{/*
Render pod template annotations that trigger a rollout when mounted cert sources change.
*/}}
{{- define "5g-control-plane.certs_pod_annotations" -}}
{{- $name := index . 0 -}}
{{- $context := index . 1 -}}
{{- $sharedCaChecksum := include "5g-control-plane.shared-ca-checksum" $context | trim -}}
{{- $leafSecretName := printf "%s-certs" $name -}}
{{- $leafChecksum := include "5g-control-plane.leaf-cert-checksum" (dict "context" $context "name" $name) | trim -}}
checksum/sdcore-shared-ca: {{ $sharedCaChecksum | quote }}
checksum/{{ $leafSecretName }}: {{ $leafChecksum | quote }}
{{- end -}}

{{/*
Startup, liveness and readiness probes of a network function container: a TCP
connect to the port the function serves on, the same port its Service
publishes. The startup probe gates the liveness probe: a function that waits
for a peer at start (MongoDB, the NRF) does not open its port until the peer
answers, and must not be restarted for that. Each probe is tuned or turned
off under .Values.probes; every field besides "enabled" is passed to the probe
as it is. An optional third element replaces the liveness probe's handler, for
a function that can report more than an open port.
Usage: {{ tuple <port> . | include "5g-control-plane.probes" | nindent 8 }}
       {{ tuple <port> . <liveness handler> | include "5g-control-plane.probes" | nindent 8 }}
*/}}
{{- define "5g-control-plane.probes" -}}
{{- $port := index . 0 -}}
{{- $probes := (index . 1).Values.probes -}}
{{- $liveness := dict "tcpSocket" (dict "port" $port) -}}
{{- if gt (len .) 2 }}
{{- $liveness = index . 2 -}}
{{- end }}
{{- if $probes.startup.enabled }}
startupProbe:
  tcpSocket:
    port: {{ $port }}
{{- toYaml (omit $probes.startup "enabled") | nindent 2 }}
{{- end }}
{{- if $probes.liveness.enabled }}
livenessProbe:
{{- toYaml $liveness | nindent 2 }}
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
The MongoDB URL the network functions use. With mongodb.enabled it
points at the replica set MongoDB's operator runs: the Service <name>-svc, the
replica set <name>, and the SCRAM user the operator creates, whose password
the URL carries. Otherwise config.mongodb.url (or authUrl) as set.
*/}}
{{- define "5g-control-plane.mongodbOperatorUrl" -}}
{{- $m := .Values.mongodb -}}
{{- $password := required "mongodb.password must be set when mongodb.enabled is true" $m.password -}}
{{- printf "mongodb://%s:%s@%s-svc:27017/?replicaSet=%s&authSource=admin" (urlquery $m.user | replace "+" "%20") (urlquery $password | replace "+" "%20") $m.name $m.name -}}
{{- end -}}

{{- define "5g-control-plane.mongodbUrl" -}}
{{- if .Values.mongodb.enabled -}}
{{- include "5g-control-plane.mongodbOperatorUrl" . -}}
{{- else -}}
{{- .Values.config.mongodb.url -}}
{{- end -}}
{{- end -}}

{{- define "5g-control-plane.mongodbAuthUrl" -}}
{{- if .Values.mongodb.enabled -}}
{{- include "5g-control-plane.mongodbOperatorUrl" . -}}
{{- else -}}
{{- .Values.config.mongodb.authUrl -}}
{{- end -}}
{{- end -}}

{{/*
The configuration of a network function whose file carries the MongoDB URL is
a Secret when that URL has the operator's password in it, a ConfigMap
otherwise.
*/}}
{{- define "5g-control-plane.nfConfigKind" -}}
{{- if .Values.mongodb.enabled }}Secret{{ else }}ConfigMap{{ end -}}
{{- end -}}

{{- define "5g-control-plane.nfConfigData" -}}
{{- if .Values.mongodb.enabled }}stringData{{ else }}data{{ end -}}
{{- end -}}

{{/*
A checksum of the MongoDB credentials, on the pods of the functions whose
configuration carries them, so that a password change rolls them out with the
new URL.
*/}}
{{- define "5g-control-plane.mongodbCredentialsChecksum" -}}
{{- printf "%s:%s" .Values.mongodb.user .Values.mongodb.password | sha256sum -}}
{{- end -}}

{{/*
Render one port of a network function Service. The nodePort is only set when
the Service is of type NodePort and the port's values carry one.
Usage: {{- tuple "sbi" .Values.config.<nf>.sbi "TCP" .Values.config.<nf>.serviceType | include "5g-control-plane.service_port" | nindent 2 }}
*/}}
{{- define "5g-control-plane.service_port" -}}
{{- $name := index . 0 -}}
{{- $port := index . 1 -}}
{{- $protocol := index . 2 -}}
{{- $serviceType := index . 3 -}}
- name: {{ $name }}
  port: {{ $port.port }}
  protocol: {{ $protocol }}
{{- if and (eq $serviceType "NodePort") $port.nodePort }}
  nodePort: {{ $port.nodePort }}
{{- end }}
{{- end -}}

{{/*
Render the pod spec fields every network function Pod shares: the security
context, the ServiceAccount, the node selector and the image pull secrets.
Usage: {{- tuple "<nf>" . | include "5g-control-plane.pod_common" | nindent 6 }}
*/}}
{{- define "5g-control-plane.pod_common" -}}
{{- $serviceAccount := index . 0 -}}
{{- $context := index . 1 -}}
{{- if and $context.Values.podSecurityContext (not $context.Values.config.coreDump.enabled) }}
securityContext:
{{ toYaml $context.Values.podSecurityContext | indent 2 }}
{{- end }}
serviceAccountName: {{ $serviceAccount }}
{{- if $context.Values.nodeSelectors.enabled }}
nodeSelector:
  {{ $context.Values.nodeSelectors.label }}: {{ $context.Values.nodeSelectors.value | quote }}
{{- end }}
{{- if hasKey $context.Values.images "pullSecrets" }}
imagePullSecrets:
{{ toYaml $context.Values.images.pullSecrets | indent 2 }}
{{- end }}
{{- end -}}

{{/*
Render init container that waits for a Service name to resolve in DNS.
Usage: {{- tuple "wait-<nf>-module" "<service>" . | include "5g-control-plane.wait_dns" | nindent 6 }}
*/}}
{{- define "5g-control-plane.wait_dns" -}}
{{- $name := index . 0 -}}
{{- $service := index . 1 -}}
{{- $context := index . 2 -}}
- name: {{ $name }}
  image: {{ $context.Values.images.repository }}{{ $context.Values.images.tags.init }}
  imagePullPolicy: {{ $context.Values.images.pullPolicy }}
  command: ['sh', '-c', 'until nslookup {{ $service }}; do echo waiting for {{ $service }}; sleep 4; done;']
{{- end -}}

{{/*
Render the volumes that hold the certificates of a network function (the
emptyDir the certs init container fills, and the Secrets it reads) and, with
config.coreDump.enabled, the host paths the coredump init container needs.
Usage: {{- tuple "<nf>" . | include "5g-control-plane.certs_volumes" | nindent 6 }}
*/}}
{{- define "5g-control-plane.certs_volumes" -}}
{{- $name := index . 0 -}}
{{- $context := index . 1 -}}
- name: certs
  emptyDir: {}
- name: certs-src
  projected:
    sources:
      - secret:
          name: {{ $name }}-certs
          items:
            - key: tls.crt
              path: tls.crt
            - key: tls.key
              path: tls.key
      - secret:
          name: {{ include "5g-control-plane.shared-ca-secret-name" $context }}
          items:
            - key: ca.crt
              path: ca.crt
{{- if $context.Values.config.coreDump.enabled }}
- name: host-rootfs
  hostPath:
    path: /
- name: coredump
  hostPath:
    path: {{ $context.Values.config.coreDump.path }}
{{- end }}
{{- end -}}

{{/*
IPv6 and dual-stack, opt-in through global.network (see values.yaml). Every
helper below renders nothing while global.network is unset, so an IPv4
deployment gets the same manifests as before the block existed. The same
helpers, with their own prefix, are in bess-upf and omec-sub-provision.

"5g-control-plane.network" returns global.network, validated, as YAML: use it
with fromYaml.
*/}}
{{- define "5g-control-plane.network" -}}
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
{{- define "5g-control-plane.network_enabled" -}}
{{- $network := include "5g-control-plane.network" . | fromYaml -}}
{{- if or $network.ipFamilyPolicy $network.ipFamilies $network.preferredFamily -}}
true
{{- end -}}
{{- end -}}

{{/*
"true" when the deployment uses IPv6: IPv6 is in global.network.ipFamilies or
is global.network.preferredFamily.
*/}}
{{- define "5g-control-plane.ipv6_enabled" -}}
{{- $network := include "5g-control-plane.network" . | fromYaml -}}
{{- if or (has "IPv6" $network.ipFamilies) (eq $network.preferredFamily "IPv6") -}}
true
{{- end -}}
{{- end -}}

{{/*
The primary family, that of the Services and of POD_IP: the first entry of
global.network.ipFamilies, else global.network.preferredFamily, else empty.
*/}}
{{- define "5g-control-plane.primary_family" -}}
{{- $network := include "5g-control-plane.network" . | fromYaml -}}
{{- if $network.ipFamilies -}}
{{- first $network.ipFamilies -}}
{{- else -}}
{{- $network.preferredFamily -}}
{{- end -}}
{{- end -}}

{{/*
The family of the fields that hold a single address: global.network.preferredFamily,
else the primary family, else empty.
*/}}
{{- define "5g-control-plane.preferred_family" -}}
{{- $network := include "5g-control-plane.network" . | fromYaml -}}
{{- $network.preferredFamily | default (include "5g-control-plane.primary_family" .) -}}
{{- end -}}

{{/*
The ipFamilyPolicy and ipFamilies fields of a Service spec, each only when set
in global.network, on new lines at the given indent.
Usage: {{- tuple 2 . | include "5g-control-plane.service_ip_families" }}
*/}}
{{- define "5g-control-plane.service_ip_families" -}}
{{- $indent := index . 0 -}}
{{- $network := include "5g-control-plane.network" (index . 1) | fromYaml -}}
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
Usage: {{- tuple 2 .Values.config.<nf>.externalIp .Values.config.<nf>.externalIPs | include "5g-control-plane.external_ips" }}
*/}}
{{- define "5g-control-plane.external_ips" -}}
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
POD_IPS, every address of the pod (status.podIPs, comma-separated), next to
POD_IP (status.podIP, the primary family only). Only when global.network is
set, on new lines at the given indent.
Usage: {{- tuple 8 . | include "5g-control-plane.pod_ips_env" }}
*/}}
{{- define "5g-control-plane.pod_ips_env" -}}
{{- $indent := index . 0 -}}
{{- if include "5g-control-plane.network_enabled" (index . 1) -}}
{{- list "- name: POD_IPS" "  valueFrom:" "    fieldRef:" "      fieldPath: status.podIPs" | join "\n" | nindent $indent -}}
{{- end -}}
{{- end -}}

{{/*
Fills in the family-neutral SBI binding address of a network function: with
IPv6 enabled, an sbi section that does not set bindingAddr gets "::", which
the functions bind dual-stack. bindingIPv4 stays as it is, as the alias older
images read. registerIPv6 and bindingAddr set in cfgFiles are kept; nothing
changes without IPv6.
Usage: {{- tuple $sbi . | include "5g-control-plane.sbi_defaults" }}
*/}}
{{- define "5g-control-plane.sbi_defaults" -}}
{{- $sbi := index . 0 -}}
{{- if and (include "5g-control-plane.ipv6_enabled" (index . 1)) (not (hasKey $sbi "bindingAddr")) -}}
{{- $_ := set $sbi "bindingAddr" "::" -}}
{{- end -}}
{{- end -}}

{{/*
The additionalMongodConfig of the MongoDBCommunity resource, as YAML (empty
when there is none): mongodb.additionalMongodConfig, over the IPv6 settings
when mongod serves IPv6.
mongodb.ipv6 decides: true or false, or unset to follow global.network, which
turns IPv6 on when the deployment uses IPv6 (see ipv6_enabled). mongod then
binds "::" and "0.0.0.0" with net.ipv6: MongoDB's automation agent ignores
net.bindIpAll (mongodb/mongodb-kubernetes#1191), and "::" alone is IPv6-only,
which would shut out the IPv4 clients of a cluster whose primary family, and
so that of the operator's single-stack Service, is IPv4.
*/}}
{{- define "5g-control-plane.mongod_config" -}}
{{- $m := .Values.mongodb -}}
{{- $ipv6 := eq (include "5g-control-plane.ipv6_enabled" .) "true" -}}
{{- if kindIs "bool" $m.ipv6 -}}
{{- $ipv6 = $m.ipv6 -}}
{{- end -}}
{{- $config := dict -}}
{{- if $ipv6 -}}
{{- $config = dict "net" (dict "ipv6" true "bindIp" "::,0.0.0.0") -}}
{{- end -}}
{{- with $m.additionalMongodConfig -}}
{{- $config = mergeOverwrite $config (deepCopy .) -}}
{{- end -}}
{{- if $config -}}
{{- toYaml $config -}}
{{- end -}}
{{- end -}}
