<!-- KRATE-README-HEADER:START -->
<p align="center">
  <a href="https://github.com/runkrate">
    <img src="https://raw.githubusercontent.com/runkrate/.github/main/assets/logo/logo.png" alt="KRATE" width="128" />
  </a>
</p>

<p align="center">
  <a href="https://github.com/runkrate/krate/stargazers"><img src="https://img.shields.io/github/stars/runkrate/krate?style=flat-square&logo=github" alt="GitHub stars" /></a>
  <a href="https://github.com/runkrate/krate/releases"><img src="https://img.shields.io/github/v/release/runkrate/krate?style=flat-square&label=version" alt="Current version" /></a>
  <a href="https://github.com/runkrate/krate/blob/main/LICENSE"><img src="https://img.shields.io/github/license/runkrate/krate?style=flat-square" alt="License" /></a>
</p>

<p align="center">
  <a href="https://runkrate.com"><img src="https://img.shields.io/badge/Website-runkrate.com-0A66C2?style=flat-square" alt="Website" /></a>
  <a href="https://runkrate.com/docs"><img src="https://img.shields.io/badge/Docs-runkrate.com%2Fdocs-111827?style=flat-square" alt="Docs" /></a>
  <a href="https://github.com/runkrate/hub/issues"><img src="https://img.shields.io/github/issues-search/runkrate/hub?query=is%3Aopen&style=flat-square&label=issues%2FPRs" alt="Open issues and pull requests" /></a>
</p>
<!-- KRATE-README-HEADER:END -->

# Official apps (core)

Catalog of **officially supported** KRATE applications — actively maintained by the KRATE team and shipped with the `krate` package.

**License:** see [LICENSE](LICENSE)

## Install KRATE

Do **not** clone this repository to install KRATE. Usable releases come only from [`runkrate/krate`](https://github.com/runkrate/krate).

Follow the install instructions in the [`runkrate/krate` README](https://github.com/runkrate/krate#install).

[Documentation](https://runkrate.com/docs) · [Releases](https://github.com/runkrate/krate/releases)

## This repository

This tree is the **published official apps catalog** used by the package and by `zen` / HarmonyUI. It is not an installer.

What “official” means here:

- Apps are **supported and maintained by KRATE** (install handlers, packaging, updates, and integration with the stack).
- Some apps are built or prepared by KRATE and published here as the public catalog entry.
- Others are **precompiled artifacts synchronized from a private source repository**; this public tree is the sync target users and the package consume — not a place to rebuild every app from scratch.

Day-to-day installs and updates on a host go through the `krate` package and `zen software …` (or HarmonyUI), not by cloning this repo.

## Core vs community

| | [`core`](https://github.com/krate-apps/core) (this repo) | [`community`](https://github.com/krate-apps/community) |
| --- | --- | --- |
| Support | Officially supported by KRATE | Community-contributed |
| Maintenance | Actively maintained by the KRATE team | Maintained by contributors; KRATE may ship the catalog but does not promise the same support level |
| Expectation | Preferred defaults for production hosts | Optional extras; quality and update cadence vary by app |

## Useful links

- [Documentation](https://runkrate.com/docs)
- [Report a bug or suggest a feature](https://github.com/runkrate/hub/issues)

## Contributing

To propose changes to official apps, open a pull request following the [contributing guide](https://github.com/runkrate/docs/blob/main/CONTRIBUTING.md). Bug reports and feature ideas go to [hub](https://github.com/runkrate/hub).
