# Libvirtex Core

`libvirtex_core` is the dependency-free contract layer for the Libvirtex
umbrella. It defines domain structs, VM lifecycle validation, a classified
error taxonomy, and provider behaviours for IPAM and CoreDNS records.

It deliberately contains no database, network transport, libvirt, or provider
implementation. Those belong to the control-plane, scheduler, and adapter
applications that use these contracts.

