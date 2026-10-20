# Security and private data

Never submit credentials, phone sessions, signed URLs, raw API responses, QR keys, device identifiers, APKs or runtime caches in an Issue, pull request, release asset or CI secret.

Private state belongs outside the Git checkout. The modules restrict credential access to the current Windows user and SYSTEM. A public repository should contain only source, synthetic tests and documentation. The Actions workflow does not run account tasks.

If a credential was accidentally committed, deleting the working file is insufficient: revoke/renew it through the platform and remove it from all relevant Git history before publication. The publication check examines the index and reachable commits, but no pattern scanner can certify that arbitrary data is safe.

For a vulnerability, use the repository owner's private reporting channel if one is configured in GitHub. Otherwise open an Issue containing only a short, non-sensitive description and request a private contact method; do not post the exploit data publicly. This source package intentionally does not invent a maintainer email address.

Do not bypass verification, App permissions, account risk controls or OS approval. Keep pause markers until the actual issue is resolved. A task failure must not trigger automatic repeated submissions.
