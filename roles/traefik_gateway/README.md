# traefik_gateway role

This role deploys Traefik Gateway in an air‑gapped Kubernetes cluster using manifests stored under `files/`.
It applies the Gateway API CRDs, RBAC rules, controller DaemonSet, `GatewayClass` and `Gateway` objects.

Air‑gapped support is achieved by referencing images from the local registry and copying all manifests to the node before applying them with `kubectl`.

## Files
- `standard-install.yaml` – Gateway API CRDs
- `traefik-controller.yaml` – Traefik DaemonSet using `hostNetwork` so that
  every node listens directly on ports 80 and 443
- `rbac.yaml` – permissions for the controller
- `gatewayclass.yaml` – default `GatewayClass`
- `gateway.yaml` – default `Gateway` with HTTP and HTTPS listeners
- `whoami.yaml` – optional dummy backend service
- `test-route.yaml` – optional `HTTPRoute` mapping to the whoami service

## Customization
Edit `gatewayclass.yaml` or `gateway.yaml` to adjust the controller name, listeners or TLS settings. These files are static and can be replaced with your own versions if different configuration is required.

Set `deploy_test_route: true` to automatically deploy the `whoami` service and associated `HTTPRoute` after the controller is running. Ensure the whoami image is present in your private registry if using an air‑gapped environment.
