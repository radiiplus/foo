# Security Policy

## Supported versions

Security fixes are developed on the default branch and released for the current
minor series. Older minor series may not receive a patch.

| Version | Supported |
| --- | --- |
| `0.6.x` | Yes |
| Earlier versions | No |

## Report a vulnerability

Do not open a public issue for a suspected vulnerability. Submit a
[private security advisory](https://github.com/radiiplus/foo/security/advisories/new)
with:

- affected FOO version, operating system, backend, and target;
- a minimal reproduction or proof of concept;
- expected and observed behavior;
- realistic impact and required attacker access;
- any known workaround;
- whether the report or exploit has been shared elsewhere.

Remove credentials, signing keys, personal data, and unrelated proprietary code
from the report. If the private advisory form is unavailable, contact the
repository owner through the private contact method on their GitHub profile and
ask for a secure reporting channel.

Maintainers aim to acknowledge a complete report within seven days, validate
the impact, coordinate a fix and disclosure date, and credit the reporter when
requested. Complex or platform-specific reports may take longer. Please avoid
public disclosure until a fix is available or a disclosure date has been
agreed.

Compiler crashes without a security boundary impact, documentation mistakes,
and ordinary correctness bugs belong in the public issue tracker. Leaked keys
must be revoked with their provider immediately; deleting them from Git history
is not sufficient.
