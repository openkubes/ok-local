# OK-101 local environment runner

This directory contains the Makefile attached to Jira OK-101 and used by the
[OpenRMF Multipass and Crossplane tutorial](../../docs/tutorial-multipass-crossplane.md).
Keep it named `Makefile` and run it from this directory because its recursive
Make calls depend on that layout.

Use Homebrew's `gmake` for the individual targets. The runner uses modern GNU
Make's `.ONESHELL` behavior; the `make setup` wrapper bootstraps `gmake` but
then continues through Tutorials 3-4, which is outside the OpenRMF path.

For the OpenRMF path, run Tutorial 2 and the individual Crossplane targets:

```bash
gmake tutorial-2
gmake install-crossplane
gmake install-crossplane-providers
gmake crossplane-provider-configs
gmake crossplane-examples
```

Do not use `setup`, `tutorials`, `tutorial-3`, or `tutorial-4` for the
no-KubeVirt OpenRMF test. Those entry points install CAPI/CAPK with the
KubeVirt infrastructure provider.

The `clean` target calls the global `multipass purge` command. Follow the
tutorial's scoped cleanup when other deleted Multipass instances must remain
recoverable.
