import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';

import 'playground_config.dart';
import 'playground_components.dart';

// ══════════════════════════════════════════════════════════════════════════════
// The full multi-agent software delivery pipeline assembled from
// ComposableNode components and Provider<T> typed context injection.
// ══════════════════════════════════════════════════════════════════════════════

/// Typed configuration bundle injected at the pipeline root.
const _projectConfig = ProjectConfig(
  projectName: 'Nexus API',
  language: 'Dart',
  targetDeploymentEnv: 'production',
  featureFlags: ['oauth2', 'rate_limiting', 'audit_logging'],
);

const _securityPolicy = SecurityPolicy(
  requireOWASPAudit: true,
  requireDependencyCheck: true,
  maxCvssScore: 6,
);

const _qualityGate = QualityGate(
  minTestCoverage: 90,
  enforceDocCoverage: true,
  requiredReviewers: ['architect', 'tech_lead', 'security_auditor'],
);

/// The complete multi-agent delivery pipeline for Nexus API.
///
/// Pipeline phases:
///   Phase 0 — Bootstrap:   Mount VFS storage, write project brief
///   Phase 1 — Planning:    Architect designs system from brief
///   Phase 2 — Build:       Backend + Frontend implemented in parallel
///   Phase 3 — Security:    Security audit with OWASP + dependency check
///   Phase 4 — Review:      Tech lead reviews implementations + security findings
///   Phase 5 — Testing:     QA writes 90%-coverage test suite
///   Phase 6 — Docs:        Technical writer produces API docs + runbook
///   Phase 7 — Delivery:    Architect assembles final delivery report
///
/// Typed context injections (ProviderNode`<T`>):
///   ProjectConfig    — consumed by all agent components
///   SecurityPolicy   — consumed by SecurityAuditComponent
///   QualityGate      — consumed by TechLeadReviewComponent + TestSuiteComponent
const nexusApiPipeline = Pipeline(
  spec: PipelineSpec(
    name: 'nexus_api_delivery_pipeline',
    version: '1.0.0',
    rootStoragePath: '/workspace',
    metadata: {
      'owner': 'platform-engineering',
      'project': 'Nexus API',
      'stage': 'production-delivery',
    },
  ),
  children: [
    // ── Phase 0: Bootstrap ────────────────────────────────────────────────────
    Mount(mount: StorageMount(mountPrefix: '/workspace')),

    // Write the project brief to VFS — the single source of truth
    WriteFile(
      path: '/workspace/brief.md',
      content: '''
# Nexus API — Project Brief

## Overview
Build a production-grade multi-tenant REST API platform called **Nexus API** using Dart.
The platform exposes a unified gateway for downstream microservices.

## Requirements
- JWT-based authentication with OAuth2 support
- Rate limiting (per-tenant and global)
- Full audit logging for compliance
- Multi-tenant data isolation
- Horizontal scalability (stateless service design)
- OpenAPI 3.0 documentation

## Non-Functional Requirements
- P99 latency < 50ms for authenticated requests
- 99.99% uptime SLA
- SOC 2 Type II compliance readiness
- Zero-downtime deployments

## Technology Constraints
- Language: Dart (shelf framework)
- Database: PostgreSQL with connection pooling
- Cache: Redis for session and rate-limit state
- Deployment: Kubernetes on GCP
''',
    ),

    // ── Typed context injection ───────────────────────────────────────────────
    // Wrap entire pipeline in Provider<ProjectConfig> so every ComposableNode
    // can call context.read<ProjectConfig>() down the tree.
    Provider<ProjectConfig>(
      value: _projectConfig,
      children: [
        // Provision the full agent team (reads ProjectConfig for role instructions)
        ProvisionAgentTeamComponent(),

        // ── Phase 1: Architecture Design ──────────────────────────────────────
        ArchitectureDesignComponent(
          briefPath: '/workspace/brief.md',
          outputPath: '/workspace/docs/architecture.md',
        ),

        // ── Phase 2: Parallel Implementation ─────────────────────────────────
        ParallelImplementationComponent(architecturePath: '/workspace/docs/architecture.md'),

        // ── Phase 3: Security Audit (with SecurityPolicy) ─────────────────────
        Provider<SecurityPolicy>(
          value: _securityPolicy,
          children: [
            SecurityAuditComponent(
              backendPath: '/workspace/src/backend/main.dart',
              architecturePath: '/workspace/docs/architecture.md',
            ),
          ],
        ),

        // ── Phase 4 + 5 + 6: Review, Testing, Docs (with QualityGate) ─────────
        Provider<QualityGate>(
          value: _qualityGate,
          children: [
            // Tech lead cross-reviews all implementation + security findings
            TechLeadReviewComponent(),

            // QA writes test suite targeting the quality gate's coverage requirement
            TestSuiteComponent(),
          ],
        ),

        // Docs have no quality gate dependency — run independently
        DocumentationComponent(),

        // ── Phase 7: Human Approval Gate & Delivery Subroutine ───────────────
        ApprovalGate(
          requestId: 'nexus_release_approval',
          prompt: 'Approve production deployment of Nexus API release v1.0.0?',
          onApprove: [Call(name: 'deploy_nexus_subroutine')],
          onReject: [
            WriteFile(
              path: '/workspace/reports/delivery_report.md',
              content: 'Deployment rejected by human approval gate.',
            ),
          ],
        ),

        // Reusable subroutine definition compiled into jump-isolated program memory
        Subroutine(
          name: 'deploy_nexus_subroutine',
          children: [
            DeliveryReportComponent(),
            WriteFile(
              path: '/workspace/reports/delivery_report.md',
              content: '\${delivery_report}',
            ),
            Return(value: 'delivery_report'),
          ],
        ),

        Output(output: 'delivery_report'),
      ],
    ),
  ],
);
