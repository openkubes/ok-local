# GitOps wiring — registry-default (zot)

The root `kustomization.yaml` renders the pinned upstream zot chart with
`compositions/zot/values-local.yaml`. `argocd/application.yaml` wires that
composition from the `ok-local` repository into the registered
`ok-infra-local` workload cluster.

## Secret boundary

Credentials are deliberately not stored in Git. Before the first Argo CD sync,
create the local static-credential Secret with:

```bash
KUBECONFIG=../.tunnel-infra.kubeconfig make secret
```

The chart consumes the pre-existing `zot-htpasswd` Secret. The GitOps rendering
uses TCP health probes, so no clear-text probe password or base64-encoded basic
authentication header is committed. Phase 2 replaces this local secret boundary
with the platform Vault/OIDC integration.

## Render and bootstrap

Argo CD's Kustomize build options must include `--enable-helm`. Validate the
same rendering locally:

```bash
make gitops-render
```

Once Argo CD is installed on `ok-mgmt-local`, has `ok-infra-local` registered as
a destination cluster, and this change exists on `main`, bootstrap the app:

```bash
kubectl --kubeconfig ../.tunnel-mgmt.kubeconfig apply \
  -f gitops/argocd/application.yaml
```
