---
name: ml-repo-organisation-guidelines-for-coding-agents
description: Repository conventions for an ML project. Covers where every file belongs, the four maintained documents (ChangeLog.md, Decisions.md, Flow.md, and the README design doc), coding principles, and writing style. Use this skill for any work inside a repository that follows these conventions, including writing or modifying code, adding data or model artifacts, creating any new file, refactoring, debugging, running experiments, or writing documentation. Trigger it even when the user asks only for code and never mentions documentation or structure, because these conventions require a ChangeLog.md entry for every repository change and require every new file to be placed in its designated directory. Also trigger when the user asks where a file belongs, asks for a design doc, asks why a past decision was made, or asks how data flows through the system.
---

# ML Repo Organisation Guidelines for Coding Agents

These conventions optimise for two things at once: working code, and a repository that someone else can audit later. Code that runs but leaves no record of what changed or why fails the second goal, so it is not finished work.

The repository answers four questions, each in a fixed place:

| Question | Document | Updated |
|---|---|---|
| What changed? | `ChangeLog.md` | Every repository change, without exception |
| Why was it done this way? | `Decisions.md` | When a meaningful technical choice is made |
| How does the system work and flow? | `Flow.md` | When structure or execution flow changes |
| How will this be implemented? | `README.md` design doc | Before and during significant architectural change |

These four serve different purposes and must not become redundant with each other. `ChangeLog.md` is a record of events. `Decisions.md` is reasoning. `Flow.md` is a live description of the current system. The design doc is a technical proposal.

## Every change follows this loop

Copy this checklist into your working notes and complete it before reporting the task done.

```
- [ ] 1. Read the relevant code before changing it
- [ ] 2. Check whether the change is architecturally significant
- [ ] 3. Make the change, placing every new file in its designated directory
- [ ] 4. Update ChangeLog.md (always)
- [ ] 5. Update Decisions.md (if a meaningful technical choice was made)
- [ ] 6. Update Flow.md (if structure or execution flow changed)
- [ ] 7. Update the README design doc (if architecturally significant)
- [ ] 8. Confirm no empty, redundant, or unused directories were left behind
```

**Step 1 is not optional.** Understand the purpose and behaviour of code before changing it. Do not write code you cannot clearly explain. When important information is missing, ask rather than guessing silently.

**Step 2 decides how much documentation the change needs.** A change is architecturally significant when it introduces a major component, pipeline, API, model, database, or dependency, when it changes an important interface or data flow, or when it changes the evaluation methodology. Small bug fixes, minor refactoring, and formatting changes are not significant. They still require step 4.

## Where files go

```text
ml-project/
├── .github/workflows/ci-cd.yml   # GitHub Actions pipeline
├── data/
│   ├── raw/                      # Immutable source data
│   ├── processed/                # Transformed, model-ready data
│   └── external/                 # Third-party data
├── notebooks/                    # EDA and experiments
├── src/
│   ├── config/config.py
│   ├── data/                     # ingestion.py, validation.py, transformation.py
│   ├── features/feature_engineering.py
│   ├── models/                   # train.py, evaluate.py, predict.py
│   ├── pipelines/                # training_pipeline.py, inference_pipeline.py
│   ├── api/app.py                # FastAPI / Flask API
│   ├── utils/                    # logger.py, exception.py
│   └── entity/config_entity.py
├── models/                       # Saved model artifacts
├── reports/                      # Metrics, plots
├── logs/
├── tests/                        # Unit tests
├── requirements.txt
├── setup.py
├── Dockerfile
├── docker-compose.yml
├── README.md                     # Design doc
└── .env
```

**Placement rules.**

Every file you create goes in the directory that matches its role. Generated artifacts are not exempt. Metrics and plots go in `reports/`, trained models go in `models/`, log files go in `logs/`, and intermediate data goes in `data/processed/`. Do not leave them in the repository root or beside the code that produced them.

