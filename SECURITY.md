# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities **privately** through GitHub Security
Advisories:

**https://github.com/ocpp-debugkit/studio/security/advisories/new**

Do not open a public issue for security reports. We will acknowledge your report,
investigate, and coordinate a fix and disclosure with you.

## Supported versions

Studio is in early development (pre-`1.0`). Security fixes are applied to the
`main` branch and the latest release. There are no long-term-support branches
yet.

## Security principles

Studio is a debugging instrument that processes untrusted data. Its design holds
to a few principles:

- **Untrusted input.** Trace files, pasted content, live socket data, and CLI
  arguments are treated as untrusted: parsed safely, bounded in size and event
  count, and never allowed to exhaust memory or hang the UI.
- **Local-first.** Studio processes data on your machine. It has no accounts, no
  telemetry, and never uploads your traces.
- **Your data is yours.** User-loaded traces and the reports Studio generates
  contain your own data; the tool never silently alters or exfiltrates them.
- **Least privilege.** Network listeners, filesystem watches, and other native
  capabilities are opt-in and scoped to the task at hand.

## Scope

This policy covers the Studio application in this repository. The TypeScript
`@ocpp-debugkit/toolkit` is a separate project with its own security policy.
