# Changelog

All notable changes to FS25_SettingsHub will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Added
- Changelog file established (suite ruling 2026-08-22).
- Control Center core: `RfActionRegistry`, `RfLiveBinding`, `RfInputContextGuard`, `RfControlCenterInput`, and the `RF_OPEN_CONTROL_CENTER` summon key (default: Right Shift + A). Publishes `g_currentMission.rfActionRegistry` for companion delegates.
- Control Center dialog GUI (`RfKeybindActionDialog`): vanilla `fs25_dialog` chrome with live key chips and trigger buttons that run registered delegates.

## [1.0.1.0] - 2026-08-22

- First entry under changelog tracking.
