  // I need
  - vaster_model - model interface (execute request)
  - vaster_session - active session that a model can use to execute requests
  - vaster_session_manager - manages active sessions and their lifecycle
  
  - vaster_context - virtual context sources managing context window in a virtual way
  - vaster_context_manager - manages virtual context sources and their lifecycle
  
  - vaster_filesystem - virtual filesystem for context sources
  - vaster_filesystem_manager - manages virtual filesystem and its lifecycle
  - vaster_tool - tools available to the model for executing requests and managing context
  - vaster_tool_manager - manages tools and their lifecycle



  // context sources can be filesystem_source, tool_source, or any other source that can provide context to the model. The vaster_context_manager will manage these sources and their lifecycle, ensuring that the model has access to the necessary context for executing requests.

  # llm_core
  #     IDs
  #     lifecycle
  #     errors


  # llm_models
  #     ModelBackend
  #     ModelCapabilities


  # llm_sessions
  #     ModelSession


  # llm_session_runtime
  #     SessionManager


  # llm_filesystem
  #     FileSystem
  #     File
  #     Directory


  # llm_tools
  #     Tool
  #     ToolDefinition
  #     ToolResult


  # llm_context

  #     ContextHeap
  #     ContextRegion
  #     ContextSnapshot

  #     ContextManager

  #     TokenBudget
  #     TokenAllocator
  #     AllocationStrategy


  # llm_context_sources
  #     FileSource
  #     MemorySource
  #     ConversationSource


  # llm_execution
  #     ExecutionContext
  #     ResourceScope


  # llm_vm
  #     bytecode
  #     interpreter

  # llm_artifact_extractor - Turn model output into structured artifacts (e.g. JSON, YAML, etc.) for further processing or storage.

    #                  LLM VM

    #                     |
    # ------------------------------------------------

    # Scheduler          Event Bus          Policy

    #     |                  |                 |

    # Execution Runtime ---------------- Resource Manager

    #     |

    # ------------------------------------------------

    # Model       Context       Filesystem       Tools

    # Sessions    Memory        Storage          Actions


# class ContextRegion {

#   ContextId id;

#   int estimatedTokens;

#   ContextPriority priority;

#   ContextLifetime lifetime;

#   ContextUtility utility;

# }

# 1. Scheduler (llm_scheduler)

# You have:

# model sessions
# tools
# agents
# context compilation

# But who decides what runs when?

# You need something like an OS scheduler.

# Task Queue

#     |
#     v

# Scheduler

#     |
#     +---- Model execution
#     |
#     +---- Tool execution
#     |
#     +---- Agent execution

# Responsibilities:

# priority
# cancellation
# timeouts
# concurrency limits
# resource allocation

# Example:

# scheduler.spawn(
#     AgentTask(
#        priority: high,
#        budget: 10000,
#     )
# );
# 2. Event system (llm_events)

# An agent runtime will become asynchronous.

# Everything generates events:

# ModelStarted
# ModelTokenGenerated
# ToolCalled
# FileWritten
# ContextEvicted
# AgentSpawned

# A unified event bus:

# abstract interface class RuntimeEventBus {

#   Stream<RuntimeEvent> events;

#   void publish(RuntimeEvent event);

# }

# This enables:

# debugging
# replay
# monitoring
# observability
# 3. Transaction system (llm_transactions)

# This is a very interesting one.

# Agents constantly do risky operations:

# Modify 20 files
# Run tests
# Commit changes

# What if something fails?

# You want:

# BEGIN

# write file A
# write file B
# run tests

# COMMIT

# or:

# ROLLBACK

# This is database thinking applied to agents.

# 4. Checkpointing (llm_checkpoint)

# Related but different.

# A long-running agent should be resumable.

# Example:

# Agent execution

# Step 1 ✓
# Step 2 ✓
# Step 3 ✓
# Step 4 running

# Save:

# Checkpoint(
#     contextSnapshot,
#     memoryState,
#     executionStack,
#     filesystemState,
# )

# Then:

# machine crashes

# resume()


# ------------------------------------------

Yes. Time is fundamentally different from tokens/context. Your intuition is correct: **time belongs closer to the scheduler and execution runtime**, not the context system.

The analogy becomes:

```text
                Runtime Resources

        ┌───────────────┬───────────────┐
        |               |               |
      Memory          Compute          Time
        |               |               |
   Context System    Model System   Scheduler
```

Tokens answer:

> "What information can the model see?"

Time answers:

> "How long is this execution allowed to exist?"

---

## Introduce a Resource Manager

Instead of only thinking about token budgets, you are arriving at a general runtime resource model:

```text
llm_resources

    TokenBudget
    TimeBudget
    CostBudget
    ToolBudget
    StorageBudget
```

But the implementations are different.
