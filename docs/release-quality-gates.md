# Evidence required for a 9/10 release

A passing build is necessary, not sufficient. Do not declare these gates passed
without recording the tested commit, platform, scenario, and observed outcome.

## Automated regression gates

- TypeScript, API build, Expo diagnostics, dependency audit, and web export pass.
- Core and UI tests pass their repository-wide coverage thresholds. Do not narrow
  coverage includes to raise the percentage. Reports use separate directories.
- Onboarding covers invalid credentials, duplicate submissions, API failure and
  retry, verification delivery failure, and invite redemption recovery.
- Optional device feedback cannot block navigation or turn successful writes into
  reported failures, including when the native promise never settles.
- Database integration tests run against a disposable database with production
  migrations. Mocked unit tests are not a substitute for this gate.

## Required real-device and browser journeys (not yet signed off)

| Journey | Evidence to collect |
| --- | --- |
| Invitation → signup → verification → team | Email received, retry works after a connection drop, correct role and venue |
| Clock in → break → clock out | iPhone and Android GPS permission refusal/recovery, geofence edge, duplicate tap, server record agrees |
| Reservation → seat → clear table | Host and manager permissions, concurrent changes, no duplicate seating |
| Subscription purchase → restore | Store sandbox receipt, entitlement refresh, cancellation/expiry behavior |
| Offline → reconnect → app resume | Honest error/loading UI, safe retries, no duplicate mutations or stale identity |
| Accessibility | VoiceOver/TalkBack labels and focus, large text, keyboard navigation, reduced motion |

## Release sign-off

- Current-commit API/Mobile CI is green; cloud security scans complete and findings
  are reviewed rather than treating report generation as proof of compliance.
- Run staging smoke tests without creating test users, charges, or records in
  production. Verify error monitoring and the previous-version rollback path.
- Observe representative venue operators completing their first shift workflow;
  record confusing steps and failed tasks before adding more features.

Native store builds, device journeys, disposable-database integration, and operator
usability evidence remain separate from local test coverage. A subjective rating
must not replace release sign-off.
