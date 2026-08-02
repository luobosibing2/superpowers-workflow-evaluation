---
name: brainstorming
description: Use when a Plan-mode task needs product, architecture, or behavior design before an implementation plan can be made.
---

# Brainstorming

## Purpose

Turn an uncertain design problem into an explicit, approved direction. This is a
scoped Plan method, not a prerequisite for every task.

## Use When

- The user is in Plan mode and important product or technical choices remain open.
- A substantial behavior change has multiple plausible approaches.
- Success criteria, audience, constraints, or boundaries need clarification.

Do not use for ordinary conversation, code research, repository exploration,
mechanism explanations, status checks, or a small change whose intent is already
clear. Do not use it merely because implementation may happen later.

## Method

1. Inspect discoverable project context before asking the user for facts.
2. State the goal, audience, constraints, current state, and success criteria.
3. Identify only the decisions that materially change the design.
4. Offer two or three viable approaches when a real tradeoff exists. Lead with a
   recommendation and explain the cost of each alternative.
5. Resolve failure modes, compatibility, data flow, and testing expectations.
6. Present the resulting design at a level proportional to its risk.
7. Ask for approval only when a material design choice or high-risk behavior is
   still unsettled.

## Output

A decision-complete design that can feed a plan. Keep it in the conversation by
default. Write or commit a design document only when the user or repository
contract requires one.

Brainstorming never authorizes code changes, sub-agent delegation, worktree
creation, or any other execution action.
