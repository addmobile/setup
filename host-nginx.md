# Host nginx

The installer builds a pod whose nginx listens on **plain HTTP** and publishes one port to the host
(`MOBILEAPI_PORT`, default 8080). It cannot terminate TLS for you, given that the certificate lives
on the host machine.

The Raven and Raven Live clients do not accept plain HTTP in their code path, requiring HTTPS.
A host-level nginx configuration must forward requests to the `MOBILEAPI`; without one the app cannot 
connect at all.

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

## Reference vhost

Replace `raven.example.com` with your hostname and `8080` with your `MOBILEAPI_PORT`.

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

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
    http2 on;
    server_name raven.example.com;

    ssl_certificate     /etc/nginx/ssl/raven.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/raven.example.com/privkey.pem;

    # TLS 1.0/1.1 are refused by mobile clients
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # The device ingest endpoints accept up to 10 MB. nginx defaults to 1 MB, and a driver device
    # does NOT retry a rejected upload -- a 413 here loses that snapshot silently.
    client_max_body_size 10m;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_http_version 1.1;

        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # WebSocket: live map stops updating without these
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection $connection_upgrade;

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
curl -sI https://raven.example.com/version        # -> HTTP/2 200

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
```