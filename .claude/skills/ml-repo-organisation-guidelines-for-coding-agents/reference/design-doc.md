# Design Doc Standard

The repository maintains a design doc in `README.md`. Its purpose is to explain **how the system or a proposed change will be implemented**. Write it from a technical perspective, as a tech lead would write it for the engineers who will build it.

A reviewer should be able to understand and evaluate the proposed implementation without first reading the entire codebase.

## Contents

- What the design doc is for, and what it is not
- When to update it
- Length
- Required sections, with guidance for each

## What it is for

Focus on:

- How the system works.
- How the proposed change will be implemented.
- Which components will change.
- How data and control flow through the system.
- Which interfaces, APIs, models, pipelines, or dependencies are involved.
- What technical constraints and trade-offs affect the implementation.
- How the implementation will be evaluated.
- How the change affects existing components.

**Focus more on how than why.** Include technical reasoning where it affects the implementation, but the document primarily explains the design.

**What it is not.** It is not a product requirements document and not a project-management document. Do not spend space on business justification, task assignments, project status, or generic statements about impact.

It is also **not a changelog**. Do not record small implementation changes here. Those go in `ChangeLog.md`.

The design doc must stay consistent with the actual implementation. It must not describe an outdated architecture.

## When to update it

Update before implementing a significant architectural change, and whenever:

- The implementation differs materially from the existing design doc.
- A new major component, pipeline, API, model, database, or dependency is introduced.
- An important interface or data flow changes.
- A significant technical decision changes the proposed design.
- The evaluation methodology or system-level behaviour changes substantially.

Small bug fixes, minor refactoring, formatting changes, and changes that do not affect the overall design do not require an update.

## Length

Generally 500 to 1000 words. The goal is not to reach a word count. Include enough technical detail for an engineer to understand and evaluate the implementation, and prefer concrete technical detail over general explanation.

## Sections

### Context and Scope

Briefly explain the existing system and the specific technical problem being addressed. Clearly define which part of the system is affected.

### Goals

Describe the technical outcomes the change should achieve. Make goals specific and measurable where possible.

### Non-Goals

State what the design does not attempt to address. This prevents scope from expanding during implementation.

### Overview

Explain the proposed implementation at a high level. Describe the main components and how they interact.

### Architecture Diagrams

Use diagrams when they improve understanding of components, data flow, dependencies, APIs, or infrastructure. Diagrams should show the technical structure relevant to the change.

### Evaluation: Measure What Matters

Define how the implementation will be evaluated. Use metrics that directly measure the intended outcome, such as accuracy, latency, throughput, memory usage, cost, reliability, or test coverage. State the evaluation conditions.

### How It Impacts Other Systems

Describe changes to upstream and downstream components. Explain which APIs, databases, pipelines, services, models, or interfaces are affected.

### Structure of Changes

Describe how the implementation will be organised in the repository. Reference specific modules, files, classes, functions, tests, and configuration files where useful.

### Lifecycle / Deadlines

Include rollout stages, migration steps, deadlines, deprecation plans, or follow-up work only when they affect the technical implementation. Do not turn this into a project plan.

### Alternatives Considered

Describe credible technical alternatives and the important trade-offs that led to the selected approach. Focus on engineering consequences rather than listing technologies that were considered.
