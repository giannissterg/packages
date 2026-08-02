/// Strongly-typed enum representing all securable execution actions in the Vaster VM.
enum PolicyAction {
  fileRead('file:read'),
  fileWrite('file:write'),
  fileDelete('file:delete'),
  toolCall('tool:call'),
  sandboxExec('sandbox:exec'),
  modelGenerate('model:generate'),
  agentSpawn('agent:spawn'),
  humanInteraction('human:interact');

  final String name;
  const PolicyAction(this.name);

  static PolicyAction parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final action in PolicyAction.values) {
      if (action.name == lower || action.name.split(':').last == lower) {
        return action;
      }
    }
    return PolicyAction.fileRead;
  }

  @override
  String toString() => name;
}
