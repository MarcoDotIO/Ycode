# Security policy

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through
[GitHub's security advisories](https://github.com/MarcoDotIO/Ycode/security/advisories/new).

Please include what you found, how to reproduce it, the version and platform, and the impact you expect. Leave out
secrets and personal data, and don't attach any Apple files.

This is a volunteer project, so response times are best effort. We aim to acknowledge a report within a week, tell you
what we plan to do, and credit you in the advisory if you want that.

## Supported versions

| Version | Supported |
|---|---|
| The latest 1.0.0 beta | Yes |
| Anything older | No: please update first |

## What is in scope

Everything in this repository and the published packages. These areas matter most:

- **Opening untrusted projects.** Parsers for project files, plists, asset catalogs and the like. A project can also run
  its own build scripts and package plug-ins when you build it, as with any IDE, so only build projects you trust.
- **The simulator host.** `ycode-simd` runs guest code in KVM micro-VMs. A guest that escapes to the host process is a
  vulnerability.
- **The simulator link.** Pairing and the encrypted connection between a viewer and a simulator host.
- **The coding assistant and `ycode mcp`.** Stored credentials, and anything that lets an agent write files or run
  commands without the approval it should need.
- **Packaging and CI.** Signing, the release workflow, and anything in the packages that shouldn't be there.

## What you should know

- **The Flatpak isn't really sandboxed.** It reaches the host's toolchain through `flatpak-spawn --host`, by design. A
  sandbox escape through that permission isn't a vulnerability; see [packaging/README.md](packaging/README.md).
- **Ad-hoc signed builds aren't notarized.** The release notes say which kind a build is, and each release has checksums.
- **Beta software.** The simulator in particular is experimental, so don't point it at untrusted apps on a machine you care
  about.
