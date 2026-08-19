# maintainers

| github | role | owns |
| --- | --- | --- |
| [@okanck](https://github.com/okanck) | code maintainer | architecture, api contracts, data model, security, infrastructure, code quality, issue creation, review, release sequencing, and every merge |
| [@olyacivelek](https://github.com/olyacivelek) | product owner | user scope, ux, visual direction, and user-facing turkish copy |

the two roles decide different things and neither substitutes for the other. a
change to user-visible behavior, copy, or visual output needs product owner
approval; a technical decision does not. product owner approval is never implied
by an implementation, a passing test suite, a draft pull request, a technical
review, or an agent. see [`GOVERNANCE.md`](GOVERNANCE.md).

## contact

do not use these addresses for support questions or feature requests; see
[`SUPPORT.md`](SUPPORT.md) for where those go.

- security reports: `security@tekir.istanbul` — private, see [`SECURITY.md`](SECURITY.md)
- code of conduct reports: `security@tekir.istanbul`
- privacy: `privacy@tekir.istanbul`
- anything else: `hello@tekir.istanbul`

## code ownership

[`.github/CODEOWNERS`](.github/CODEOWNERS) is the machine-readable form of the
table above: the repository defaults to the code maintainer, and the product
contract and design references are owned by the product owner. if the roles
change, both files change together.
