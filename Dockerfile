FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# Minimal runtime deps for OVN
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates iproute2 iptables \
    libssl3 libunbound8 libunwind8 libjson-c5 libevent-2.1-7 libsystemd0 \
    procps \
 && rm -rf /var/lib/apt/lists/*

# OVN packages produced by your CI
COPY pkgs/ /tmp/pkgs/

# Install OVN; first pass may fail due to deps, then fix and finalize
RUN apt-get update \
 && dpkg -i /tmp/pkgs/*.deb || true \
 && apt-get -f install -y \
 && dpkg -i /tmp/pkgs/*.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/pkgs

# Common runtime dirs
RUN install -d -m 0755 /var/lib/ovn /var/log/ovn /etc/ovn

CMD ["bash"]
