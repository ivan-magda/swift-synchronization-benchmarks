# Final documentation fix

## Changes

- Updated the README Simulator test instructions to run the general suite while skipping `CreationCostTests`, then run that suite separately with parallel testing disabled.
- Explained that creation-cost tests measure process-wide allocations and need isolation.

## Validation

- `git diff --check` passed.
- Confirmed the documented commands include project, scheme, destination, skip/only-testing, and disabled parallel testing flags.
- No builds, test suites, or devices were run, as requested.

## Commit

- `Document isolated creation-cost test runs`
