# GitHub API Scripts

Standalone automation scripts for administering GitHub organizations and enterprises, including Copilot billing.

## Copilot budgets

**AI credit budget**:
A dollar-denominated monthly spending limit on Copilot AI credits, enforced by blocking further usage once reached.
_Avoid_: Quota, cap

**Universal budget**:
The AI credit budget that applies to every user in an enterprise unless overridden.
_Avoid_: Default budget, global budget

**User budget**:
An AI credit budget set for one individual user that overrides the universal budget for that user.
_Avoid_: Override, personal budget

**Effective budget**:
The AI credit budget that currently applies to a user, whether universal or user-specific.
_Avoid_: Current limit

**Budget increase**:
Raising a user's effective budget by a dollar amount, or to an absolute dollar amount.
_Avoid_: Top-up, bump
