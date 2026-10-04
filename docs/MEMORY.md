# Memory footprint

The motivation for Omagma was a single Gmail tab observed using roughly **2 GB of RAM** on its author's desktop. That is an individual observation, not a universal Gmail requirement or a controlled comparison: Omagma shows a bounded recent-mail list and snippets, and opens the full Gmail application when needed.

## Current three-account measurement

On 2026-10-05, the installed **v0.1.1 / Zig 0.17.0** static-musl backend with three connected accounts and five-minute background refresh used **14,444 KiB PSS** (14,452 KiB RSS), stable across five samples. A separate full offscreen UI qualification with 90 rows attributed **15,514 KiB PSS** after 1,000 open/close cycles. Together:

| Component | Attributed PSS |
| --- | ---: |
| Running backend | 14,444 KiB |
| Warm, closed Omagma UI over Quickshell baseline | 15,514 KiB |
| Approximate Omagma total | **29,958 KiB: 29.3 MiB / 30.7 MB** |

The README rounds that total to **31 MB**. The installed executable is the actual downloaded x86_64 release, SHA-256 `36d6c76847b44dbc4e4aac8255af75901ee6b3d17e6c20e1259a7a00c6d37e75`. An independent read-only live test fetched 30 messages per account using existing grants and passed a 60-second manual-probe quiet interval. It measured 15,712 KiB backend PSS, illustrating variation between process lifetimes.

## Preserved historical measurement

On 2026-10-04, the installed static-musl **v0.1.0 / Zig 0.16.0** backend with three connected accounts used **12,184 KiB PSS** (12,192 KiB RSS). A separate synthetic UI lifecycle measurement with the production logo and 90 retained rows attributed **16,068 KiB PSS** to Omagma over the Quickshell baseline. Together these give an approximate Omagma footprint of **28,252 KiB: 27.6 MiB, or 28.9 MB**, roughly **30 MB**.

That estimate includes the backend and Omagma's share of the UI. It is not the added cost of a second or third account. Omagma shares Quickshell with the rest of the bar, so UI attribution uses a baseline rather than assigning the whole desktop shell to one plugin. Chrome, other bar plugins and temporary keyring helper processes are excluded. The popup was closed after warm lifecycle use; opening it creates a temporary view.

RSS counts shared pages in full; PSS apportions them among processes. Combining RSS from the whole shell with the backend would describe the shell and its other widgets too. The application-owned 16 MiB storage reservation is a separate allocation bound, not the measured total process memory.

The historical release remains at `851ee30c5953a28fe0535fea03737ce85ec745fd`. Private receipts are retained locally; only anonymized counts and memory totals are published. See [historical evidence](../EVIDENCE.md) and [reproduction and acceptance gates](VERIFICATION.md).

## Zig 0.17 qualification

The compiler port has separate [dated evidence](evidence/zig-0.17.0.md). Its native x86_64 Safe synthetic backend peak RSS was 11,624 KiB with 90 rows; the actual downloaded release's soak reached 11,636 KiB, the same peak as the historical 0.16 static release soak. Matched old/new UI diagnostics showed no compiler-linked increase. An earlier UI attribution gate failed and is preserved in the evidence: baseline initialization varies, so individual measurements are not guarantees.

The roughly 29 MB historical and 31 MB current live estimates come from different process lifetimes and UI baseline runs. They do not isolate the compiler's effect. Historical measurements remain attached to their actual version.
