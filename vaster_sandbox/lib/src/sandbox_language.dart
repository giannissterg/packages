/// Strongly-typed enum representing supported programming languages / runtimes for sandbox execution.
enum SandboxLanguage {
  dart('dart'),
  bash('bash'),
  sh('sh'),
  python('python'),
  javascript('javascript'),
  custom('custom');

  final String name;

  const SandboxLanguage(this.name);

  static SandboxLanguage parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final lang in SandboxLanguage.values) {
      if (lang.name == lower) return lang;
    }
    return SandboxLanguage.custom;
  }

  @override
  String toString() => name;
}
