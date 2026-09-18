# Changelog

All notable changes to FS25_SettingsHub will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

## [1.1.0.0] - 2026-09-18

### Added
- Control Center Settings tab (`RfSettingsDialog`): edit any registered module's settings directly, with per-type widgets (bool toggle, enum </>, int/float -/+), a fixed row pool with pagination, and a `[Settings]` footer button on the keybind dialog that swaps to it (and back via `[Keybinds]`). Admin-only rows are locked and greyed for non-admins in multiplayer via `SettingsHub:isLocalAdmin`; the server stays authoritative on apply.
- Inline keyboard rebinding on the Control Center: each keybind row gets a `[Rebind]` button that captures a new primary keyboard binding directly through the base game's own binding chain, with no server round trip (keybinds are client-local).
- New `[Reset Keys]` footer button restores only the suite actions listed in the dialog to their mod-declared defaults, with a confirmation dialog; every other game keybind is left untouched. Replaces the earlier `[Change Keys]` route.
- "Realistic Farming Suite is running" startup notification: a one-shot corner toast about 25 seconds after each save loads, naming the number of active suite mods.

### Changed
- `RfLiveBinding` now shows the primary keyboard binding's real chord instead of a flattened combination of every bound key.
- Hide/Show button captions and status strings on the Control Center now update live instead of lagging behind the actual toggle state.

### Fixed
- RSF-F201: cab and on-foot controls stay valid across vehicle entry and exit. Each input context now registers through its own private target, so the PLAYER and VEHICLE registrations no longer share one engine identifier that a cab rebuild wiped. Membership is checked in the wrap's own context, a complete set costs no registration work, and the input wrappers install once per session instead of being restored on every mission teardown. Added the F201 context-membership test (tools/test/lua) re-pointed at production.
- `[Reset Keys]` and `[Settings]` no longer collide on the same input (Reset Keys moved off `buttonActivate` onto `buttonMenuSwitch`).

## [1.0.1.0] - 2026-08-26

### Added
- Changelog file established (suite ruling 2026-08-22).
- Control Center core: `RfActionRegistry`, `RfLiveBinding`, `RfInputContextGuard`, `RfControlCenterInput`, and the `RF_OPEN_CONTROL_CENTER` summon key (default: Right Shift + A). Publishes `g_currentMission.rfActionRegistry` for companion delegates.
- Control Center dialog GUI (`RfKeybindActionDialog`): vanilla `fs25_dialog` chrome with live key chips and trigger buttons that run registered delegates.
- Fixed build script packing: the zip now includes `xml/`, so the Control Center dialog XML ships in the mod instead of being dropped at build time.
