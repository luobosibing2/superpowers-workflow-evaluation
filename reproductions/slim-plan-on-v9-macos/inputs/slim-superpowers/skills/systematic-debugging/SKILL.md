---
name: systematic-debugging
description: Use when a bug, failing test, regression, or unexpected runtime behavior requires root-cause investigation before a fix is proposed.
---

# Systematic Debugging

## Principle

Find the root cause before changing production behavior. A plausible patch is not
evidence that the failure is understood.

## Method

1. **Reproduce:** capture the smallest reliable reproduction, exact command,
   environment, and observed result. When practical, encode it as a failing test
   or minimal script before editing implementation code.
2. **Gather evidence:** read the complete error, inspect recent changes, compare a
   working path with the failing path, and trace inputs across component boundaries.
3. **Localize:** identify the first point where actual state diverges from expected
   state. Distinguish the originating defect from downstream symptoms.
4. **Hypothesize:** write one falsifiable root-cause hypothesis and the observation
   that would disprove it.
5. **Test one variable:** make the smallest diagnostic experiment. Do not combine
   unrelated fixes or refactors.
6. **Fix the cause:** implement the narrowest durable correction after the
   hypothesis is supported.
7. **Verify:** rerun the reproduction, relevant regression tests, and nearby tests
   that could expose collateral behavior.

## Escalation

After two unsupported hypotheses, pause and re-check assumptions, environment,
and boundaries. After three failed fixes, treat the design or component contract
as suspect rather than stacking another patch.

## Evidence Record

Report the reproduction, root cause, changed behavior, verification command, and
remaining uncertainty. If the failure cannot be reproduced, say so and avoid
claiming it is fixed.
