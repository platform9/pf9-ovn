FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Base runtime deps commonly needed by OVN binaries
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    iproute2 iptables \
    libssl3 libunbound8 libunwind8 libjson-c5 libevent-2.1-7 libsystemd0 \
    procps \
  && rm -rf /var/lib/apt/lists/*

# Copy your built packages in
COPY ../*.deb /tmp/pkgs/

# Install your packages.
# dpkg first (may fail on unsatisfied deps), then resolve with apt-get -f install,
# then re-run dpkg to ensure all .debs are installed.
RUN apt-get update \
  && dpkg -i /tmp/pkgs/*.deb || true \
  && apt-get -f install -y \
  && dpkg -i /tmp/pkgs/*.deb \
  && rm -rf /var/lib/apt/lists/* /tmp/pkgs

RUN install -d -o root -g root -m 0755 /var/lib/ovn /var/log/ovn /etc/ovn

CMD ["bash"]
