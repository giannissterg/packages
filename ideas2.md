# Time is a scheduler resource

A process in an OS has:

* CPU time
* priority
* deadline
* cancellation

Your LLM execution should have similar concepts.

Example:

```dart
class ExecutionBudget {
  final Duration maxDuration;
  final DateTime? deadline;
}
```

Usage:

```dart
runtime.execute(
  task,
  budget: ExecutionBudget(
    maxDuration: Duration(minutes: 5),
  ),
);
```

---

# Scheduler becomes responsible

The scheduler tracks:

```text
id="v4xj9f"
Execution Queue

Agent A
  deadline: 10:00:05
  priority: high

Agent B
  deadline: 10:05:00
  priority: low

Agent C
  no deadline
```

Then:

```text
Scheduler

decides:

- start
- pause
- cancel
- retry
- defer
```

---

# The important distinction: timeout vs budget

A timeout is simple:

```dart
await future.timeout(
    Duration(seconds: 30)
);
```

A budget is a resource.

Example:

```text
Execution starts:

Time budget:
10 minutes


Model call:
30 seconds


Tool call:
2 minutes


File operation:
10 seconds


Remaining:
7m20s
```

Every subsystem consumes from the same budget.

---

# Hierarchical time budgets

This matches your VM idea very well.

Example:

```text
Root Execution

budget:
30 minutes


|
+-- Planning phase
|      budget:
|      5 minutes
|
+-- Coding phase
|      budget:
|      20 minutes
|
+-- Testing phase
       budget:
       5 minutes
```

The child cannot exceed the parent.

Similar to token budgets:

```text
Root Budget
     |
     +---- Child Budget
                |
                +---- Grandchild Budget
```

---

# Time affects context decisions

An interesting interaction appears.

Suppose:

```text
Remaining time:
30 seconds

Remaining tokens:
50k
```

You probably do NOT want:

```text
Search entire repository
summarize everything
```

Instead:

```text
Use existing context
produce answer
```

So the scheduler can influence context allocation.

The architecture:

```text
                 Execution Runtime

                        |
          ┌─────────────┴─────────────┐

          Scheduler              Resource Monitor

              |                         |

          Time Budget             Token Budget

                                        |
                                        |
                                Context Allocator

```

---

# Execution states

You probably need process-like states:

```dart
enum ExecutionState {
  created,
  queued,
  running,
  waiting,
  paused,
  completed,
  failed,
  cancelled,
  timedOut,
}
```

---

# Cooperative cancellation

LLM systems are not like CPUs. You cannot always kill execution instantly.

You need cancellation propagation:

```text
Execution cancelled

        |
        +-- stop model generation
        |
        +-- cancel tool calls
        |
        +-- release context
        |
        +-- rollback transactions
```

Similar to structured concurrency.

---

# Time is also needed for planning

An advanced runtime could let the model know:

```text
You have:

5 minutes
20k tokens
3 tool calls
```

Then the model can adapt.

Example:

```text
Large budget:

"Analyze architecture deeply"


Small budget:

"Provide minimal fix"
```

---

# Package structure evolution

Now I would add:

```text
llm_scheduler

    Scheduler
    TaskQueue
    Priority
    Deadline


llm_runtime

    Execution
    ExecutionState
    ResourceScope


llm_resources

    TimeBudget
    TokenBudget
    CostBudget
```

---

The dependency graph becomes:

```text
                 Execution Runtime

                         |
              Resource Scope
                         |
       ┌─────────────────┼─────────────────┐

       v                 v                 v

  Scheduler        Context Manager     Tool Manager

       |                 |                 |

  Time Budget      Token Budget      Tool Budget

                         |
                         v

                  Model Session
```

---

This separation is very important. If you put time management inside context management, you will eventually have a tangled system. Context answers **"what can the model know?"**. Scheduler answers **"when and how much can the computation run?"**.

The natural next question after time is probably **execution lifecycle and cancellation**, because once you have time as a resource, you need processes that can start, suspend, resume, checkpoint, and terminate. That leads directly toward the VM layer.


-----------------------------------------------------------

Yes. With that addition, your runtime is becoming a complete **resource-controlled execution environment**.

The permission/policy layer is the missing piece that answers:

> "What is this execution allowed to do?"

It is different from tokens and time:

* **Context** → what information is available
* **Tokens** → how much reasoning capacity is available
* **Time** → how long execution may continue
* **Permissions** → what actions are allowed

This maps very closely to operating systems.

```text
                 Execution

                    |
            Resource Scope

        ┌───────────┼───────────┐
        |           |           |
     Context      Time       Permissions
     Memory       Budget     Policy

        |           |           |
     Tokens     Scheduler     Security
```

