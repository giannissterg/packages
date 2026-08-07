import 'package:vaster_model/vaster_model.dart' show ModelDescriptor;
import 'package:vaster_policy/vaster_policy.dart';

/// Descriptor handle metadata defining an agent's identity, role, and capabilities.
class AgentDescriptor {
  /// Unique agent identifier.
  final String agentId;

  /// Human-readable name (e.g. 'ResearchAgent', 'CoderAgent').
  final String name;

  /// High-level role or job title description.
  final String role;

  /// Top-level system prompt instruction guiding agent behavior.
  final String systemInstruction;

  /// Whitelist of allowed tool names accessible by this agent.
  /// An empty list means all registered tools are exposed.
  final List<String> allowedToolNames;

  /// Maximum number of model→tool→model loop iterations allowed per task.
  /// Prevents runaway tool call chains. Defaults to 10.
  final int maxToolCallLoops;

  /// Optional execution policy governing capabilities and security restrictions for this agent.
  final ExecutionPolicy? policy;

  /// The model this agent runs on, resolved through the registry at
  /// creation. Null means the VM's default (or a host-supplied override).
  /// Declared here so agent model identity is compiled, auditable data —
  /// `CreateAgentOp` carries the descriptor through the ISA.
  final ModelDescriptor? modelDescriptor;

  /// Ordered fallback chain after [modelDescriptor] (GAP-3b, mirroring
  /// `SelectModel.fallbacks`): a model-kind failure on an agent turn falls
  /// through descriptor by descriptor, each tried once. Cancellation never
  /// advances the chain; retry-same-model is `Resilient`'s job.
  final List<ModelDescriptor> modelFallbacks;

  /// Arbitrary metadata attributes.
  final Map<String, dynamic> metadata;

  const AgentDescriptor({
    required this.agentId,
    required this.name,
    required this.role,
    required this.systemInstruction,
    this.allowedToolNames = const [],
    this.maxToolCallLoops = 10,
    this.policy,
    this.modelDescriptor,
    this.modelFallbacks = const [],
    this.metadata = const {},
  });

  /// ABI naming convention: the model session provisioned for the agent with
  /// [agentId]. The workflow compiler emits session ops against this name and
  /// the agent manager provisions under it — both must agree, so the rule
  /// lives here in the one leaf package every layer already imports.
  static String sessionIdFor(String agentId) => 'sess_$agentId';

  Map<String, dynamic> toJson() => {
        'agentId': agentId,
        'name': name,
        'role': role,
        'systemInstruction': systemInstruction,
        'allowedToolNames': allowedToolNames,
        'maxToolCallLoops': maxToolCallLoops,
        if (policy != null) 'policy': policy!.toJson(),
        // Emitted only when declared: pre-chain descriptors stay
        // byte-identical (tape/checkpoint compatibility).
        if (modelDescriptor != null)
          'modelDescriptor': modelDescriptor!.toJson(),
        if (modelFallbacks.isNotEmpty)
          'modelFallbacks': [for (final f in modelFallbacks) f.toJson()],
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  factory AgentDescriptor.fromJson(Map<String, dynamic> json) {
    return AgentDescriptor(
      agentId: json['agentId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? '',
      systemInstruction: json['systemInstruction'] as String? ?? '',
      allowedToolNames:
          (json['allowedToolNames'] as List?)?.cast<String>() ?? [],
      maxToolCallLoops: json['maxToolCallLoops'] as int? ?? 10,
      policy: json['policy'] != null
          ? ExecutionPolicy.fromJson(json['policy'] as Map<String, dynamic>)
          : null,
      modelDescriptor: json['modelDescriptor'] != null
          ? ModelDescriptor.fromJson(
              Map<String, dynamic>.from(json['modelDescriptor'] as Map))
          : null,
      modelFallbacks: [
        for (final f in json['modelFallbacks'] as List? ?? const [])
          ModelDescriptor.fromJson(Map<String, dynamic>.from(f as Map)),
      ],
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

  @override
  String toString() =>
      'AgentDescriptor(id: "$agentId", name: "$name", role: "$role")';
}
