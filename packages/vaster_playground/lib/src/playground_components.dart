import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';

import 'playground_config.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Reusable ComposableNode components used throughout the playground pipeline.
// Each component reads typed configuration from BuildContext via context.read<T>().
// ══════════════════════════════════════════════════════════════════════════════

/// Provisions the full delivery team in one [AgentTeam]: Architect, Tech
/// Lead, Backend Dev, Frontend Dev, Security Auditor, QA Engineer, and
/// Technical Writer.
class ProvisionAgentTeamComponent extends ComposableNode {
  const ProvisionAgentTeamComponent();

  @override
  VasterNode build(BuildContext context) {
    final project = context.read<ProjectConfig>();
    return AgentTeam(roles: [
      AgentRole(
        roleId: 'architect',
        name: 'Lead Architect',
        title: 'Principal Software Architect',
        instruction:
            'You design scalable, production-ready system architectures for ${project.projectName}. '
            'You enforce clean boundaries, SOLID principles, and ${project.language} idioms. '
            'Always output structured Markdown design documents.',
      ),
      AgentRole(
        roleId: 'tech_lead',
        name: 'Tech Lead',
        title: 'Technical Lead Engineer',
        instruction:
            'You review implementation plans, enforce code standards, and ensure the team '
            'stays aligned with the architectural decisions for ${project.projectName}. '
            'You provide concrete, actionable feedback.',
      ),
      AgentRole(
        roleId: 'backend_dev',
        name: 'Backend Developer',
        title: 'Senior ${project.language} Backend Engineer',
        instruction:
            'You implement production-quality backend services using ${project.language}. '
            'You follow the architect\'s design documents and write clean, well-documented code. '
            'You target the ${project.targetDeploymentEnv} environment.',
      ),
      AgentRole(
        roleId: 'frontend_dev',
        name: 'Frontend Developer',
        title: 'Senior Frontend Engineer',
        instruction:
            'You build responsive, accessible frontend interfaces that consume the backend APIs '
            'for ${project.projectName}. You write clean component-based code.',
      ),
      AgentRole(
        roleId: 'security_auditor',
        name: 'Security Auditor',
        title: 'Application Security Engineer',
        instruction:
            'You perform thorough security audits of code and architecture for ${project.projectName}. '
            'You identify vulnerabilities (OWASP Top 10, injection attacks, auth flaws, etc.) '
            'and provide remediation guidance with severity scores.',
      ),
      AgentRole(
        roleId: 'qa_engineer',
        name: 'QA Engineer',
        title: 'Senior Quality Assurance Engineer',
        instruction:
            'You write comprehensive unit, integration, and E2E tests for ${project.projectName}. '
            'You use ${project.language}-idiomatic testing frameworks and ensure test coverage '
            'meets the quality gate.',
      ),
      AgentRole(
        roleId: 'tech_writer',
        name: 'Technical Writer',
        title: 'Senior Technical Documentation Engineer',
        instruction:
            'You produce clear, comprehensive API documentation, developer guides, and '
            'operational runbooks for ${project.projectName}. '
            'You use OpenAPI 3.0 spec for REST APIs.',
      ),
    ]);
  }
}

/// Designs system architecture from a brief and persists the result to VFS.
class ArchitectureDesignComponent extends ComposableNode {
  final String briefPath;
  final String outputPath;

  const ArchitectureDesignComponent({required this.briefPath, required this.outputPath});

  @override
  VasterNode build(BuildContext context) {
    final project = context.read<ProjectConfig>();
    return Transaction(
      children: [
        ReadFile(path: briefPath, output: 'project_brief'),
        Task(
          agentId: 'architect',
          output: 'architecture_doc',
          prompt:
              'Read the project brief below and produce a comprehensive system architecture '
              'document for ${project.projectName} using ${project.language}.\n\n'
              'Brief: \${project_brief}\n\n'
              'Include: system overview, component diagram, API contracts, data models, '
              'deployment topology for ${project.targetDeploymentEnv}, and technology decisions.',
        ),
        WriteFile(path: outputPath, content: '\${architecture_doc}'),
      ],
    );
  }
}

/// Runs parallel implementation tasks for backend and frontend simultaneously.
class ParallelImplementationComponent extends ComposableNode {
  final String architecturePath;

  const ParallelImplementationComponent({required this.architecturePath});

  @override
  VasterNode build(BuildContext context) {
    final project = context.read<ProjectConfig>();
    return Sequence([
        ReadFile(path: architecturePath, output: 'architecture_doc'),
        ParallelTasks(
          entries: [
            ParallelTaskEntry(
              agentId: 'backend_dev',
              output: 'backend_implementation',
              prompt:
                  'Implement the backend service for ${project.projectName} based on the '
                  'architecture document below. Write production-quality ${project.language} code '
                  'with proper error handling, logging, and configuration management.\n\n'
                  'Architecture: \${architecture_doc}',
            ),
            ParallelTaskEntry(
              agentId: 'frontend_dev',
              output: 'frontend_implementation',
              prompt:
                  'Implement the frontend client for ${project.projectName} based on the '
                  'architecture document below. Write clean, component-based UI code that '
                  'consumes the backend REST APIs.\n\n'
                  'Architecture: \${architecture_doc}',
            ),
          ],
        ),
        const WriteFile(
          path: '/workspace/src/backend/main.dart',
          content: '\${backend_implementation}',
        ),
        const WriteFile(
          path: '/workspace/src/frontend/app.dart',
          content: '\${frontend_implementation}',
        ),
    ]);
  }
}

