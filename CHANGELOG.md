# Changelog

All notable changes to FS25_SettingsHub will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Fixed
- RSF-F201: cab and on-foot controls stay valid across vehicle entry and exit. Each input context now registers through its own private target, so the PLAYER and VEHICLE registrations no longer share one engine identifier that a cab rebuild wiped. Membership is checked in the wrap's own context, a complete set costs no registration work, and the input wrappers install once per session instead of being restored on every mission teardown. Added the F201 context-membership test (tools/test/lua) re-pointed at production.

## [1.0.1.0] - 2026-08-26

### Added
- Changelog file established (suite ruling 2026-08-22).
- Control Center core: `RfActionRegistry`, `RfLiveBinding`, `RfInputContextGuard`, `RfControlCenterInput`, and the `RF_OPEN_CONTROL_CENTER` summon key (default: Right Shift + A). Publishes `g_currentMission.rfActionRegistry` for companion delegates.
- Control Center dialog GUI (`RfKeybindActionDialog`): vanilla `fs25_dialog` chrome with live key chips and trigger buttons that run registered delegates.
- Fixed build script packing: the zip now includes `xml/`, so the Control Center dialog XML ships in the mod instead of being dropped at build time.
