# Run Burmese IME Quality Pipeline

Run the full 6-step Burmese IME quality pipeline for $ARGUMENTS iteration(s).

You are the orchestrator. You must NOT do any codebase work yourself. Your only job is to dispatch work to subagents using the Task tool and pass their outputs forward.

For each iteration 1..$ARGUMENTS, execute these steps in order using the Task tool:

**Step 1:** Use the Task tool to invoke the `step-1-task-creation` agent:
> "Investigate the codebase, find issues, and create task files in tasks/ as described in your instructions."

Wait for it to complete and capture its JSON output as step1_result.

**Step 2:** Use the Task tool to invoke the `step-2-task-validation` agent:
> "Validate and refine the task files in tasks/. Step 1 produced: {step1_result}"

Wait for it to complete and capture its JSON output as step2_result.

**Step 3:** Use the Task tool to invoke the `step-3-task-execution` agent:
> "Implement fixes for all valid tasks using TDD. Step 2 produced: {step2_result}"

Wait for it to complete and capture its JSON output as step3_result.

**Step 4:** Use the Task tool to invoke the `step-4-completion-validation` agent:
> "Validate all completed tasks and identify any gaps. Step 3 produced: {step3_result}"

Wait for it to complete and capture its JSON output as step4_result.

**Step 5 (only if step4_result.gaps_found is true):** Use the Task tool to invoke the `step-5-gap-fixes` agent:
> "Fix all identified gaps. Step 4 produced: {step4_result}"

Wait for it to complete and capture its JSON output as step5_result.

**Step 6:** Use the Task tool to invoke the `step-6-archive-cleanup` agent:
> "Archive this iteration. Results: step3={step3_result} step4={step4_result} step5={step5_result}"

After each iteration completes, append a summary line to pipeline-run.log.

Do not use Bash, Read, or any other tool to do codebase work yourself. Every action on the codebase must happen inside a Task-dispatched subagent.
