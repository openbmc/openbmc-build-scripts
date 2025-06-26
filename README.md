# openbmc-build-scripts

Build script for CI jobs in Jenkins.

## Linter policy and related build failures

Formatting linters sometimes change stylistic output across
releases. Separately, [some linters are not version-pinned in the CI
container][no-pin-policy], as pinning would drive either frequent maintenance
with upgrades or stagnation of the code-base against older versions.

The combination may result in inconsistent formatting opinions across CI worker
nodes[^1].

If you see such behaviour consider [changing the
thing](https://github.com/openbmc/openbmc-build-scripts/commit/a1cbd4041f94193e1
c43e767156c8a2dd117b99d) to force a container refresh.

[no-pin-policy]:
  https://discord.com/channels/775381525260664832/867820390406422538/1387500393243869265

[^1]: The collection of container builds across all worker nodes may not hold a
consistent set of tool versions despite being built from the same specification:
The inconsistencies emerge from the cadence of upstream tool package updates
beating against the cadence of container rebuilds on the worker nodes.
