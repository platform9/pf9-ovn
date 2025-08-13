FROM docker.io/openstackhelm/ovn:ubuntu_jammy

# Copy your patched binary to /usr/bin
COPY northd/ovn-northd /usr/bin/ovn-northd

# Ensure correct permissions
RUN chmod +x /usr/bin/ovn-northd

