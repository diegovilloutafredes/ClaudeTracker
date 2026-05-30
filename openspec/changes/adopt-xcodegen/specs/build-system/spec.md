## ADDED Requirements

### Requirement: Xcode project is generated from project.yml

The Xcode project SHALL be generated from `project.yml` via XcodeGen and SHALL NOT be committed to version control. `project.yml` is the single source of truth for targets, build settings, and schemes.

#### Scenario: Fresh checkout builds

- **WHEN** a contributor checks out the repo (which has no `ClaudeTracker.xcodeproj`) and runs `make build`, `make test`, or `make run`
- **THEN** the project SHALL be generated first (the `generate` Make target is a prerequisite)
- **AND** the build SHALL proceed against the freshly generated project

#### Scenario: Generated project is ignored

- **WHEN** `make generate` produces `ClaudeTracker.xcodeproj`
- **THEN** git SHALL ignore it (`.gitignore` entry), so it never appears in `git status` or diffs

### Requirement: Generated build is equivalent to the previous hand-written project

Generating the project SHALL NOT change build output. The resolved build settings for every target and configuration, and the resulting app bundle's `Info.plist`, SHALL match the previous hand-written project.

#### Scenario: Build settings unchanged

- **WHEN** `xcodebuild -showBuildSettings` is compared for the app and test targets across Debug and Release
- **THEN** the generated project SHALL produce identical settings to the previous `project.pbxproj`

#### Scenario: Info.plist preserved

- **WHEN** the app is built from the generated project
- **THEN** the bundled `Info.plist` SHALL retain `LSUIElement` (no dock icon), `SUFeedURL`, and `CFBundleShortVersionString` matching `MARKETING_VERSION`

### Requirement: CI generates the project explicitly

The release workflow SHALL install XcodeGen explicitly (not assume it is present on the runner) and generate the project before building.

#### Scenario: Release workflow runs

- **WHEN** the release workflow runs on a tag push
- **THEN** it SHALL install `xcodegen` and run `make generate` before lint/build/sign/notarize
- **AND** the existing signing, notarization, and packaging steps SHALL be unchanged

### Requirement: Version bump edits project.yml

`make tag VERSION=x.y.z` SHALL update `MARKETING_VERSION` in `project.yml` (not the generated pbxproj) and commit `project.yml`.

#### Scenario: Cutting a release

- **WHEN** the maintainer runs `make tag VERSION=1.20.0`
- **THEN** `project.yml`'s `MARKETING_VERSION` SHALL become `1.20.0`
- **AND** `project.yml` SHALL be committed and tagged `v1.20.0`
