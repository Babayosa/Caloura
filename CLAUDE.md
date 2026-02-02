# Claude Code Operating Rules (Repository Constitution)

These instructions are ALWAYS in effect for work in this repo.

## Workflow Orchestration

### 1) Plan Mode Default
- For ANY non-trivial task (3+ steps, multiple files, architectural decisions), start with a PLAN before touching code.
- If something goes sideways, STOP and re-plan immediately. Do not push forward blindly.
- Use planning for verification steps too, not just building.
- Write detailed specs up front to reduce ambiguity (inputs, outputs, constraints, acceptance criteria).

### 2) Subagent Strategy
- Use subagents liberally to keep the main context clean.
- Offload research, exploration, and parallel analysis to subagents.
- For complex problems, split the work: one subagent per focused task.
- Do not mix tasks inside one subagent.

### 3) Self-Improvement Loop
- After ANY correction from the user or any bug due to misunderstanding, update `tasks/lessons.md` using:
  - Mistake → Root cause → New rule to prevent it → Example
- Ruthlessly iterate on these lessons until the mistake rate drops.
- At session start, re-scan lessons relevant to the current task before acting.

### 4) Verification Before Done
- Never mark a task "done" without proving it works.
- Explain differences between main vs changed behavior when relevant.
- Ask: "Would a staff engineer approve this?"
- Run tests, check logs, and demonstrate correctness with evidence.

### 5) Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "Is there a more elegant way?"
- If a fix feels hacky, rewrite it as the clean solution.
- Skip this for simple, obvious fixes (do not over-engineer).
- Challenge your own work before presenting it.

### 6) Autonomous Bug Fixing
- When given a bug report: fix it. Do not ask for hand-holding.
- Start from logs/errors/failing tests → then resolve.
- Minimize context switching required from the user.
- Do not "silence" failing CI. Make it actually correct.

#### Bug Fix Protocol
- For non-trivial bugs: write a failing test at the lowest viable level
  (unit > integration > e2e) BEFORE implementing the fix.
- Record: expected vs actual, exact trigger, test command.
- Fix minimally. Confirm the test passes.
- If a deterministic test isn't feasible, document why and what you did instead.

---

## Task Management Protocol

For EVERY task:

1. **Plan First**
   - Write the plan to `tasks/todo.md` as a checklist (small, checkable items).
2. **Verify Plan**
   - Before implementing, sanity-check the plan vs requirements and repo conventions.
3. **Track Progress**
   - Mark checklist items complete as you go.
4. **Explain Changes**
   - Provide a short high-level summary for each major step.
5. **Document Results**
   - Add a "Review / Evidence" section to `tasks/todo.md` with proof (tests run, outputs).
6. **Capture Lessons**
   - Update `tasks/lessons.md` after corrections or notable discoveries.

---

## Core Principles

- **Simplicity First:** Make every change as simple as possible. Minimal code. Minimal surface area.
- **No Laziness:** Fix root causes. No temporary fixes. Meet senior dev standards.
- **Minimal Impact:** Touch only what's necessary. Avoid introducing new bugs.

---

## Definition of Done (DoD)
A task is DONE only if:
- The plan checklist is completed in `tasks/todo.md`
- Verification evidence exists (tests/logs/output)
- Any new rules/lessons are recorded in `tasks/lessons.md`
