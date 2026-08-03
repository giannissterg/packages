import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_resources/vaster_resources.dart';

/// Static capability audit of a compiled [VasterProgram].
///
/// Because the ISA is finite and every control-flow destination is static,
/// a program's capabilities can be enumerated *before* execution: which
/// paths it can touch, which tools and models it can invoke, where the model
/// holds the steering wheel (the decision surface), where humans gate it,
/// and what resource ceilings it declares. This is the audit a prompt-based
/// agent cannot give you.
///
/// Interpolated fields (`${...}`) are reported honestly as *dynamic*: a
/// write path containing a register reference is not statically bounded, so
/// it is listed as a template rather than silently counted as a literal.
final class CapabilityAudit {
  final String programName;
  final int instructionCount;

  /// Mounted filesystems: prefix → backing (`memory` or the disk path).
  final Map<String, String> mounts;

  /// Statically-known read/write paths.
  final Set<String> staticReads;
  final Set<String> staticWrites;

  /// Interpolated path templates (dynamic capability).
  final Set<String> dynamicReads;
  final Set<String> dynamicWrites;

  /// Registered tool names (the model can call these in tool loops).
  final Set<String> tools;

  /// Provisioned agents: id → role title.
  final Map<String, String> agents;

  final Set<String> sessions;

  /// Selected models as `provider:modelId` descriptor keys.
  final Set<String> models;

  /// Registered sandboxes: id → language (code-execution capability).
  final Map<String, String> sandboxes;
  final int sandboxExecutions;

  /// The decision surface: every point where the model steers control flow.
  final List<DecisionPoint> decisions;

  /// Human gates: pc → request id.
  final Map<int, String> humanGates;

  /// Declared resource ceilings.
  final List<ResourceQuota> quotas;

  /// Inter-agent messages: `sender → recipient` pairs.
  final Set<String> messageEdges;

  const CapabilityAudit({
    required this.programName,
    required this.instructionCount,
    required this.mounts,
    required this.staticReads,
    required this.staticWrites,
    required this.dynamicReads,
    required this.dynamicWrites,
    required this.tools,
    required this.agents,
    required this.sessions,
    required this.models,
    required this.sandboxes,
    required this.sandboxExecutions,
    required this.decisions,
    required this.humanGates,
    required this.quotas,
    required this.messageEdges,
  });

  factory CapabilityAudit.of(VasterProgram program) {
    final mounts = <String, String>{};
    final staticReads = <String>{};
    final staticWrites = <String>{};
    final dynamicReads = <String>{};
    final dynamicWrites = <String>{};
    final tools = <String>{};
    final agents = <String, String>{};
    final sessions = <String>{};
    final models = <String>{};
    final sandboxes = <String, String>{};
    var sandboxExecutions = 0;
    final decisions = <DecisionPoint>[];
    final humanGates = <int, String>{};
    final quotas = <ResourceQuota>[];
    final messageEdges = <String>{};

    bool isDynamic(String text) =>
        RegisterInterpolation.token.allMatches(text).any((m) => m.group(1) != null);

    for (var pc = 0; pc < program.instructions.length; pc++) {
      switch (program.instructions[pc]) {
        case MountFsOp(:final mountPrefix, :final diskPath):
          mounts[mountPrefix] = diskPath ?? 'memory';
        case ReadFileOp(:final vfsPath):
          (isDynamic(vfsPath) ? dynamicReads : staticReads).add(vfsPath);
        case WriteFileOp(:final vfsPath):
          (isDynamic(vfsPath) ? dynamicWrites : staticWrites).add(vfsPath);
        case RegisterToolSetOp(tools: final toolDefs):
          tools.addAll(toolDefs.map((t) => t.name));
        case CreateAgentOp(:final descriptor):
          agents[descriptor.agentId] = descriptor.role;
        case CreateSessionOp(:final sessionId):
          sessions.add(sessionId);
        case SelectModelOp(:final descriptor):
          models.add(descriptor.descriptorKey);
        case RegisterSandboxOp(:final sandboxId, :final language):
          sandboxes[sandboxId] = language.name;
        case ExecSandboxOp():
          sandboxExecutions++;
        case DecideOp(:final prompt, :final branches, :final defaultLabel):
          decisions.add(DecisionPoint(
            pc: pc,
            prompt: prompt,
            branches: {for (final b in branches) b.label: b.targetPc},
            defaultLabel: defaultLabel,
          ));
        case YieldHumanInteractionOp(:final request):
          humanGates[pc] = request.requestId;
        case SetQuotaOp(:final quota):
          quotas.add(quota);
        case SendMessageOp(:final senderId, :final recipientId):
          messageEdges.add('$senderId → $recipientId');
        default:
          break;
      }
    }

    return CapabilityAudit(
      programName: program.programName,
      instructionCount: program.instructions.length,
      mounts: mounts,
      staticReads: staticReads,
      staticWrites: staticWrites,
      dynamicReads: dynamicReads,
      dynamicWrites: dynamicWrites,
      tools: tools,
      agents: agents,
      sessions: sessions,
      models: models,
      sandboxes: sandboxes,
      sandboxExecutions: sandboxExecutions,
      decisions: decisions,
      humanGates: humanGates,
      quotas: quotas,
      messageEdges: messageEdges,
    );
  }

