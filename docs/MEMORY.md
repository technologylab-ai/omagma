# Memory footprint

The motivation for Omagma was a single Gmail tab observed using roughly **2 GB of RAM** on its author's desktop. That is an individual observation, not a universal Gmail requirement or a controlled comparison: Omagma shows a bounded recent-mail list and snippets, and opens the full Gmail application when needed.

## Three-account measurement

On 2026-10-04, the installed static-musl **v0.1.0 / Zig 0.16.0** backend with three connected accounts used **12,184 KiB PSS** (12,192 KiB RSS). A separate synthetic UI lifecycle measurement with the production logo and 90 retained rows attributed **16,068 KiB PSS** to Omagma over the Quickshell baseline. Together these give an approximate Omagma footprint of **28,252 KiB: 27.6 MiB, or 28.9 MB**, rounded to **30 MB** in the README.

That estimate includes the backend and Omagma's share of the UI. It is not the added cost of a second or third account. Omagma shares Quickshell with the rest of the bar, so UI attribution uses a baseline rather than assigning the whole desktop shell to one plugin. Chrome, other bar plugins and temporary keyring helper processes are excluded. The popup was closed after warm lifecycle use; opening it creates a temporary view.

RSS counts shared pages in full; PSS apportions them among processes. Combining RSS from the whole shell with the backend would describe the shell and its other widgets too. The application-owned 16 MiB storage reservation is a separate allocation bound, not the measured total process memory.

The historical release remains at `851ee30c5953a28fe0535fea03737ce85ec745fd`. Private receipts are retained locally; only anonymized counts and memory totals are published. See [historical evidence](../EVIDENCE.md) and [reproduction and acceptance gates](VERIFICATION.md).

## Zig 0.17 qualification

The compiler port has separate [dated evidence](evidence/zig-0.17.0.md). Its native x86_64 Safe synthetic backend peak RSS was 11,624 KiB with 90 rows. Final UI and installed-release totals are recorded after qualification; historical measurements are not relabeled as new-version results.
