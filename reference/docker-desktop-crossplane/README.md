# Docker Desktop Crossplane/OpenRMF preflight

This bundle reproduces the compact WSL2 + Docker Desktop validation used for
[`docs/tutorial-multipass-crossplane.md`](../../docs/tutorial-multipass-crossplane.md).
It is a developer preflight, not a replacement for the final two-Multipass-VM
test.

The preflight deliberately uses one Docker Desktop Kubernetes cluster as both
the Crossplane management cluster and the target cluster. It still uses a
kubeconfig Secret and the same secret-backed ProviderConfigs as the OK-101
Makefile, so it exercises the provider credential and `valuesFrom` paths.

## Tested versions

| Component | Version |
|---|---|
| Docker Desktop Kubernetes | `v1.32.2` |
| Crossplane | `2.3.3` |
| provider-kubernetes | `v0.14.1` |
| provider-helm | `v1.2.0` |
| Traefik chart | `40.2.0` |
| OpenRMF chart | `1.0.0` |
| podinfo | `6.7.1` |

The validation ran on an amd64 Docker Desktop node with 2 CPUs and about
4 GiB RAM. That allocation is useful for compatibility testing but can become
unresponsive while `rmf-sim` is busy. Use the web-only phase for browser
testing.

## Prerequisites

- Docker Desktop Kubernetes enabled.
- A `docker-desktop` kubectl context.
- Linux `amd64` Kubernetes node.
- Docker, kubectl, Helm, GNU Make, OpenSSL, and curl available in WSL.
- Outbound access to Helm repositories, GHCR, Quay, Docker Hub, GitHub release
  assets, and `xpkg.upbound.io`.

The targets modify the selected Kubernetes cluster. Use a disposable Docker
Desktop cluster without unrelated Crossplane or Traefik installations.

## Run the stable web profile

From this directory:

```bash
make setup
```

The target:

1. verifies Docker, the kubectl context, and amd64 nodes;
2. snapshots pre-existing CRDs for scoped cleanup;
3. installs pinned Crossplane and Traefik charts;
4. installs the provider versions used by the OK-101 Makefile;
5. creates a secret-backed ProviderConfig pointing back to Docker Desktop;
6. verifies provider-kubernetes and provider-helm with `podinfo`;
7. generates disposable passwords under `.state/`;
8. deploys the OpenRMF web profile through Crossplane;
9. retries Keycloak setup with a longer deadline when its JWT ConfigMap is
   still empty; and
10. checks the dashboard and API documentation through Traefik.

Generated files are mode `0600` and ignored by Git:

```text
.state/credentials.env
.state/rmf-values.yaml
.state/preexisting-crds.txt
```

Print the disposable dashboard and Keycloak administrator credentials:

```bash
make credentials
```

## Browser access

Add this entry to the Windows hosts file at
`C:\Windows\System32\drivers\etc\hosts`:

```text
127.0.0.1 rmf.test
```

Then open:

- `https://rmf.test/dashboard`
- `https://rmf.test/auth/admin/master/console/`
- `https://rmf.test/rmf/api/v1/docs`

Traefik uses its self-signed default certificate, so a browser warning is
expected.

## Exercise the simulation

After `make setup` succeeds:

```bash
make simulation
```

This switches `ENABLE_RMF_SIM` to `true`, updates the Crossplane values Secret,
forces reconciliation, and waits for Kubernetes to pull and start `rmf-sim`.

On a 2-CPU Docker Desktop node the simulation can starve Traefik probes and
cause intermittent browser connection resets. Return to the web-only profile:

```bash
make pause-simulation
```

For status and repeatable route checks:

```bash
make status
make verify-web
```

## Cleanup

Remove named releases, providers, namespaces, Secrets, Crossplane, and
Traefik:

```bash
make cleanup
```

To also remove Crossplane and Traefik CRDs that were absent from the snapshot
taken by `make check`:

```bash
make cleanup-all
```

`cleanup-all` refuses CRD cleanup when the pre-install snapshot is missing. An
empty snapshot is valid for a clean Docker Desktop cluster. Cleanup never
removes a CRD that was present in that snapshot. Local generated credentials
remain under `.state/`; remove that directory separately when it is no longer
needed.
