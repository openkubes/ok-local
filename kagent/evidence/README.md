# Acceptance evidence

`dashboard-2026-08-24/` contains the sanitized Phase 1 Dashboard acceptance
record. The three case files retain the user prompt, exact tool call, selected
non-sensitive Kubernetes evidence, final answer, usage metadata, duration, and
a hash of the full local session response. `summary.json` is the compact case
index. `resource-probe.json` contains the independent grounded probe and
five-second CPU/memory samples.

The exporter deliberately excludes unfiltered controller/tool logs, Secrets,
tokens, credentials, and cluster IP addresses. The full session history remains
in the local kagent PostgreSQL database after the final reinstall.
