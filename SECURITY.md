# Security Policy

## Supported versions

Security fixes are released for the latest minor version of the current major release.

| Version | Supported |
|---|---|
| latest `1.x` | ✅ |
| older | ❌ |

## Reporting a vulnerability

Please **do not** report security vulnerabilities in public issues, discussions or pull requests.

Report them privately through GitHub instead:
[**Report a vulnerability**](https://github.com/Dominik-esb/git-v2-azuredevops-proxy/security/advisories/new).

Please include:

- the affected version or image tag
- a description of the issue and its impact
- steps to reproduce, or a proof of concept

You can expect an acknowledgement within a few days. Once the issue is confirmed, a fix is
prepared in a private advisory and released, and you are credited in the advisory unless you
prefer otherwise.

## Scope

The proxy holds credentials for Azure DevOps (a PAT or an Entra access token) and can push on
their behalf. Issues that let someone read those credentials, bypass the proxy's authentication,
or push to a repository they should not reach are in scope and especially welcome.
