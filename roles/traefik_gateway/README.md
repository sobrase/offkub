# traefik_gateway role

This role deploys Traefik Gateway in an air‑gapped Kubernetes cluster using a Helm chart rendered to YAML.
The `fetch_offline_assets.sh` helper downloads the chart and generates `traefik.yaml` with `helm template` so Helm is not required on the target hosts.  The template command now includes CRDs to avoid additional downloads when deploying.
The role applies the Gateway API CRDs and then the rendered manifest which includes RBAC rules, the controller and the default `GatewayClass` and `Gateway` objects. The dashboard IngressRoute is disabled to keep the deployment minimal.
`fetch_offline_assets.sh` also strips the `maxSurge` field from the DaemonSet update strategy because Kubernetes forbids setting `maxSurge` when `maxUnavailable` is non-zero.

## Files
- `standard-install.yaml` – Gateway API CRDs
- `traefik.yaml` – manifest rendered from the Helm chart
- `values.yaml` – values used during templating
- `whoami.yaml` – optional dummy backend service
- `test-route.yaml` – optional `HTTPRoute` mapping to the whoami service

## Customization
Adjust `values.yaml` if you need different settings before rendering the chart with `scripts/fetch_offline_assets.sh`.

Set `deploy_test_route: true` to automatically deploy the `whoami` service and
associated `HTTPRoute` after the controller is running. The
`scripts/fetch_offline_assets.sh` helper downloads this image so it can be
loaded into the local registry during `setup_registry`.
