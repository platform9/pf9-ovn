FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    iproute2 iptables \
    libssl3 libunbound8 libunwind8 libjson-c5 libevent-2.1-7 libsystemd0 \
    procps \
  && rm -rf /var/lib/apt/lists/*

# Copy built packages from the build context
COPY ../pkgs/*.deb /tmp/pkgs/

RUN apt-get update \
&& dpkg -i /tmp/pkgs/*.deb || true \
&& apt-get -f install -y \
&& dpkg -i /tmp/pkgs/*.deb \
&& rm -rf /var/lib/apt/lists/* /tmp/pkgs


RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
  && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl


RUN mkdir -p /usr/libexec/cni/
COPY ovnkube ovn-kube-util ovndbchecker ovnkube-identity ovnkube-observ /usr/bin/
COPY ovn-k8s-cni-overlay /usr/libexec/cni/ovn-k8s-cni-overlay

# ovnkube.sh is the entry point. This script examines environment
# variables to direct operation and configure ovn
COPY ovnkube.sh /root/
COPY ovndb-raft-functions.sh /root/
# override the pkg's ovn_k8s.conf with this local copy
COPY ovn_k8s.conf /etc/openvswitch/ovn_k8s.conf


# iptables wrappers
COPY ./iptables-scripts/iptables /usr/sbin/
COPY ./iptables-scripts/iptables-save /usr/sbin/
COPY ./iptables-scripts/iptables-restore /usr/sbin/
COPY ./iptables-scripts/ip6tables /usr/sbin/
COPY ./iptables-scripts/ip6tables-save /usr/sbin/
COPY ./iptables-scripts/ip6tables-restore /usr/sbin/


RUN install -d -m 0755 /var/lib/ovn /var/log/ovn /etc/ovn

WORKDIR /root
ENTRYPOINT /root/ovnkube.sh
