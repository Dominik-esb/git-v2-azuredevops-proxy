# Contributing

Thanks for your interest in improving git-v2-azuredevops-proxy! Bug reports, feature ideas,
documentation fixes and pull requests are all welcome.

## Reporting issues

- **Bugs and feature requests:** open an [issue](https://github.com/Dominik-esb/git-v2-azuredevops-proxy/issues/new/choose) using one of the templates.
- **Security vulnerabilities:** do **not** open a public issue — see [SECURITY.md](SECURITY.md).

## Development

The proxy is a shell entrypoint ([`start.sh`](start.sh)) around nginx, fcgiwrap and
`git-http-backend`, packaged as a Docker image.

```bash
# Build the image
docker build -t git-proxy:test .

# Run the end-to-end smoke test (needs Docker and git; no Azure DevOps account required)
tests/smoke.sh git-proxy:test
```

The smoke test runs the image against a local bare repository standing in for Azure DevOps and
checks authentication, protocol v2 clones over HTTP and HTTPS, push forwarding and the
background sync.

CI also runs these linters; running them locally before you push saves a round trip:

| Tool | Checks |
|---|---|
| [shellcheck](https://www.shellcheck.net/) | `start.sh`, `tests/*.sh` |
| [hadolint](https://github.com/hadolint/hadolint) | `Dockerfile` |
| [actionlint](https://github.com/rhysd/actionlint) | `.github/workflows/` |
| [kubeconform](https://github.com/yannh/kubeconform) | every rendered kustomize overlay in `k8s/` |

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep each pull request focused on one change, and update the README or `docs/` when behaviour changes.
3. **Sign off every commit** ([Developer Certificate of Origin](https://developercertificate.org/)):
   `git commit -s`. The DCO check blocks unsigned commits.
4. Give the pull request a descriptive title, e.g. `feat: add Entra client secret support` or
   `fix: refresh token before forwarding a push`.
5. A maintainer adds one of these labels; it decides where the change appears in the release notes:

   | Label | Use for |
   |---|---|
   | `breaking-change` | Anything that requires users to change their setup |
   | `enhancement` | New features and improvements |
   | `bug` | Bug fixes |
   | `security` | Security fixes and hardening |
   | `documentation` | Documentation only |
   | `dependencies` | Dependency and base image updates |
   | `ci` | CI and repository tooling |
   | `chore` | Maintenance, excluded from release notes |

`main` is protected: changes land through pull requests once all required checks pass.

## Releases (maintainers)

Pull requests and pushes to `main` only build and test the image; nothing is published. To
release, tag `main` with a [semantic version](https://semver.org/):

```bash
git tag v1.2.3
git push origin v1.2.3
```

The [Release workflow](.github/workflows/release.yml) runs the smoke test, pushes `1.2.3`, `1.2`,
`1` and `latest` to [Docker Hub](https://hub.docker.com/r/dominikesb/git-v2-azuredevops-proxy)
(multi-arch, with SBOM and provenance) and creates a GitHub Release whose notes are grouped by
the labels above. Bump the major version for anything labelled `breaking-change`.
