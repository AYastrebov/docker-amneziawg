# Dockerfile for amneziawg-go and amneziawg-tools

# ---- Builder Stage ----
# This stage compiles a static amneziawg-go binary.
FROM golang:1.24.4-alpine AS builder

# Install build dependencies for cgo (build-base) and git
RUN apk add --no-cache git build-base

# Clone the amneziawg-go repository
WORKDIR /src
RUN git clone https://github.com/amnezia-vpn/amneziawg-go.git .

# Build a static binary, enabling cgo for static linking.
RUN CGO_ENABLED=1 go build -ldflags '-linkmode external -extldflags "-fno-PIC -static"' -v -o amneziawg-go

# ---- Runtime Stage ----
# This stage creates the final image using pre-compiled tools.
# Using alpine:3.19 to match the pre-compiled tools version.
FROM alpine:3.19

# Define the release version of amneziawg-tools to download
ARG AWGTOOLS_RELEASE="1.0.20250706"

# Install runtime dependencies and tools for downloading
RUN apk --no-cache add iproute2 iptables bash wget unzip openresolv

# Download and install pre-compiled amneziawg-tools
RUN cd /usr/bin/ && \
    wget https://github.com/amnezia-vpn/amneziawg-tools/releases/download/v${AWGTOOLS_RELEASE}/alpine-3.19-amneziawg-tools.zip && \
    unzip -j alpine-3.19-amneziawg-tools.zip && \
    rm alpine-3.19-amneziawg-tools.zip && \
    chmod +x /usr/bin/awg /usr/bin/awg-quick && \
    # Add symbolic links for compatibility with standard wg commands
    ln -s /usr/bin/awg /usr/bin/wg && \
    ln -s /usr/bin/awg-quick /usr/bin/wg-quick && \
    sed -i 's|\[\[ $proto == -4 \]\] && cmd sysctl -q net\.ipv4\.conf\.all\.src_valid_mark=1|[[ $proto == -4 ]] \&\& [[ $(sysctl -n net.ipv4.conf.all.src_valid_mark) != 1 ]] \&\& cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1|' /usr/bin/wg-quick

# Copy the compiled amneziawg-go binary from the builder stage
COPY --from=builder /src/amneziawg-go /usr/bin/

# Create a directory for WireGuard configurations
RUN mkdir -p /etc/wireguard

# Copy the entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# The default command is to show usage, but you'll override this
CMD ["--help"]
