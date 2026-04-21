# frp-gateway

One-command setup for publishing local HTTP services to public subdomains via [frp](https://github.com/fatedier/frp).

```
[Client Machine]                    [Public Server]                [Internet]
 local:3000 ←─ frpc ──TLS tunnel──→ frps:2001 ──→ vhost:2002 ←─── Reverse Proxy ←── *.example.com
```

## Server Setup

On a server with a public IP:

```bash
# Deploy frps-gateway
sudo bash frps-gateway-install.sh example.com

# Custom ports
sudo bash frps-gateway-install.sh example.com 7000 7080
```

The script will:
1. Download frp and install `frps` to `/usr/local/bin/frps-gateway`
2. Generate a random auth token (UUID)
3. Create config at `/etc/frps-gateway/frps.toml`
4. Start systemd service `frps-gateway`

### Post-setup

1. **DNS**: Point `*.example.com` to your server IP
2. **Reverse proxy**: Forward `*.example.com` HTTP traffic to the vhost port (default `127.0.0.1:2002`)

Caddy example:
```caddyfile
*.example.com {
    reverse_proxy 127.0.0.1:2002 {
        header_up Host {host}
    }
}
```

### Security

- vhost HTTP port binds to `127.0.0.1` only (not exposed to public)
- TLS is enforced on the frps↔frpc control channel
- Token-based authentication

## Client Setup

On any machine where you want to expose a local port:

```bash
# Publish local port 3000 as myapp.example.com
sudo bash frpc-gateway-install.sh <server_ip> <port> <token> example.com myapp 3000

# Add more services (won't affect existing ones)
sudo bash frpc-gateway-install.sh <server_ip> <port> <token> example.com another-app 8080
```

### Management

```bash
# List all registered proxies
bash frpc-gateway-install.sh --list

# Remove a single proxy
sudo bash frpc-gateway-install.sh --remove myapp

# Uninstall everything
sudo bash frpc-gateway-install.sh --uninstall-all
```

## How It Works

- **Server**: Single `frps-gateway` systemd service
- **Client**: Each proxy runs as an independent systemd instance via template unit `frpc-gateway@<name>.service`
- Configs stored in `/etc/frpc-gateway/<name>.toml`
- Binary shared at `/usr/local/bin/frpc-gateway`

## Uninstall

```bash
# Server
sudo bash frps-gateway-install.sh --uninstall

# Client
sudo bash frpc-gateway-install.sh --uninstall-all
```
