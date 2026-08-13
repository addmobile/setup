# ADDMOBILE Server Setup Script

![ADDMOBILE_IMAGE](add_mobile.png)

## Installation 

Install: Run the following in bash
```
$ bash -c "$(curl -fsSL https://raw.githubusercontent.com/addmobile/setup/refs/heads/main/setup.sh)"
```

### You must put nginx in front of this

The pod listens on plain HTTP and publishes one port. RavenLive and the driver devices are
HTTPS-only, so a host-level nginx terminating TLS for your hostname is **required** -- installer
cannot do this for you.

See **[host-nginx.md](host-nginx.md)** for a reference vhost and the five settings that must be
right. Two of them (the WebSocket upgrade headers, and the upload size limit) fail silently if
wrong: the app appears to work while the live map never updates, or occasional drivers disappear
from the board with no error anywhere.

## Uninstall

This will stop and remove mobile-pod
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/addmobile/setup/refs/heads/main/clear.sh)"
```

## Optional

Set these in `~/.bashrc` (or `~/.cshrc`, `~/.zshrc`) so the installer does not have to
ask for them:
```
GATEWAY_URL=<your gateway url>
MOBILEAPI_PORT=<host port, default 8080>
```

To install a specific release instead of the newest published one, export the image
before running. `export` is required, not optional: on bare "assignment" the default
installation commands get the latest build instead of the release pinned.
```
export SERVICE2_IMAGE=hub.addsys.com:33443/add-mobileportal:v1.0.0.32
export MOBILESERVICES_IMAGE=hub.addsys.com:33443/mobileservices:v0.0.13
```

## What it installs

One podman pod (`mobile-pod`) with four containers: mongodb, mobileservices,
add-mobileportal and nginx. Only nginx is published on the host -- it is the
entrypoint and the auth gate for everything behind it.

A fifth container, kafka, is **off by default**, saving ~1GB of memory and disk
spent on retained events -- only created when `KAFKA_BROKERS` is set.

Health checks once it is up (replace 8080 with your port):
```
curl http://127.0.0.1:8080/health       nginx
curl http://127.0.0.1:8080/ms/health    auth verify
curl http://127.0.0.1:8080/amp/health   the API
```
