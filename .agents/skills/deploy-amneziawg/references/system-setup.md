# System Setup — Docker, Firewall, Sysctls

Phase 2 details. All commands assume `RUN` = run on the target host (wrap in SSH if remote).

## Installing Docker

### Debian / Ubuntu / Raspbian

The official convenience script is the simplest path and the upstream-supported one:

```bash
curl -fsSL https://get.docker.com | sh

# Add user to docker group (avoids needing sudo for docker commands)
sudo usermod -aG docker $USER
# User must log out and back in for group membership to take effect.
# For the current session, the new shell can be entered via: newgrp docker
```

This installs Docker Engine + CLI + Compose v2 plugin in one go on all current Debian/Ubuntu releases.

### Fedora

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### RHEL / Rocky / Alma / CentOS Stream

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### Arch / Manjaro

```bash
sudo pacman -Syu --noconfirm docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### Alpine

```bash
sudo apk add --no-cache docker docker-cli-compose
sudo rc-update add docker default
sudo service docker start
sudo addgroup $USER docker
```

### openSUSE

```bash
sudo zypper install -y docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### Verifying

After install:

```bash
docker --version
docker compose version
docker run --rm hello-world  # exercises the daemon
```

If `docker run hello-world` fails with permission errors, the user hasn't re-logged in yet. Either tell them to log out and back in, or use `newgrp docker` for the current shell, or prepend `sudo` for the rest of this session.

## Persistent sysctls

The container's `sysctls:` block already applies what AmneziaWG needs *inside the container's network namespace*. The only one that genuinely needs to be set on the **host** is `net.ipv4.ip_forward=1` — it controls whether the host kernel routes packets between the container bridge and the public NIC. The others (`src_valid_mark`, `disable_ipv6`) only need to apply to the wg0 interface itself, which lives in the container's netns.

```bash
sudo tee /etc/sysctl.d/99-amneziawg.conf >/dev/null <<'EOF'
# Required for AmneziaWG container: route packets between container and uplink.
net.ipv4.ip_forward=1
EOF

sudo sysctl --system  # apply now
```

Verify:
```bash
sysctl net.ipv4.ip_forward
# net.ipv4.ip_forward = 1
```

> **Why only `ip_forward` on the host?** The container's compose file sets `src_valid_mark=1` and `disable_ipv6=0` via its own `sysctls:` block — those apply to the wg0 interface inside the container's netns, which is the only place they matter. A real-world deployment confirmed: `src_valid_mark=0` on the host with the container running healthy and routing traffic.
>
> If the user is already setting `src_valid_mark=1` on the host (e.g., from a previous bare-metal WireGuard setup), leaving it is harmless. Just don't *require* it.

If `ip_forward` was already enabled by another tool (Docker itself sets it on daemon start), the drop-in file is still useful — it makes the setting survive someone manually unsetting it or rebooting into a configuration that resets it.

## Firewall configuration

The VPN listens on UDP/`SERVERPORT` (default 51820). Open it in whichever firewall the host runs. Also configure NAT/masquerade for the VPN subnet if peers will route through the host (the default `ALLOWEDIPS=0.0.0.0/0` case).

### ufw (Debian/Ubuntu default)

```bash
sudo ufw allow ${SERVERPORT:-51820}/udp comment 'amneziawg'

# If user runs SSH on a non-default port and ufw is fresh: make sure SSH is allowed first!
# sudo ufw allow 22/tcp

# Enable if not already on (will prompt)
sudo ufw status || sudo ufw enable

# Masquerade for the VPN subnet (only if peers route through host):
# Edit /etc/ufw/before.rules — add at top, before *filter:
#   *nat
#   :POSTROUTING ACCEPT [0:0]
#   -A POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE
#   COMMIT
# Then: sudo ufw reload
```

**Important:** if the user's current SSH session is on the host (and they're running this skill on the box), don't enable ufw without first explicitly allowing SSH — you'll lock them out. Always confirm SSH is open before `ufw enable`.

### firewalld (Fedora / RHEL / Rocky / Alma default)

```bash
sudo firewall-cmd --permanent --add-port=${SERVERPORT:-51820}/udp
sudo firewall-cmd --permanent --add-masquerade
sudo firewall-cmd --reload
```

For per-zone configuration (e.g., only on the public zone):
```bash
sudo firewall-cmd --permanent --zone=public --add-port=${SERVERPORT:-51820}/udp
```

### nftables (modern Debian/Arch without ufw)

```bash
sudo nft add rule inet filter input udp dport ${SERVERPORT:-51820} accept
# Masquerade:
sudo nft add table ip nat
sudo nft add chain ip nat postrouting '{ type nat hook postrouting priority 100 ; }'
sudo nft add rule ip nat postrouting ip saddr 10.13.13.0/24 oifname "eth0" masquerade
```

To persist nftables changes, write to `/etc/nftables.conf` and `systemctl enable nftables`.

### iptables (legacy)

```bash
sudo iptables -A INPUT -p udp --dport ${SERVERPORT:-51820} -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE
# Persist with iptables-persistent (Debian) or netfilter-persistent or by saving to /etc/iptables/rules.v4
```

### Cloud provider security groups

ufw/firewalld on the VM is **not enough** for cloud VPS — the provider's network ACL/security group is in front. Common providers:

| Provider | Where |
|---|---|
| AWS EC2 | Security Groups → Inbound rules → Custom UDP, port 51820, source 0.0.0.0/0 |
| GCP | VPC → Firewall → Create rule, ingress, UDP/51820 |
| Hetzner Cloud | Firewalls → Inbound → UDP 51820 (or disable firewall entirely) |
| DigitalOcean | Networking → Firewalls → Inbound rules → UDP 51820 |
| OVH/Scaleway/Linode | Similar — check each provider's "firewall" or "security group" UI |

If the user mentions a cloud provider, **remind them to open the port at the provider level too**. Don't assume they'll do it.

## TUN device

```bash
# Ensure tun module is loaded and persistent
sudo modprobe tun
echo tun | sudo tee -a /etc/modules-load.d/modules.conf

# Verify
ls -l /dev/net/tun
# crw-rw-rw- 1 root root 10, 200 ... /dev/net/tun
```

On some minimal cloud images (e.g., LXC-based VPS like cheap "Container VPS" plans), `/dev/net/tun` may be absent or restricted by the host kernel. **This is a hard blocker** — the user can't run WireGuard-style VPNs on those plans. If `modprobe tun` fails with "Operation not permitted", explain that the VPS is running under LXC/OpenVZ without TUN/TAP support and they need to ask their provider to enable it or switch to a KVM/QEMU-based plan.
