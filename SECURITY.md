# Security Policy

Nautech Systems values reports that help protect its open-source projects. Use this policy for
security issues in Nautilus Engineering. NautilusTrader maintains its own security policy, and a
repository-specific policy takes precedence where one exists.

## Scope

This policy covers:

- Shared standards, configurations, scripts, and pre-commit definitions maintained in this
  repository.
- The sync, update, validation, and recovery behavior provided by this repository.
- Repository automation and CI configuration maintained here.

Report a consumer-specific issue to the affected consumer repository when it does not originate in
a shared artifact. Report vulnerabilities in third-party tools to their maintainers unless the
Nautilus Engineering integration creates the exposure.

## Report a vulnerability

Do not report a security vulnerability in a public issue.

Use [GitHub Security Advisories](https://github.com/nautechsystems/nautilus_engineering/security/advisories/new)
for private disclosure and coordination. Alternatively, email <security@nautechsystems.io>. You may
request the Nautech Systems PGP key for sensitive email reports.

Include the vulnerability description, reproduction steps, affected revisions or artifacts,
expected impact, and a suggested fix when available.

## Response targets

Nautech Systems commits to:

- An initial response within 48 hours.
- A status update within 7 days with the initial assessment.
- A fix for critical vulnerabilities within 30 days and other confirmed vulnerabilities within 90
  days.
- Coordinating a public disclosure date with the reporter.

## Responsible disclosure

When investigating or reporting a vulnerability:

- Limit testing to what is necessary to demonstrate the issue.
- Do not access unauthorized data or disrupt systems.
- Do not disclose the vulnerability publicly before a fix is available.
- Comply with applicable laws.

Nautech Systems credits reporters in security advisories unless they prefer to remain anonymous.

## Supported revisions

Only the latest revision on `main` is supported. Consumer repositories pin exact commits and must
review and adopt security fixes explicitly; a change here never updates a consumer automatically.

## Bug bounty

Nautech Systems does not operate a formal bug bounty program. We appreciate responsible reports and
recognize contributors where appropriate.
