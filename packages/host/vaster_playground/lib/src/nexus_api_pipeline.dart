import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';

import 'playground_components.dart';
import 'playground_config.dart';

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
const nexusApiPipeline = Pipeline(
  spec: PipelineSpec(
    name: 'nexus_api_delivery_pipeline',
    version: '1.0.0',
    rootStoragePath: '/workspace',
    metadata: {'owner': 'platform-engineering', 'project': 'Nexus API', 'stage': 'production-delivery'},
  ),
  children: [
    // ── Phase 0: Bootstrap ────────────────────────────────────────────────────
    Mount(mount: StorageMount(mountPrefix: '/workspace')),

    // Write the project brief to VFS — the single source of truth
    WriteFile(
      path: Template.text('/workspace/brief.md'),
      content: Template.text('''
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
'''),
    ),

    // ── Typed context injection ───────────────────────────────────────────────
    Provider<ProjectConfig>(
      value: _projectConfig,
      children: [
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
          children: [TechLeadReviewComponent(), TestSuiteComponent()],
        ),

        DocumentationComponent(),

        // ── Phase 7: Human Approval Gate & Delivery Component ────────────────
        ApprovalGate(
          requestId: 'nexus_release_approval',
          prompt: Template.text('Approve production deployment of Nexus API release v1.0.0?'),
          onApprove: [
            DeliveryReportComponent(),
            WriteFile(
              path: Template.text('/workspace/reports/delivery_report.md'),
              content: Template([Binding('delivery_report')]),
            ),
          ],
          onReject: [
            WriteFile(
              path: Template.text('/workspace/reports/delivery_report.md'),
              content: Template.text('Deployment rejected by human approval gate.'),
            ),
          ],
        ),
      ],
    ),
  ],
);
