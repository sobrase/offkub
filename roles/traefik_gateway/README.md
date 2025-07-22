# traefik_gateway role

This role deploys Traefik Gateway in an air‑gapped Kubernetes cluster using a Helm chart rendered to YAML.
The `fetch_offline_assets.sh` helper downloads the Traefik chart and renders `traefik.yaml` with `helm template` so Helm is not required on the target hosts. It also pulls the companion `traefik-crds` chart and concatenates its CRD files into `traefik-crds.yaml`.
The role applies the Gateway API CRDs and these Traefik CRDs before deploying the rendered manifest which includes RBAC rules, the controller and the default `GatewayClass` and `Gateway` objects. The dashboard IngressRoute is disabled to keep the deployment minimal.
During the deployment the role generates a self-signed certificate and stores it in a `traefik-cert` Secret so the HTTPS listener of the Gateway is configured entirely offline.
`fetch_offline_assets.sh` also strips the `maxSurge` field from the DaemonSet update strategy because Kubernetes forbids setting `maxSurge` when `maxUnavailable` is non-zero.

## Files
- `standard-install.yaml` – Gateway API CRDs
- `traefik-crds.yaml` – Traefik CustomResourceDefinitions
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