/// Performs a comprehensive security audit.
class SecurityAuditComponent extends ComposableNode {
  final String backendPath;
  final String architecturePath;

  const SecurityAuditComponent({required this.backendPath, required this.architecturePath});

  @override
  VasterNode build(BuildContext context) {
    final policy = context.read<SecurityPolicy>();
    final owaspClause = policy.requireOWASPAudit ? 'Perform a full OWASP Top 10 audit. ' : '';
    final depClause = policy.requireDependencyCheck ? 'Check for vulnerable dependencies. ' : '';

    return Transaction(
      children: [
        ReadFile(path: backendPath, output: 'backend_src'),
        ReadFile(path: architecturePath, output: 'architecture_doc'),
        Task(
          agentId: 'security_auditor',
          output: 'security_report',
          prompt:
              '$owaspClause$depClause'
              'Identify all vulnerabilities with CVSS scores. Flag anything above '
              '${policy.maxCvssScore} as CRITICAL. Provide remediation steps.\n\n'
              'Backend source:\n\${backend_src}\n\n'
              'Architecture:\n\${architecture_doc}',
        ),
        const WriteFile(
          path: '/workspace/reports/security_audit.md',
          content: '\${security_report}',
        ),
      ],
    );
  }
}

/// Tech lead reviews both implementations for quality and architecture alignment.
class TechLeadReviewComponent extends ComposableNode {
  const TechLeadReviewComponent();

  @override
  VasterNode build(BuildContext context) {
    final gate = context.read<QualityGate>();
    final reviewersClause = gate.requiredReviewers.join(', ');

    return Task(
      agentId: 'tech_lead',
      output: 'tech_lead_review',
      prompt:
          'Review the backend and frontend implementations for quality, '
          'architecture alignment, and adherence to our quality gate:\n'
          '- Minimum test coverage: ${gate.minTestCoverage}%\n'
          '- Documentation coverage enforced: ${gate.enforceDocCoverage}\n'
          '- Required reviewers sign-off: $reviewersClause\n\n'
          'Backend:\n\${backend_implementation}\n\n'
          'Frontend:\n\${frontend_implementation}\n\n'
          'Security report:\n\${security_report}\n\n'
          'List all action items with MUST/SHOULD priority.',
    );
  }
}

/// Writes comprehensive test suites for the backend service.
class TestSuiteComponent extends ComposableNode {
  const TestSuiteComponent();

  @override
  VasterNode build(BuildContext context) {
    final gate = context.read<QualityGate>();
    final project = context.read<ProjectConfig>();

    return Transaction(
      children: [
        Task(
          agentId: 'qa_engineer',
          output: 'test_suite',
          prompt:
              'Write a comprehensive test suite for ${project.projectName} backend. '
              'Target ${gate.minTestCoverage}% code coverage. Include:\n'
              '- Unit tests for all business logic\n'
              '- Integration tests for all API endpoints\n'
              '- E2E tests for critical user flows\n'
              '- Security regression tests based on the audit findings\n\n'
              'Backend implementation:\n\${backend_implementation}\n\n'
              'Tech lead review (action items):\n\${tech_lead_review}\n\n'
              'Use ${project.language}-idiomatic testing patterns.',
        ),
        const WriteFile(path: '/workspace/test/api_test.dart', content: '\${test_suite}'),
      ],
    );
  }
}

/// Generates full API documentation and an operational runbook.
class DocumentationComponent extends ComposableNode {
  const DocumentationComponent();

  @override
  VasterNode build(BuildContext context) {
    final project = context.read<ProjectConfig>();
    return Transaction(
      children: [
        Task(
          agentId: 'tech_writer',
          output: 'api_documentation',
          prompt:
              'Write complete API documentation for ${project.projectName} including:\n'
              '1. OpenAPI 3.0 specification\n'
              '2. Developer getting-started guide\n'
              '3. Authentication & authorization guide\n'
              '4. Deployment runbook for ${project.targetDeploymentEnv}\n\n'
              'Architecture:\n\${architecture_doc}\n\n'
              'Backend implementation:\n\${backend_implementation}',
        ),
        const WriteFile(
          path: '/workspace/docs/api_reference.md',
          content: '\${api_documentation}',
        ),
      ],
    );
  }
}

/// Assembles the final delivery report aggregating all artefacts.
class DeliveryReportComponent extends ComposableNode {
  const DeliveryReportComponent();

  @override
  VasterNode build(BuildContext context) {
    final project = context.read<ProjectConfig>();
    return Task(
      agentId: 'architect',
      output: 'delivery_report',
      prompt:
          'Produce a final delivery report for ${project.projectName} summarising:\n'
          '- Architecture decisions and rationale\n'
          '- Implementation status (backend + frontend)\n'
          '- Security audit outcome and remediation status\n'
          '- Quality gate results (coverage, reviews)\n'
          '- Test results summary\n'
          '- Documentation completeness\n'
          '- Known risks and open items\n\n'
          'Architecture: \${architecture_doc}\n'
          'Security: \${security_report}\n'
          'Review: \${tech_lead_review}\n'
          'Tests: \${test_suite}\n'
          'Docs: \${api_documentation}',
    );
  }
}
