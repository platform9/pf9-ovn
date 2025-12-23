FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    iproute2 iptables \
    libssl3 libunbound8 libunwind8 libjson-c5 libevent-2.1-7 libsystemd0 \
    procps curl \
  && rm -rf /var/lib/apt/lists/*

# Copy built packages from the build context
COPY pkgs/u22/*.deb /tmp/pkgs/

RUN apt-get update \
&& dpkg -i /tmp/pkgs/*.deb || true \
&& apt-get -f install -y \
&& dpkg -i /tmp/pkgs/*.deb \
&& rm -rf /var/lib/apt/lists/* /tmp/pkgs

RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
  && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
 
COPY  ovn-kube-util /usr/bin/


RUN install -d -m 0755 /var/lib/ovn /var/log/ovn /etc/ovn

WORKDIR /root
ENTRYPOINT /root/ovnkube.sh