  Map<String, dynamic> toJson() => {
        'programName': programName,
        'instructionCount': instructionCount,
        'mounts': mounts,
        'files': {
          'staticReads': staticReads.toList()..sort(),
          'staticWrites': staticWrites.toList()..sort(),
          'dynamicReads': dynamicReads.toList()..sort(),
          'dynamicWrites': dynamicWrites.toList()..sort(),
        },
        'tools': tools.toList()..sort(),
        'agents': agents,
        'sessions': sessions.toList()..sort(),
        'models': models.toList()..sort(),
        'sandboxes': sandboxes,
        'sandboxExecutions': sandboxExecutions,
        'decisions': [for (final d in decisions) d.toJson()],
        'humanGates': humanGates.map((pc, id) => MapEntry('$pc', id)),
        'quotas': [for (final q in quotas) q.toJson()],
        'messageEdges': messageEdges.toList()..sort(),
      };

  String toPrettyString() {
    final buffer = StringBuffer()
      ..writeln('── CAPABILITY AUDIT ─ $programName '
          '($instructionCount instructions) ─────')
      ..writeln();

    void section(String title, Iterable<String> lines,
        {String emptyNote = '(none)'}) {
      buffer.writeln('$title:');
      if (lines.isEmpty) {
        buffer.writeln('  $emptyNote');
      } else {
        for (final line in lines) {
          buffer.writeln('  $line');
        }
      }
      buffer.writeln();
    }

    section(
        'Filesystem mounts',
        mounts.entries.map((e) => e.value == 'memory'
            ? '${e.key}  (memory)'
            : '${e.key}  → DISK ${e.value}'));
    section('File writes', [
      ...(staticWrites.toList()..sort()),
      ...(dynamicWrites.toList()..sort())
          .map((t) => '$t  ⚠ dynamic (interpolated)'),
    ]);
    section('File reads', [
      ...(staticReads.toList()..sort()),
      ...(dynamicReads.toList()..sort())
          .map((t) => '$t  ⚠ dynamic (interpolated)'),
    ]);
    section('Callable tools', tools.toList()..sort(),
        emptyNote: '(none registered — built-in write_file/read_file VFS '
            'syscalls remain available to tool loops)');
    section('Agents',
        agents.entries.map((e) => '${e.key}  (${e.value})'));
    section('Models', models.toList()..sort(),
        emptyNote: '(default model only)');
    section(
        'Sandboxes (code execution)',
        sandboxes.entries
            .map((e) => '${e.key}  [${e.value}]')
            .followedBy(sandboxExecutions > 0
                ? ['$sandboxExecutions execution site(s)']
                : []));
    section(
        'Decision surface — where the model steers',
        decisions.map((d) {
          final menu = d.branches.entries
              .map((b) => '${b.key}→PC:${b.value}')
              .join(', ');
          final def = d.defaultLabel == null ? '' : ' default=${d.defaultLabel}';
          return '[PC:${d.pc.toString().padLeft(4, '0')}] {$menu}$def '
              '"${d.prompt.length <= 60 ? d.prompt : '${d.prompt.substring(0, 60)}…'}"';
        }),
        emptyNote: '(none — control flow is fully static)');
    section(
        'Human gates',
        humanGates.entries
            .map((e) => '[PC:${e.key.toString().padLeft(4, '0')}] ${e.value}'));
    section(
        'Resource ceilings',
        quotas.map((q) => [
              if (q.maxTokenBudget != null) '${q.maxTokenBudget} tokens',
              if (q.timeDeadline != null) '${q.timeDeadline!.inSeconds}s',
              if (q.maxCostBudget != null) '\$${q.maxCostBudget}',
            ].join(', ')),
        emptyNote: '(none declared — unlimited)');
    section('Inter-agent messages', messageEdges.toList()..sort());

    return buffer.toString();
  }
}

/// One model-steered branch point.
final class DecisionPoint {
  final int pc;
  final String prompt;
  final Map<String, int> branches;
  final String? defaultLabel;

  const DecisionPoint({
    required this.pc,
    required this.prompt,
    required this.branches,
    this.defaultLabel,
  });

  Map<String, dynamic> toJson() => {
        'pc': pc,
        'prompt': prompt,
        'branches': branches,
        if (defaultLabel != null) 'defaultLabel': defaultLabel,
      };
}
