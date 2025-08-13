/* SPDX-License-Identifier: Apache-2.0 */
/* Simple compatibility helpers to build OVN 22.03.x with OVS 2.17.x and 3.x */

#ifndef OVS_COMPAT_H
#define OVS_COMPAT_H

/* Pull OVS version macros if available. */
#include "openvswitch/version.h"
/* inet_parse_active() prototype lives here via stream.h->socket-util.h in OVN,
 * but some call sites include socket-util.h directly; include it to ensure
 * macro expansion compiles either way. */
#include "socket-util.h"

/* OVS 3.x adds an extra argument to inet_parse_active():
 *   bool inet_parse_active(const char *target, int default_port,
 *                          struct sockaddr_storage *ss, bool allow_dns,
 *                          const struct sockaddr_storage *bound_addr);
 * OVS 2.17.x has the 4-arg version (no bound_addr).
 */
#if defined(OVS_VERSION_MAJOR) && (OVS_VERSION_MAJOR >= 3)
#define PARSE_ACTIVE(target, default_port, ss, allow_dns) \
    inet_parse_active((target), (default_port), (ss), (allow_dns), NULL)
#else
#define PARSE_ACTIVE(target, default_port, ss, allow_dns) \
    inet_parse_active((target), (default_port), (ss), (allow_dns))
#endif

/*
 * ovsdb_idl_set_write_changed_only_all() exists in newer OVS (3.x) but not in
 * OVS 2.17.x. On old stacks, compile the call away so there’s no unresolved
 * symbol at link time.
 */
#if !defined(OVS_VERSION_MAJOR) || (OVS_VERSION_MAJOR < 3)
#ifndef ovsdb_idl_set_write_changed_only_all
#define ovsdb_idl_set_write_changed_only_all(IDL, CHANGED_ONLY) \
    ((void)(IDL), (void)(CHANGED_ONLY))
#endif
#endif

#endif /* OVS_COMPAT_H */
