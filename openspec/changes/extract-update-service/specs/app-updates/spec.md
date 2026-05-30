## ADDED Requirements

This change formalizes the previously-unspecced in-app update capability. No behavior changes — these requirements document the contract that the `UpdateService` extraction preserves.

### Requirement: Automatic update checking against GitHub Releases

The system SHALL check the GitHub Releases API for a newer version than the running `CFBundleShortVersionString`, comparing versions numerically (so `1.10.0` > `1.9.0`). It SHALL check shortly after launch, after the Mac wakes from sleep, and on a recurring timer whose interval is derived adaptively from recent release cadence and clamped to the range [4 hours, 24 hours]. The recurring timer SHALL only run while auto-install is enabled.

#### Scenario: A newer release is published

- **WHEN** the latest GitHub release tag is numerically greater than the running version
- **THEN** the system SHALL expose it as an available update with its release URL and, when present, the `.zip` asset download URL

#### Scenario: No newer release

- **WHEN** the latest release tag is equal to or older than the running version
- **THEN** the system SHALL NOT surface an available update

#### Scenario: Adaptive interval from release cadence

- **WHEN** at least two recent releases are available with parseable `published_at` timestamps
- **THEN** the next-check interval SHALL be half the average gap between releases, clamped to [4h, 24h]
- **AND** when fewer than two timestamps are parseable the interval SHALL default to 12 hours

### Requirement: Manual update check

The system SHALL provide a "Check for Updates" action in Settings. The action SHALL be debounced so overlapping checks cannot run concurrently, showing a "Checking…" state while in flight.

#### Scenario: User checks manually

- **WHEN** the user taps "Check for Updates"
- **THEN** the system SHALL perform a check and, if a newer version exists, surface it in the Settings update row and the popover banner

### Requirement: One notification per discovered version

When a newer version is first discovered, the system SHALL notify the user at most once per version string, persisted across relaunches, so the same update never produces repeat toasts.

#### Scenario: Update discovered while auto-install is off

- **WHEN** a newer version is discovered and auto-install is disabled
- **AND** that version has not been notified before
- **THEN** the system SHALL show a single "Update available" toast and remember the version

#### Scenario: Same version rediscovered

- **WHEN** a subsequent check rediscovers the same version already notified
- **THEN** the system SHALL NOT show another toast

### Requirement: Optional automatic installation

The system SHALL provide an "Auto-install updates" toggle persisted under the UserDefaults key `"autoUpdate"`. When enabled and a downloadable `.zip` asset exists, discovering a new version SHALL trigger a countdown toast followed by download, in-place replacement of the app bundle in `/Applications`, and relaunch. When disabled, the user installs manually from the Settings/popover update affordance. Download and install progress SHALL be reflected through idle / downloading / installing / failed states.

#### Scenario: Auto-install enabled

- **WHEN** auto-install is on, a new version with a `.zip` asset is discovered for the first time
- **THEN** the system SHALL show a countdown toast and then download, install, and relaunch

#### Scenario: Install failure surfaces

- **WHEN** download or installation fails
- **THEN** the system SHALL enter a failed state exposing a fallback "Download" link to the release page
- **AND** SHALL NOT terminate the app without a successful install

#### Scenario: Toggle uses the green switch style

- **WHEN** the user views the Settings form
- **THEN** the "Auto-install updates" toggle SHALL render with `GreenSwitchStyle()`
