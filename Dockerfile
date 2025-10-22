FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    iproute2 iptables \
    libssl3 libunbound8 libunwind8 libjson-c5 libevent-2.1-7 libsystemd0 \
    procps \
  && rm -rf /var/lib/apt/lists/*

COPY ovs-libs/ /usr/lib/x86_64-linux-gnu/
RUN ldconfig || true

# Copy built packages from the build context
COPY pkgs/*.deb /tmp/pkgs/

RUN apt-get update \
  && dpkg -i /tmp/pkgs/*.deb || true \
  && apt-get -f install -y \
  && dpkg -i /tmp/pkgs/*.deb \
  && rm -rf /var/lib/apt/lists/* /tmp/pkgs

RUN install -d -m 0755 /var/lib/ovn /var/log/ovn /etc/ovn

CMD ["bash"]
