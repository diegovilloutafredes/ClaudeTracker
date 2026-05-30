# Contributing

Contributions are welcome — bug fixes, improvements, and new features.

## Getting started

```bash
brew install xcodegen
git clone https://github.com/diegovilloutafredes/ClaudeTracker.git
cd ClaudeTracker
make generate && open ClaudeTracker.xcodeproj
```

Requires macOS 14+, Xcode 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml` and is **not** committed — run `make generate` (or any `make build`/`run`, which do it for you) before opening it in Xcode. **Edit `project.yml`, never the generated `.xcodeproj`** — your project changes won't survive the next `make generate` otherwise. To add a source file, just create it under `ClaudeTracker/` and regenerate. The app has no runtime dependencies.

## Build cycle

macOS caches app binaries aggressively. The simplest path is `make run`, which regenerates the project, cleans, builds, installs to `/Applications/`, and launches. To run the clean cycle manually:

```bash
make generate   # regenerate ClaudeTracker.xcodeproj from project.yml
pkill -9 -f ClaudeTracker 2>/dev/null; sleep 1
rm -rf /Applications/ClaudeTracker.app
rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeTracker-*
xcodebuild -project ClaudeTracker.xcodeproj \
           -scheme ClaudeTracker \
           -configuration Debug \
           clean build
```

Then copy and launch:

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "ClaudeTracker.app" -not -path "*/Index.noindex/*" | head -1)
cp -R "$APP" /Applications/
open /Applications/ClaudeTracker.app
```

The `make release` command (see below) does the full build + package cycle. To install the resulting binary:

```bash
cd release/dist && bash install.command
```

## Cutting a release

```bash
make tag VERSION=1.2.0
```

This checks for a clean working directory, bumps `MARKETING_VERSION` in `project.yml`, commits the change, creates an annotated git tag, and pushes both the commit and the tag. The GitHub Actions release workflow triggers on the tag push and publishes a GitHub Release with the built zip attached.

Release notes are auto-generated from commit messages between tags. Write commit messages as complete sentences describing what changed and why — they become the release changelog.

## Future automation options

The current release process (manual `make tag`) is intentionally simple. If the project grows, consider:

- **[git-cliff](https://github.com/orhun/git-cliff)** — generates a `CHANGELOG.md` from conventional commit messages. Add `cliff.toml` at the repo root and run `git cliff --tag v1.x.0` before tagging to produce release notes.
- **[Conventional Commits](https://www.conventionalcommits.org)** — a commit message convention (`feat:`, `fix:`, `chore:`) that tools like git-cliff and semantic-release parse to determine version bumps automatically.
- **Automated version bump** — a GitHub Actions workflow on `main` that reads the latest tag, bumps the patch version, and opens a "Release v1.x.0" PR. Merge the PR to publish.

## Bundle ID note

The app's bundle identifier is `com.claudetracker.app`. UserDefaults keys and the Notification Center identifier are derived from this. If you fork the project and change the bundle ID, update the `UNUserNotificationCenter` category identifier in `UsageViewModel.swift` accordingly.

## Pull requests

1. Fork the repo and create a feature branch
2. Keep changes focused — one concern per PR
3. Test the full build cycle before opening the PR
4. Describe what changed and why in the PR description

## Reporting issues

Use the GitHub issue templates. Include:
- macOS version
- Whether you're on a Pro, Max, or Team plan
- Steps to reproduce
- Any relevant console output (run `Console.app`, filter by `ClaudeTracker`)
