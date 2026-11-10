<!--
SPDX-FileCopyrightText: 2026 Balázs Toldi
SPDX-License-Identifier: Apache-2.0
-->

# IPv6 and dual-stack clusters

The charts run on IPv4-only clusters by default and render exactly what they
rendered before IPv6 support was added. For an IPv6-only or a dual-stack
cluster, set `global.network` once in the `sd-core` umbrella chart, or in each
chart installed on its own:

```yaml
global:
  network:
    ipFamilyPolicy: PreferDualStack   # SingleStack | PreferDualStack | RequireDualStack
    ipFamilies: [IPv6, IPv4]          # [IPv4] | [IPv6] | [IPv4, IPv6] | [IPv6, IPv4], primary first
    preferredFamily: IPv6             # single-address fields; defaults to the first of ipFamilies
```

This directory has the values for each cluster mode. Use them with your own
values, for example `helm install sd-core ./sdcore-helm-charts -f docs/ipv6/values-v6.yaml -f my-values.yaml`.

| Mode | Cluster | Values |
|---|---|---|
| v4 | IPv4 only | [values-v4.yaml](values-v4.yaml) (empty `global.network`) |
| v6 | IPv6 only | [values-v6.yaml](values-v6.yaml) |
| dual-v4 | dual-stack, IPv4 listed first in the pod and Service CIDRs | [values-dual-v4.yaml](values-dual-v4.yaml) |
| dual-v6 | dual-stack, IPv6 listed first | [values-dual-v6.yaml](values-dual-v6.yaml) |

The kind clusters of the IPv6 workflow show each mode's cluster settings:
[kind-v6.yaml](../../.github/ipv6/kind-v6.yaml),
[kind-dual-v4.yaml](../../.github/ipv6/kind-dual-v4.yaml) and
[kind-dual-v6.yaml](../../.github/ipv6/kind-dual-v6.yaml).

## What `global.network` changes

Nothing below renders while `global.network` is empty.

- **Services** (5g-control-plane, bess-upf, omec-sub-provision): every Service
  gets `ipFamilyPolicy` and `ipFamilies` as given.
- **Pods**: every container with `POD_IP` (`status.podIP`, the primary family
  only) also gets `POD_IPS` (`status.podIPs`, every address, comma-separated).
- **SBI**: with IPv6 in `ipFamilies`, each network function's `sbi` section
  that does not set `bindingAddr` gets `bindingAddr: "::"`, which binds both
  families. `bindingIPv4` stays, as the key older images read. Each `sbi`
  section also gets `preferredFamily` (the family of the function's own URIs
  and of the peer addresses it picks) unless `cfgFiles` sets it. `registerIPv6`
  (the IPv6 address registered with the NRF) can be set next to
  `registerIPv4` in `cfgFiles`.
- **SMF**: `pfcp.preferredFamily` is set from `preferredFamily` unless
  `cfgFiles` sets it. It picks the N4 Node ID when `pfcp.addr` has both
  families, and the order UPF names resolve in. `pfcp.addr` also takes a
  list, `POD_IPS` for one dual-stack N4 socket, `pfcp.nodeId` sets the Node
  ID (IPv4, IPv6 or FQDN), and `upfTransportFamily` (a map of UPF hostname to
  `ipv4` or `ipv6`) the N3/N9 family per UPF; these stay `cfgFiles` keys.
- **UPF adapter**: `UPFADAPTER_PREFERRED_FAMILY` is set from
  `config.upfadapter.preferredFamily`, else from `preferredFamily`, and
  `UPFADAPTER_NODE_ID` from `config.upfadapter.nodeId` when it is set. It
  reads `POD_IPS` too.
- **MongoDB**: with IPv6 in `ipFamilies`, the `MongoDBCommunity` resource
  gets `additionalMongodConfig` `net.ipv6: true` and
  `net.bindIp: "::,0.0.0.0"`, so mongod serves both families. MongoDB's
  automation agent ignores `net.bindIpAll`
  ([mongodb/mongodb-kubernetes#1191](https://github.com/mongodb/mongodb-kubernetes/issues/1191)),
  and `::` alone is IPv6-only, which would shut out the IPv4 clients of a
  cluster whose primary family is IPv4: the operator's Service is
  single-stack, of that family. `mongodb.ipv6` overrides the choice and
  `mongodb.additionalMongodConfig` is merged on top.
- **UPF** (bess-upf, with IPv6 in `ipFamilies` or `config.upf.ipv6.enabled`):
  bessd serves gRPC on `[::]:10514`, so that the liveness probe reaches it on
  an IPv6 pod address. bess-init drops outgoing ICMPv6 port unreachable, as it
  does for IPv4. The CNI tuning plugin is chained in `access-net` and
  `core-net` to set `config.upf.ipv6.interfaceSysctls`, by default
  `accept_ra` 0 and IPv4 `forwarding` 0. `accept_ra` 0 stops a router
  advertisement on N3 or N6 from adding a default route through `core`, which
  would take N4 and DNS off `eth0`. `forwarding` 0 keeps the pod's kernel from
  forwarding what BESS already forwards in user space: with AF_PACKET the
  kernel sees every frame, and a forwarding kernel sends each downlink packet
  back out of `core`, where BESS tunnels it to the UE a second time. On an
  IPv6-only cluster the pod has no cluster IPv4 address, so the CNI does not
  turn IPv4 forwarding off as it does on IPv4 clusters, and the pod inherits
  the node's `net.ipv4.ip_forward` 1. The tuning plugin must be installed on
  the nodes; set `interfaceSysctls: {}` to leave it out.

## Values that take both families

These work in every mode, and nothing renders while they are unset:

- `externalIPs`, a list, next to each scalar `externalIp`: AMF and SCTPLB
  (`config.<nf>.ngapp`), NRF, PCF and AF (`config.<nf>`), and the UPF
  (`service`).
- bess-upf `config.upf.access` and `config.upf.core`: `ips` (addresses of
  either family, instead of `ip`) and `gateways.ipv4` / `gateways.ipv6` (next
  to `gateway`). `config.upf.ran.subnets` adds RAN subnets of either family.
  `config.upf.core.defaultRouteMetric` sets the metric of the default route
  through `core`: the IPv4 route keeps metric 110 unless set, and an IPv6
  route is added only when `defaultRouteMetric.ipv6` is set. Keep that metric
  above that of the pod's IPv6 default route on `eth0`, usually 1024.
- omec-sub-provision `ip-domains`: `ue-ipv6-pool`, `ue-ipv6-prefix-len`,
  `dns-primary-v6` and `pcscf-v6` are reserved for IPv6 PDU sessions. Today's
  simapp and webconsole ignore them.

## Limits

- The BESS datapath carries IPv4 only: N3 and N6 stay on IPv4.
- `bessctl http` (the `upf-http` Service's port 8000) listens on IPv4 only.
- The network functions need images that read `bindingAddr`, `registerIPv6`,
  `preferredFamily` and a `POD_IPS` list, and the SMF and UPF adapter images
  with IPv6 N4 support. Older images ignore these keys and variables and keep
  their IPv4 behaviour, except that an older SMF cannot parse
  `pfcp.addr: POD_IPS`.
