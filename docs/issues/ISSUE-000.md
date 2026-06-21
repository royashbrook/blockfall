# #0 — Baseline + issue tracking + commit hook

- **Area:** meta
- **Priority:** P0
- **Status:** done
- **Source:** playtest feedback (baseline round)

## Description
Tag the current solid build as `baseline`, add a local issue tracker under docs/issues/, and a commit-msg hook (.githooks/commit-msg) that rejects any commit whose message lacks an issue reference (#<n>).

## Acceptance
Hook installed via core.hooksPath; baseline tag created; all 24 playtest items filed.

## Notes
_(updates / PR refs go here)_
