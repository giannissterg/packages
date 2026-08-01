/// Typed domain configuration objects used by ProviderNode`<T`> injections
/// throughout the playground pipeline.
library;

/// Top-level project configuration injected into the pipeline context.
class ProjectConfig {
  final String projectName;
  final String language;
  final String targetDeploymentEnv;
  final List<String> featureFlags;

  const ProjectConfig({
    required this.projectName,
    required this.language,
    this.targetDeploymentEnv = 'production',
    this.featureFlags = const [],
  });

  bool hasFeature(String flag) => featureFlags.contains(flag);

  @override
  String toString() =>
      'ProjectConfig("$projectName" [$language] -> $targetDeploymentEnv)';
}

/// Security policy injected via ProviderNode for security-aware components.
class SecurityPolicy {
  final bool requireOWASPAudit;
  final bool requireDependencyCheck;
  final int maxCvssScore;

  const SecurityPolicy({
    this.requireOWASPAudit = true,
    this.requireDependencyCheck = true,
    this.maxCvssScore = 7,
  });

  @override
  String toString() =>
      'SecurityPolicy(owasp=$requireOWASPAudit, depCheck=$requireDependencyCheck, maxCvss=$maxCvssScore)';
}

/// Quality gate configuration for code review and testing.
class QualityGate {
  final int minTestCoverage;
  final bool enforceDocCoverage;
  final List<String> requiredReviewers;

  const QualityGate({
    this.minTestCoverage = 80,
    this.enforceDocCoverage = true,
    this.requiredReviewers = const ['architect', 'tech_lead'],
  });

  @override
  String toString() =>
      'QualityGate(coverage=$minTestCoverage%, docCoverage=$enforceDocCoverage)';
}
