FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update && apt-get install -y -qq --no-install-recommends \
    ca-certificates \
    iproute2 iptables \
    libssl3 libunbound8 libunwind8 libjson-c5 libevent-2.1-7 libsystemd0 \
    procps curl \
  && rm -rf /var/lib/apt/lists/*

# Copy built packages from the build context
COPY pkgs/u24/*.deb /tmp/pkgs/

RUN apt-get update \
&& dpkg -i /tmp/pkgs/*.deb || true \
&& apt-get -f install -y \
&& dpkg -i /tmp/pkgs/*.deb \
&& rm -rf /var/lib/apt/lists/* /tmp/pkgs

# Debug symbols and perf, so `ovn-debugger perf-profile capture` names every function
# of this image's daemons and needs nothing installed at capture time (PCD-10646).
# The -dbgsym packages come from the same pf9-custom-ovn build as pkgs/u24, so their
# build IDs match these binaries; symbols from any other build would not fit. The
# build context must hold debug/u24-dbgsym/. It may be empty (PF9_DEBUG_SYMBOLS=false);
# then only perf and libc6-dbg are added. Only the packages for what runs in this
# image are installed: ovn-central (ovn-northd), ovn-common (libovn and the OVN
# tools) and openvswitch-common (ovsdb-server and the OVS tools). The packages are
# bind-mounted for this step, not copied: a COPY layer would keep all of them in the
# image (38 MB) after the step deletes them. The mount needs BuildKit (Docker 23 and
# later by default, or buildah).
# Plain POSIX sh, like the other RUN lines: a builder that ignores SHELL (buildah's
# OCI format) runs /bin/sh.
RUN --mount=type=bind,source=debug/u24-dbgsym,target=/tmp/dbgsym \
    apt-get update \
 && apt-get install -y -qq --no-install-recommends linux-tools-generic libc6-dbg \
 && for f in /tmp/dbgsym/ovn-central-dbgsym_*.ddeb /tmp/dbgsym/ovn-common-dbgsym_*.ddeb \
             /tmp/dbgsym/openvswitch-common-dbgsym_*.ddeb; do \
        if [ -e "$f" ]; then dpkg -i "$f" || exit 1; fi; \
    done \
 && rm -rf /var/lib/apt/lists/*

RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
  && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
 
COPY  ovn-kube-util /usr/bin/


RUN install -d -m 0755 /var/lib/ovn /var/log/ovn /etc/ovn

WORKDIR /root
ENTRYPOINT /root/ovnkube.sh