---

## Create a policy package

Something like:

```text
llm_policy
```

or:

```text
llm_security
```

Responsibilities:

* define capabilities
* check operations
* enforce restrictions
* audit violations

---

# Capability-based design

I would avoid thinking only in terms of users/roles.

A stronger model is **capabilities**.

A capability is a token that grants a specific power.

Example:

```dart
Capability(
    action: FileAction.write,
    resource: "/workspace/src/**"
)
```

An agent receives:

```text
Coding Agent capabilities:

✓ read /workspace
✓ write /workspace/src
✓ execute tests

✗ access secrets
✗ modify deployment config
```

---

## Policy evaluation

Every dangerous operation goes through:

```dart
PolicyEngine.authorize(
    ExecutionContext,
    Operation
)
```

Example:

```dart
await filesystem.write(
    "/production/database.sql",
    content,
);
```

Internally:

```text
FileSystem

    |
    v

PolicyEngine

    |
    +-- allowed → continue
    |
    +-- denied → reject
```

---

# Policies should apply everywhere

Not just tools.

## Filesystem

```text
Allowed:

read:
 /src/**

write:
 /src/**


Denied:

delete:
 /production/**
```

---

## Tools

```text
Agent:

Allowed tools:

✓ search
✓ read_file
✓ run_tests


Denied:

✗ deploy
✗ send_email
```

---

## Models

Interesting possibility:

```text
Simple task:

allowed:
cheap model


Complex reasoning:

allowed:
advanced model
```

Policy:

```dart
if(task.cost > limit)
    deny();
```

---

## Token/time/cost are also policies

Your policy layer could unify constraints.

Example:

```yaml
agent: coding_agent

limits:
  tokens: 100000
  time: 30m
  money: $5

permissions:
  filesystem:
    - read:/project/**
    - write:/project/src/**

  tools:
    - git
    - terminal
```

---

# Hierarchical policies

This is where it becomes powerful.

Like process inheritance:

```text
Root Runtime Policy

    |
    |
    +-- Coding Agent Policy

            |
            |
            +-- Test Agent Policy
```

A child cannot gain permissions that the parent does not have.

Example:

```text
Root:

filesystem:
  /workspace


Child:

requests:
  /workspace/src


Result:

allowed
```

But:

```text
Child:

requests:
  /etc


Result:

denied
```

---

# Policy + VM instructions

Your future bytecode can have security checks:

Example:

```text
LOAD_CONTEXT
CHECK_PERMISSION
CALL_TOOL
WRITE_FILE
```

or even:

```text
CALL_TOOL(read_file)

requires capability:

filesystem.read
```

---

# Auditing

A serious runtime should record:

```text
PolicyEvent

Agent:
coding-agent

Action:
write_file

Resource:
src/auth.dart

Decision:
allowed

Reason:
capability filesystem.write
```

This integrates naturally with your event system.

---

# The architecture now looks like this

```text
                         LLM VM

                            |
                    Execution Runtime

                            |
                    Resource Scope

     ┌──────────────┬───────────────┬──────────────┐

     Context        Scheduler       Policy         Tools
     Memory         Time            Security       Actions

        |              |              |              |

    Token Budget   Time Budget   Capabilities   External World

                            |
                            v

                       Model Session
```

---

At this point your runtime has the same fundamental primitives as an operating system:

| OS concept      | LLM runtime equivalent  |
| --------------- | ----------------------- |
| Process         | Agent execution         |
| Memory          | Virtual context         |
| Virtual memory  | Context compiler        |
| CPU scheduling  | LLM/tool scheduler      |
| File system     | Artifact storage        |
| Syscalls        | Tools                   |
| Permissions     | Policies/capabilities   |
| Resource limits | Token/time/cost budgets |
| Process state   | Execution checkpoints   |

The next architectural question after this would probably be **how to represent execution itself**: whether your agents/functions should compile into bytecode and run on a VM, or whether the runtime should stay as a graph/workflow executor. That is where your earlier AST/bytecode ideas become relevant.

----

llm_core

llm_models
    ModelBackend

llm_sessions
    ModelSession

llm_context
    Virtual Memory

llm_filesystem
    Storage

llm_tools
    Actions

llm_budget
    Resources

llm_scheduler
    Time

llm_policy
    Security


llm_agents
    Identity + Roles

llm_execution
    Process Runtime

llm_messaging
    Agent Communication

llm_memory
    Persistent Knowledge

llm_planner
    Task Decomposition


llm_vm
    Bytecode + Interpreter
