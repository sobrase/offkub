# sample_app role

This role deploys a minimal Python HTTP server using local manifests so it works fully offline.
It creates a ConfigMap with an `index.html`, a Deployment running `python -m http.server`, a Service and an HTTPRoute to expose the pod through the Traefik gateway.

The container image, content and resource names can be customised in `defaults/main.yml`.