If a new kind of artifact does not fit any existing directory, either place it in the closest appropriate one or add a new directory and update this structure in the same change. Do not invent an undocumented directory.

Do not create or keep empty, redundant, or unused directories. If a change leaves a directory empty, remove it.

The repository must stay easy to navigate. When you are about to create a file, first check whether an existing file should be extended instead.

## ChangeLog.md

Record every repository change. The AI must not modify the repository without recording it here.

Each entry states which files changed, what changed, why when useful, and any behaviour or configuration impact. Newest entries go at the top.

```markdown
## 2026-08-25

### src/data/validation.py, src/pipelines/training_pipeline.py
Added a schema check that runs before transformation and raises on unexpected columns.
Reason: column drift in the raw exports was silently changing the feature count.
Impact: the training pipeline now fails fast on malformed input instead of training on it.
```

Keep entries brief. This file records what happened, not the reasoning behind it. Reasoning goes in `Decisions.md`.

## Decisions.md

Record the reasoning behind meaningful technical choices. The purpose is to explain **why** an implementation was chosen, not what was implemented.

Write an entry when choosing a language, framework, or library, when selecting an architecture or design pattern, when picking a database, API, model, or infrastructure component, when adding a test for a non-obvious reason, or when preferring one implementation approach over another that a reader might expect.

```markdown
## Store the processed data layer as Parquet

Date: 2026-08-25
Context: processed feature tables in data/processed/ are read repeatedly during
training and hyperparameter search.
Decision: src/data/transformation.py writes Parquet rather than CSV.
Alternatives: CSV stays readable in a text editor but does not preserve dtypes
and reads more slowly at this size.
Trade-off: files are no longer inspectable without a reader. Accepted because
dtype loss was repeatedly turning categorical columns into strings downstream.
```

The test for whether an entry is needed: would another developer, reading this code in six months, wonder why it was done this way? If yes, write the entry.

## Flow.md

Describe how the parts of the codebase work together, and how data and execution move through the system. This is a live description of the current system, not a history.

It should let a reader answer: what happens first, which function calls which, how data moves, which component depends on which, where an error can originate, and whether a bug in one component could have been caused by an earlier or later one. Cover the path from ingestion through transformation, feature engineering, training, evaluation, and inference.

Update it whenever structure or execution flow changes significantly. Adding a function to an existing module usually does not qualify. Adding a stage to a pipeline, changing what calls what, or changing where data enters or leaves does.

## README.md design doc

For significant architectural changes only. See [reference/design-doc.md](reference/design-doc.md) for the required sections, length, and update triggers. Read that file before writing or revising the design doc.

## Coding principles

1. **Maintain conceptual clarity.** Understand the purpose and behaviour of code before changing it. Do not generate code you cannot clearly explain.
2. **Code with explanation.** Non-trivial changes come with an explanation of the design, assumptions, and behaviour. Ask when important information is missing.
3. **Build debugging ability.** When debugging, explain the cause and the reasoning, not only the fix. The goal is to improve the developer's ability to debug without you.
4. **Write modular, maintainable code.** Keep responsibilities clear and modules reasonably sized. Avoid unnecessary coupling and duplication. Comment non-obvious reasoning, not self-explanatory code.
5. **Be ready for the next person.** Every change leaves the repository understandable, runnable, and maintainable by someone who did not make it.
6. **Prefer understanding over blind automation.** Inspect the relevant code, verify assumptions, and consider the effects of a change. Ask when something important is unclear rather than guessing silently.

## Writing style

Applies to prose you write in this repository, including the four documents above.

Always: complete grammatical sentences, sentences of about 25 words or fewer, active voice by default, plain and familiar words, and **no em dashes, en dashes, or semicolons as connectors**. Use a period, a comma, or a subordinate clause instead.

For reports, papers, experiment write-ups, and any academic or research writing, read [reference/writing-style.md](reference/writing-style.md) for the full standard, which covers precision of claims, citation, separating results from interpretation, and stating limitations.
