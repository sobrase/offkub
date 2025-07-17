# sample_app role

This role deploys a minimal HTTP application using only local manifests so it works fully offline.
It creates a Deployment, Service and HTTPRoute to expose the pod through the Traefik gateway.

The container image and resource names can be customised in `defaults/main.yml`.
