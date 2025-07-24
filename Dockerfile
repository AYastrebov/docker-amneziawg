# syntax=docker/dockerfile:1
# Use the specified base image from LinuxServer.io
FROM ghcr.io/linuxserver/baseimage-ubuntu:noble

# Set build arguments for versioning and build date
ARG BUILD_DATE
ARG VERSION="latest" # Default to 'latest' if not provided
ARG AMNEZIAWG_RELEASE # Placeholder for a specific AmneziaWG release if needed

# Set labels for image metadata, following LinuxServer's convention
LABEL build_version="Linuxserver.io version:- ${VERSION} Build-date:- ${BUILD_DATE}"
LABEL maintainer="AYAstrebov"

# Set environment variables for non-interactive apt operations
# This prevents prompts during package installation.
ENV DEBIAN_FRONTEND=noninteractive

# Step 1: (Optional) Upgrade system - Generally skipped in Dockerfiles
# Upgrading the kernel and requiring a reboot is not standard practice for Docker image builds.
# The base image is expected to be up-to-date enough for most use cases within a container.

# Step 3: Install pre-requisites
# Install necessary packages for adding PPAs and potentially for kernel module compilation.
# - software-properties-common: Provides add-apt-repository.
# - python3-launchpadlib: Dependency for add-apt-repository.
# - gnupg2: For managing GPG keys used by APT.
# - linux-headers-generic: Provides generic Linux kernel headers. While `uname -r`
#   would give the host kernel, `linux-headers-generic` is typically sufficient
#   for installing kernel modules from PPAs on standard Ubuntu base images,
#   as the AmneziaWG package should be built against common Ubuntu kernels.
# Note: apt-get update is now performed here for the first time in the build process.
RUN apt-get update && \
    apt-get install -y \
    software-properties-common \
    python3-launchpadlib \
    gnupg2 \
    linux-headers-generic \
    # Add iptables and iproute2 which are commonly needed for VPNs
    iptables \
    iproute2 && \
    # Clean up apt cache to reduce image size. This is crucial for efficient Docker images.
    rm -rf /var/lib/apt/lists/*

# Step 4: Add the Amnezia PPA (Personal Package Archive)
# This command adds the official Amnezia PPA to your system's APT sources,
# allowing you to install packages provided by Amnezia.
# After adding the PPA, update the package lists again to include the new packages.
RUN add-apt-repository ppa:amnezia/ppa && \
    apt-get update

# Step 5: Install AmneziaWG
# Finally, install the AmneziaWG package from the newly added PPA.
# This package should handle the installation of the kernel module and any other
# necessary components.
RUN apt-get install -y amneziawg && \
    # Add 'amneziawg' to /etc/modules to ensure the kernel module loads at boot
    echo "amneziawg" >> /etc/modules && \
    # Clean up apt cache one more time after the final installation.
    rm -rf /var/lib/apt/lists/*

# LinuxServer.io often uses a /config volume for persistent data.
# AmneziaWG, being a WireGuard fork, likely uses /etc/wireguard or /etc/amneziawg
# for its configuration files. We'll symlink /etc/amnezia/amneziawg to /config/amneziawg
# to allow external volume mounting for configurations.
# This assumes AmneziaWG uses /etc/amnezia/amneziawg for its config.
RUN mkdir -p /config/amneziawg && \
    mkdir -p /etc/amnezia && \
    rm -rf /etc/amnezia/amneziawg && \
    ln -s /config/amneziawg /etc/amnezia/amneziawg

# Implement iptables-legacy symlinking and awg-quick modification from LinuxServer's WireGuard
# This helps ensure compatibility with awg-quick in the container environment.
RUN cd /usr/sbin && \
    for i in "" "-save" "-restore"; do \
        rm -f iptables${i} ip6tables${i} && \
        ln -s iptables-legacy${i} iptables${i} && \
        ln -s ip6tables-legacy${i} ip6tables${i}; \
    done && \
    # Modify awg-quick to prevent issues with sysctl src_valid_mark
    sed -i 's|\[\[ $proto == -4 \]\] && cmd sysctl -q net\.ipv4\.conf\.all\.src_valid_mark=1|[[ $proto == -4 ]] \&\& [[ $(sysctl -n net.ipv4.conf.all.src_valid_mark) != 1 ]] \&\& cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1|' /usr/bin/awg-quick && \
    # Create /build_version file for image metadata
    printf "Linuxserver.io version: ${VERSION}\nBuild-date: ${BUILD_DATE}" > /build_version && \
    # General cleanup of temporary files
    rm -rf /tmp/*

# Add custom branding for LinuxServer.io base images
# This will display "AmneziaWG" in the container's startup banner.
COPY branding.txt /etc/s6-overlay/s6-rc.d/init-adduser/branding

# Create the service directory for s6-overlay and copy the run script
# This script will be executed by s6-overlay to start the AmneziaWG service.
RUN mkdir -p /etc/services.d/amneziawg

# Copy the amneziawg run script into the s6-overlay services directory.
# This file needs to be created in the same directory as your Dockerfile.
COPY amneziawg.run /etc/services.d/amneziawg/run
# Set executable permissions for the run script
RUN chmod +x /etc/services.d/amneziawg/run

# Copy the initialization script and set executable permissions
COPY init-amneziawg.sh /usr/bin/init-amneziawg.sh
RUN chmod +x /usr/bin/init-amneziawg.sh

# Expose the default WireGuard port (UDP 51820)
# AmneziaWG, being based on WireGuard, is highly likely to use the same default port.
EXPOSE 51820/udp

# The CMD instruction is removed as s6-overlay will manage the service startup.
# Optional: You might want to add a HEALTHCHECK if your application
# inside the container will rely on the AmneziaWG module being loaded.
# For example, checking for the existence of the /dev/net/tun device:
# HEALTHCHECK --interval=5m --timeout=3s \
#   CMD test -f /dev/net/tun || exit 1
