# GitHub API Scripts

Standalone automation scripts for administering GitHub organizations and enterprises, including Copilot billing.

## Billing reports

**Billing product**:
A top-level GitHub billable offering in an enterprise's bill, such as Enterprise Cloud licenses, Advanced Security, Actions, or Copilot.
_Avoid_: Area, category, service

**SKU**:
One priced line item within a billing product, such as Linux runner minutes within Actions or Copilot Business seats within Copilot.
_Avoid_: Line, meter

**Active committer**:
A person who pushed a commit in the last 90 days to a repository with Advanced Security or Code Quality enabled; each one is billed one seat, counted once across the enterprise.
_Avoid_: Active user, contributor

**Reporting window**:
The span of calendar months a billing report covers: the most recent complete months. The current month is never included.
_Avoid_: Period, range

**Billing report**:
An HTML and PDF document showing enterprise cost per billing product across a reporting window, with charts of how each cost changed over time.
_Avoid_: Cost report, invoice

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
