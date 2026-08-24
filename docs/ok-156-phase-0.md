# OK-156 Phase 0 — Preflight and resource decision

Status: completed on 2026-08-24 for the local installation preflight. Phase 1
functional acceptance subsequently passed with the bounded `qwen3:4b` profile;
see `docs/ok-156-phase-1.md`. Phase 2 remains blocked by unpublished OpenKubes
images.

## Environment

| Item | Observed value |
|---|---|
| Host architecture | `arm64` |
| `ok-mgmt-local` | Running, 4 CPU, 7.7 GiB RAM, 38.7 GiB disk |
| `ok-infra-local` | Running, 4 CPU, 7.7 GiB RAM, 38.7 GiB disk |
| K3s | `v1.35.5+k3s1`, both nodes Ready |
| Existing services | Ollama and Open WebUI on `ok-infra-local`; Crossplane on `ok-mgmt-local` |
| Existing model | Ollama `qwen2.5:0.5b` (397 MB) |
| `ok-local` revision | `9cc12481e5c0538c5839063bca2b0a89462dfcdc` |

The existing `ollama/` and `platform/` directories were untracked at this
revision. They were preserved; only the Ollama image/runtime values required by
the Phase 1 model envelope were changed.

## Required local tools

The following commands are available:

- Multipass `1.16.3+mac`
- kubectl `v1.36.3`
- Helm `v4.2.1`
- Docker `29.5.2`
- jq `1.7.1`
- Git `2.54.0`
- Python 3; OK-129 renderer tests additionally require PyYAML

PyYAML `6.0.2` was installed only in a temporary virtual environment for the
preflight tests. It has not been added as an undeclared host dependency.

## Pinned OK-129 source revisions

The compatible cross-repository pair is:

| Repository | Revision | Purpose |
|---|---|---|
| `openkubes/openkubes` | `6a0a56a4140dab3d55ade4a926c09412781e1407` | documentation, read-only agent, fixtures, access renderer |
| `openkubes/ok-cluster` | `03381d239454d8bb7aacc65908e8d3512ee376c1` | lifecycle Makefile, values template, cluster access helpers |

These revisions were produced together on 2026-08-18. The standalone assets
are not present on the current `openkubes/main`, so `main` must not be used as
an implicit replacement.

Preflight results:

- shared access renderer tests: PASS;
- release-candidate boundary checks: PASS;
- cluster access helper tests: 40 PASS, 0 FAIL.

## Pinned kagent components

| Component | Version | OCI digest/index digest |
|---|---|---|
| kagent CRD chart | `0.9.12` | `sha256:85174e69eab19e05fcf82dbfda86e8e84c2be97a52c645d60cf1ae51ccbca977` |
| kagent chart | `0.9.12` | `sha256:ec0dacc1a76edbd190a554757c8bdb193ccb0b35deeb35f6d7a7e7ffc76d99fd` |
| kagent tools chart | `0.2.1` | `sha256:a4bbb3f3b8e12ecb6f54689638acb9524bf110b9eade828225f9bbe190d5dcb7` |
| kagent tools image | `0.2.1` | `sha256:50b431281d3e32666f27a292962fd486aabaac157083a844d037c12137e353aa` |
| kmcp controller image | `0.3.0` | `sha256:86ab878da25a639358aad18933c6b99e06a7ac34a801dc17fd657db0f28cee28` |
| kagent controller image | `0.9.12` | `sha256:d1ea7b70bb8d97de9f0774d44b598971c944b3ab4e88294b0bb78e59d1a63c15` |
| kagent Go Agent image | `0.9.12` | `sha256:058ca9fc1a9ac994dde3354a7df56f5a6b93222572eda40ba295da2f0b6c101b` |
| PostgreSQL image | `18.3-alpine` | `sha256:54451ecb8ab38c24c3ec123f2fd501303a3a1856a5c66e98cecf2460d5e1e9d7` |
| kagent UI image | `0.9.12` | `sha256:1d5ada8d7f65a6b9ad28232463f9fd670c4c20875baa1c8008aaa1f1f988382e` |
| Ollama image | digest pinned | `sha256:9d30908e41144b1f1da89b9d8e33c07e4aeb43ff41a8660241b1686e2cc330ad` |

All rendered images publish a `linux/arm64` manifest.

## Resource envelope

The minimal OK-129 Helm profile renders 37 objects and requests:

| Component | CPU request | Memory request | CPU limit | Memory limit |
|---|---:|---:|---:|---:|
| kagent tools | 100m | 128 Mi | 1 | 512 Mi |
| kmcp controller | 10m | 64 Mi | 500m | 128 Mi |
| kagent controller | 100m | 128 Mi | 2 | 512 Mi |
| bundled PostgreSQL | 250m | 256 Mi | 500m | 512 Mi |
| kagent UI | 100m | 256 Mi | 1 | 1 Gi |
| **Total** | **560m** | **832 Mi** | **5** | **2.625 Gi** |

PostgreSQL requests a 500 Mi persistent volume. The read-only
`cluster-inspector` must explicitly use the Go runtime.

At preflight time `ok-infra-local` used about 2.1 GiB of 7.7 GiB RAM. The
minimal kagent profile fits alongside Ollama and Open WebUI for functional
testing. A 20B local model does not fit this envelope safely.

## Model strategy

`qwen2.5:0.5b` produced the correct structured tool call in three out of three
simple preflight requests. This proves basic function-call syntax only; it does
not prove reliable Kubernetes diagnosis.

The selected staged strategy is:

1. use the existing local `qwen2.5:0.5b` only for installation and wiring; its
   first live ImagePull diagnosis selected `deployment/default` instead of
   `deployment/imagepull` and therefore failed;
2. evaluate the 2.5 GB, tool-capable `qwen3:4b` as the local candidate that fits
   the current VM envelope;
3. do not use any model as final acceptance evidence without the three required
   diagnostic fixture runs;
4. prefer an existing internal Ollama endpoint with a previously validated
   model if the local candidate does not pass;
5. do not place `gpt-oss:20b` in this VM: its published model size is 14 GB and
   Ollama documents a 16 GB minimum-memory system envelope.

The Phase 1 result selected `qwen3:4b` with a 4096-token context, immediate
model unload between requests, targeted `describe` calls, and structured
resource fields for ambiguous fixture names.

## Phase 2 blockers

The following referenced public GHCR tags returned `manifest unknown` on
2026-08-24:

- `ghcr.io/openkubes/platform-diagnostics-mcp-adapter:0.2.0`;
- `ghcr.io/openkubes/platform-diagnostics-facade:0.1.8`.

Therefore Phase 2 must not start until the images are published and their
digests are recorded. This does not block the Phase 1 standalone path.

## Phase 1 entry decision

Phase 1 may proceed with these boundaries:

- read-only profile only;
- no write tool server or write agent;
- no Secret access;
- Go agent runtime explicitly configured;
- charts, images, and source revisions pinned as recorded above;
- local model acceptance and limitations recorded in the Phase 1 evidence.
