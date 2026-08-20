# Host nginx

The installer builds a pod whose nginx listens on **plain HTTP** and publishes one port to the
host (`MOBILEAPI_PORT`, default 8080, bound to `127.0.0.1`). It cannot terminate TLS for you,
given that the certificate lives on the host machine.

The Raven and Raven Live clients do not accept plain HTTP in their code path, requiring HTTPS.

Its job is narrow: **terminate TLS and proxy to the pod.** Everything else (authentication, the
database scoping, etc). happens inside the pod.

---

## What the pod expects in front of it

```
client (https / wss)
  -> host nginx  :443            <- terminates TLS, this document
     -> 127.0.0.1:MOBILEAPI_PORT <- the pod's nginx, plain HTTP
        -> auth gate, API, auth service, mongo, kafka   (all pod-internal)
```

---

## Let the installer write it

`setup.sh` already knows the port, and drops a generator next to the rest of the install.

```bash
sudo ~/ADD_MOBILE/conf/host-nginx.sh \
     --server-name raven.example.com \
     --port 8080 \
     --cert /etc/nginx/ssl/raven.example.com/fullchain.pem \
     --key  /etc/nginx/ssl/raven.example.com/privkey.pem
```

It works out whether this host uses the Debian layout (`sites-available` + `sites-enabled`) or the
RHEL one (`conf.d`), writes the vhost and the shared WebSocket map, keeps a timestamped backup of
anything it replaces, runs `nginx -t`, and **only then** reloads. If nginx refuses the config,
every file it touched is put back and nothing is reloaded.

Straight from the URL, if you are setting up the host before or without the pod:

```bash
curl -fsSL https://raw.githubusercontent.com/addmobile/setup/refs/heads/main/host-nginx.sh \
  | sudo bash -s -- --server-name raven.example.com --port 8080 \
         --cert <fullchain.pem> --key <privkey.pem>
```

Other modes:

| Flag | What it does |
|---|---|
| `--print` | writes both files to stdout and stops. No root needed. |
| `--render --out-dir <dir>` | writes both files into a directory to review. No root needed. |
| `--upstream <host>` | the pod is published somewhere other than `127.0.0.1` |
| `--max-body <size>` | override `client_max_body_size` (default `10m`) |
| `--no-redirect` | skip the port 80 -> 443 redirect server |
| `NGINX_DIR=/path` | nginx lives somewhere other than `/etc/nginx` |

After installing it prints four checks: the pod answers behind the proxy, TLS terminates,
unauthenticated requests come back 401, and the WebSocket upgrade is proxied.

---

## WebSocket upgrade map

**`conf.d/raven-upgrade.conf`**

```nginx
map $http_upgrade $raven_connection_upgrade {
    default upgrade;
    ''      close;
}
```

## **`<server-name>.conf`** vhost. 

**`<server-name>.conf`** 

| Setting | Why |
|---|---|
| `client_max_body_size 10m` | nginx defaults to 1 MB. Snapshots over that are refused **at your edge** with a 413 and never reach the pod, which is configured for 10 MB. A driver device does not retry a rejected upload, so the snapshot is gone with nothing in any log to say so. |
| `Upgrade` / `Connection` headers | the app looks healthy and the live map never updates |
| `proxy_read_timeout` / `proxy_send_timeout` | sockets are dropped at the 60s default |
| `proxy_http_version 1.1` | the upgrade cannot be negotiated at all |
| `return 308` on the :80 server | a 301/302 turns a device's snapshot POST into a bodyless GET, losing the payload behind a 2xx |

The first two fail **silently**: nothing errors, the system just misbehaves in a way that looks
like an app bug.

---

## Reference vhost

Only needed if you are writing it by hand rather than using the generator. This is what
`--print` produces; `--print` is the authoritative version, and this copy can drift.

Replace `raven.example.com` with your hostname and `8080` with your `MOBILEAPI_PORT`. Note that
the WebSocket map is **not** in this file -- see above.

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name raven.example.com;

    # 308 preserves the method and body. A 301/302 would turn a device's
    # snapshot POST into a bodyless GET and the payload would be lost behind a 2xx.
    return 308 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name raven.example.com;

    ssl_certificate     /etc/nginx/ssl/raven.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/raven.example.com/privkey.pem;

    # TLS 1.0/1.1 are refused by mobile clients
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 10m;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_http_version 1.1;

        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection $raven_connection_upgrade;

        # Sockets are long-lived -- 60s default would drop them.
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_buffering    off;

        # The pod overwrites these itself on every gated path, so this is not required,
        # but costs nothing and means a client-supplied identity header can never reach
        # the application even if the pod config regresses.
        proxy_set_header   RAVEN-USER      "";
        proxy_set_header   RAVEN-DATABASES "";
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/raven.example.com.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

## Verify

From the host, after reloading nginx:

```bash
# Pod's gate is being proxied to (not the app directly)
curl -s http://127.0.0.1:8080/health              # -> NGINX OK!

# TLS terminates and the chain is complete
curl -sI https://raven.example.com/version        # -> HTTP/1.1 200

# Unauthenticated requests are refused , not by host nginx config
curl -s -o /dev/null -w '%{http_code}\n' \
     -X POST -H 'Content-Type: application/json' \
     -d '{"query":"{__typename}"}' \
     https://raven.example.com/api/graphql        # -> 401

# WebSocket upgrade is proxied (401 is the PASS here, not 400/426)
curl -s -o /dev/null -w '%{http_code}\n' \
     -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
     -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
     'https://raven.example.com/socket.io/?EIO=4&transport=websocket'        # -> 401

curl -s -o /dev/null -w '%{http_code}\n' \
     -X POST -H 'Content-Type: application/json' \
     --data-binary @<(head -c 2000000 /dev/zero | tr '\0' 'a' | sed 's/^/{"pad":"/;s/$/"}/') \
     https://raven.example.com/devices/probe/snapshot     # -> anything but 413
```