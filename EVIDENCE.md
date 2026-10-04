# Verification evidence

Development measurements were taken on Linux x86_64 with Zig 0.16.0, Quickshell 0.3.1 and Qt 6.11.2. They describe the tested workloads, not an operating-system memory limit or a guarantee for every machine. Reproduction commands and gates are in [verification](docs/VERIFICATION.md).

| Check | Observed result |
| --- | --- |
| Zig Debug unit tests | 20 passed |
| Debug integration cases | 13 passed |
| Closed-background synthetic backend soak | 1,000 jobs; at most 90 retained rows; one worker |
| Background backend memory | Peak RSS 8,312 KiB; warm median growth 184 KiB |
| Offscreen UI lifecycle | 1,000 measured open/close cycles; 1,204 views created and destroyed including preparation |
| Closed Quickshell memory added by UI | PSS 12,074 KiB; warm PSS growth 69 KiB; warm private memory remained stable |
| Default timer-disabled quiet interval | No measured UI/backend CPU ticks over 60 seconds |
| Live authorization | Three separate consent flows and returned account identities verified |
| Manual live fetches | Two completed jobs per tested account, with 30 bounded rows per job and profile routing checked |
| Live backend memory | Observed RSS range 15,772–20,208 KiB across separate runs |
| Public plugin namespace live check | Three isolated accounts; at most 90 retained rows; no closed-popup events or pending/active work after settlement; RSS 20,236 KiB |
| Live five-minute background refresh | Exactly 300 seconds between successful checks; 30 rows before and after; one worker and bounded pending work |
| Live background process/quiet interval | Peak RSS 19,944 KiB and 18 OS threads; no job, CPU ticks or closed-popup snapshot events during a subsequent 60-second quiet interval |
| Static musl x86_64 release checks | 20 Debug unit tests; 13 ReleaseSafe integration cases; 13 transport checks including credential-free HTTPS; loopback OAuth callback probe |
| Static musl release backend synthetic soak | 1,000 cycles with 90 rows; peak RSS 11,636 KiB; warm median growth 104 KiB; zero CPU ticks during 60 seconds idle |
| Static musl release offscreen UI soak | 1,000 measured cycles; all 1,204 views destroyed; added closed PSS 13,718 KiB; warm PSS growth −1,365 KiB; zero UI/backend CPU ticks during 60 seconds idle |

The UI harness exercised account isolation, generation rejection, bounded replacement, backend restart, unavailable/empty/error states and Loader destruction. Model tests additionally exercise arbitrary configured domains and single-account handshakes. Completed lifecycle measurements were offscreen.

RSS includes shared mappings in full. PSS apportions them among processes, so it is the UI comparison metric; private memory helps distinguish retained application memory from changes in shared mappings. The backend’s 16 MiB application-owned reservation is separate from its measured whole-process RSS. Browser, keyring and runtime allocations are outside that reservation.

Live tests verify the tested account/profile combinations. They do not establish universal Gmail browser routing, provider page ordering or a measured maximum for the complete browser-assisted authorization flow. Private raw receipts and real account details are intentionally excluded from the public repository.
