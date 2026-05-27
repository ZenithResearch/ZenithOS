# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)

## [Unreleased]

### Added
- Added configurable Hub artifact mounts and Hub-served artifact fallback previews for typed case slot files — lets operators preview Hub runtime artifacts from mounted data directories first, then authenticated Hub content endpoints when no mount resolves.
- Established ZenithOS as a standalone repository under `~/repos` — separates the SwiftUI operator app from the vault workspace so it can have its own remote, CI, and review boundary.

### Changed
- Reframed the README as a searchable architecture orientation map — gives public readers and future contributors subsystem ownership, data-flow, credential, and verification boundaries before installation details.
- Hardened public-repo ignore rules for local secrets, virtualenvs, pycache, logs, sessions, and database artifacts — keeps generated/runtime state out of future commits.

### Fixed
- Marked Markdown WebKit callbacks as main-actor isolated — keeps the initial GitHub macOS CI build compatible with stricter Swift actor checking.
