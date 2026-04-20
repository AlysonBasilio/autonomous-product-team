# Autonomous Product Team

This document specifies how an autonomous product team should work.

## Definitions

### Team

The team which will be responsible for handling a product.

### Team Manager

The persona that is responsible for managing team members and delegates tasks.

### Team Member

The persona that executes tasks.

### Tasks

The definition of how to do a specific activity to reach a specific goal.

## Premises

1. Each team has one team manager.
2. The team works on **one issue at a time** — the highest-priority unblocked issue. Multiple team members may work in parallel only on independent tasks within that single issue (e.g. backend and frontend simultaneously). No two team members ever work on different issues concurrently.
3. Team managers do not execute tasks. They always delegate tasks to team members.
4. Each task has its own completion status, tracked as structured comments on the PM issue — separate from the issue's overall lifecycle status (In Progress, Done, Blocked).
5. Tasks must be idempotent. Before starting work, the plan task checks PM issue comment history to determine which tasks have already been completed and routes only to what is still needed.
6. Every task posts a structured completion comment to the PM issue when it finishes. These comments are the authoritative record for re-entry after a restart or re-execution.