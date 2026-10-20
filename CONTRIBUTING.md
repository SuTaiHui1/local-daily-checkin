# Contributing

Keep changes narrow and make the behavior reproducible with synthetic offline fixtures. Use `scripts/Test-Publish.ps1` before submitting a change.

Do not run real login, sharing or coin spending in CI. Do not add third-party signing, remote account execution, CAPTCHA bypass, retries after risk control, hidden social publication or paid actions. Preserve ordinary-user execution, current-day checks, duplicate prevention, the five-coin cumulative limit and failure pause behavior.

When adapting a new App version, record its official source, public compatibility checks, changed fields and remaining uncertainty. A static check, successful request status or process exit is not proof that a daily reward was credited.

Do not copy third-party source unless its redistribution license is established and notices are retained. In particular, no `NativeSigner.java`, APK/native binaries, shader data, session or App-derived runtime material belongs in this public bundle.

Use focused commits. Describe what changed, why, which offline tests passed, and which live behavior remains unverified. Provide public-safe examples rather than real account data.
