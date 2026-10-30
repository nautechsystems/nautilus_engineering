# Security Policy

Use this policy to report security issues in Nautilus Engineering. Nautech Systems values reports that help
protect its open-source projects. NautilusTrader maintains its own security policy. Where a repository has
its own policy, that policy takes precedence.

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

**Keep reports private**: Do not report a security vulnerability in a public issue.

Use [GitHub Security Advisories](https://github.com/nautechsystems/nautilus_engineering/security/advisories/new)
for private disclosure and coordination. You can also email <security@nautechsystems.io>. You may request the
Nautech Systems PGP key for sensitive email reports.

Include this information:

- Vulnerability description.
- Reproduction steps.
- Affected revisions or artifacts.
- Expected impact.
- Suggested fix, if available.

## Response targets

Nautech Systems commits to these response targets:

- An initial response within 48 hours.
- A status update within 7 days with the initial assessment.
- A fix within 30 days for critical vulnerabilities and within 90 days for other confirmed vulnerabilities.
- Coordination of a public disclosure date with the reporter.

## Responsible disclosure

When you investigate or report a vulnerability:

- Limit testing to what is necessary to demonstrate the issue.
- Do not access unauthorized data or disrupt systems.
- Do not disclose the vulnerability publicly before a fix is available.
- Comply with applicable laws.

Nautech Systems credits reporters in security advisories unless they prefer to remain anonymous.

## Supported revisions

Only the latest revision on `main` is supported. Consumer repositories pin exact commits and must review and
adopt security fixes explicitly. A change here never updates a consumer automatically.

## Bug bounty

Nautech Systems does not operate a formal bug bounty program. We appreciate responsible reports and
recognize contributors where appropriate.
