# Background refresh

`refreshIntervalSeconds` is optional and defaults to `0`. It accepts a JSON integer of `0` or `60..86400` seconds. Set it to `300` for five-minute automatic refresh.

With `0`, opening or selecting an account can refresh never-checked or aged data; explicit refresh requires an open dropdown. Closing cancels outstanding work and restores the previous state without creating a cancellation error. An untouched account returns to never-checked if its first refresh was canceled.

With a positive interval, the daemon schedules enabled, connected accounts once at startup and then at each interval, including while the dropdown is closed. Disabled and disconnected accounts are skipped, and retry backoff is respected. Closing lets active work finish and does not schedule an extra refresh. Explicit refresh still requires an open dropdown.

One worker serializes network jobs, with one pending flag per account. A monotonic deadline schedules each interval; missed deadlines do not accumulate catch-up jobs. Background results replace the bounded account cache. Closed popups receive no snapshot events; reopening obtains the current cached results. The owner closing its IPC pipe cancels and joins the worker in either mode.

Changing the configuration takes effect when the backend restarts. Background access requires a valid refresh token and usable keyring. It can fail independently for each account. Cached data and the last-checked time remain visible after a failed refresh.

A synthetic 1,000-job closed-popup soak and a real 300-second interval check passed. The live check observed no work or CPU ticks in a separate 60-second quiet interval between refreshes. This does not mean an enabled timer will remain idle across its refresh deadline. See [measured evidence](../EVIDENCE.md).
