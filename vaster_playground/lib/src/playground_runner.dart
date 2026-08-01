import 'dart:io';

import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_vm/vaster_vm.dart';

import 'nexus_api_pipeline.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Nexus API Pipeline Runner
//
// Compiles the multi-agent Nexus API delivery pipeline from AST to ISA
// bytecode and executes it end-to-end on the VasterRuntime.
// ══════════════════════════════════════════════════════════════════════════════

/// Fake model responses scoped by prompt substring match.
final _agentResponses = {
  // Architect – architecture design
  'comprehensive system architecture': '''
# Nexus API — System Architecture v1.0

## System Overview
Nexus API is a multi-tenant REST gateway built on Dart (shelf). It provides a unified
entry point for all downstream microservices with auth, rate-limiting, and audit logging.

## Component Diagram
  [Client] → [API Gateway] → [Auth Service] → [JWT Validator]
                          → [Rate Limiter]   → [Redis Store]
                          → [Audit Logger]   → [PostgreSQL]
                          → [Router]         → [Downstream Services]

## API Contracts
- POST /auth/token    — Issue JWT (OAuth2 client_credentials + password flows)
- POST /auth/refresh  — Refresh access token
- DELETE /auth/token  — Revoke token
- ANY  /{service}/*   — Proxy to downstream with auth context forwarded

## Data Models
- Tenant: { id, name, plan, rateLimitTier }
- Token: { jti, sub, tenantId, exp, scope[] }
- AuditEvent: { id, tenantId, method, path, statusCode, durationMs, ts }

## Deployment Topology (production)
- 3x API Gateway pods (HPA: CPU > 70%)
- Redis Sentinel cluster (3 nodes) for rate-limit state
- PostgreSQL HA (primary + 2 replicas) for audit + tenant data
- GCP Load Balancer → Ingress → Gateway pods
''',

  // Backend Dev – implementation
  'Implement the backend service': '''
// nexus_api/main.dart — Production Nexus API Gateway
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

Future<void> main() async {
  final router = Router()
    ..post('/auth/token', _handleTokenIssuance)
    ..post('/auth/refresh', _handleTokenRefresh)
    ..delete('/auth/token', _handleTokenRevocation)
    ..all('/\u003cservice\u003e/\u003cpath|.*\u003e', _handleProxy);

  final handler = Pipeline()
    .addMiddleware(logRequests())
    .addMiddleware(_rateLimitMiddleware())
    .addMiddleware(_auditMiddleware())
    .addHandler(router.call);

  final server = await io.serve(handler, '0.0.0.0', 8080);
  print('Nexus API running on \${server.address.host}:\${server.port}');
}

Handler _rateLimitMiddleware() => (Handler inner) => (Request req) async {
  // Token bucket algorithm — 1000 req/min per tenant
  final tenantId = req.headers['x-tenant-id'] ?? 'anonymous';
  final allowed = await _redisRateLimiter.isAllowed(tenantId, limit: 1000);
  if (!allowed) return Response(429, body: 'Rate limit exceeded');
  return inner(req);
};

Response _handleTokenIssuance(Request req) {
  // OAuth2 client_credentials + password flow with PKCE
  return Response.ok('{"access_token":"...","expires_in":3600}');
}
// ... (full implementation continues)
''',

  // Frontend Dev – implementation
  'Implement the frontend client': '''
// nexus-dashboard/src/App.dart — Nexus API Management Dashboard
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class NexusDashboardApp extends StatelessWidget {
  const NexusDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus API Dashboard',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const DashboardHome(),
    );
  }
}

class DashboardHome extends StatefulWidget {
  const DashboardHome({super.key});

  @override
  State<DashboardHome> createState() => _DashboardHomeState();
}

class _DashboardHomeState extends State<DashboardHome> {
  List<Map<String, dynamic>> _tenants = [];

  @override
  void initState() {
    super.initState();
    _loadTenants();
  }

  Future<void> _loadTenants() async {
    final resp = await http.get(Uri.parse('/api/tenants'));
    setState(() => _tenants = (jsonDecode(resp.body) as List).cast());
  }
  // ... (full dashboard continues)
}
''',

  // Security Auditor – OWASP audit
  'OWASP Top 10': '''
# Security Audit Report — Nexus API

## Executive Summary
Audit completed against OWASP Top 10 2023 and CWE Top 25.
**Overall Risk: MEDIUM** (no CRITICAL issues found; 3 HIGH, 5 MEDIUM)

## Findings

### HIGH — A01: Broken Access Control [CVSS 7.5 → CRITICAL, remediation required]
Rate limiter uses tenant header (x-tenant-id) without cryptographic verification.
An attacker can spoof tenant headers to bypass rate limits.
**Remediation**: Derive tenant from validated JWT claims, never from request headers.

### HIGH — A02: Cryptographic Failures [CVSS 6.8]
JWT signing currently uses HS256 (symmetric). Compromise of signing key
affects all tokens.
**Remediation**: Migrate to RS256 (asymmetric) with key rotation.

### HIGH — A07: Identification and Authentication Failures [CVSS 6.5]
Token refresh endpoint does not invalidate the old refresh token.
**Remediation**: Implement single-use refresh tokens stored in Redis.

### MEDIUM — A04: Insecure Design [CVSS 5.3]
No request size limit on proxy endpoint — potential DoS vector.
**Remediation**: Enforce 1MB request body limit via shelf middleware.

### MEDIUM — A09: Security Logging [CVSS 4.7]
AuditEvent does not capture client IP or User-Agent.
**Remediation**: Add forensic fields to AuditEvent schema.

## Dependency Check
No known CVEs found in current dependency tree.

## Remediation Priority
1. [P0] Fix JWT header spoofing (A01) before production launch
2. [P0] Implement RS256 signing (A02)
3. [P1] Single-use refresh tokens (A07)
4. [P2] Request size limits, audit enrichment
''',

  // Tech Lead – review
  'Review the backend and frontend implementations': '''
# Tech Lead Implementation Review

## Overall Assessment: APPROVED WITH CONDITIONS

### Quality Gate Status
- ✅ Architecture alignment: Backend matches architect's design
- ⚠️  Test coverage: Not yet measured (QA phase pending)
- ✅ Documentation: API contracts documented in architecture doc
- ⚠️  Security sign-off: 3 HIGH issues must be remediated before launch

### Backend MUST Items
1. Fix JWT tenant header spoofing (security P0 — blocks launch)
2. Migrate JWT to RS256 signing (security P0)
3. Implement single-use refresh tokens (security P1)
4. Add request body size limits (5MB max)
5. Add structured JSON logging (correlation IDs, trace headers)

### Frontend MUST Items
1. Add error boundary components for API failure states
2. Implement token refresh interceptor in HTTP client
3. Add loading skeletons to prevent layout shift

### SHOULD Items
- Add OpenTelemetry spans to gateway middleware
- Implement circuit breaker for downstream proxy calls
- Add e2e Playwright tests for auth flows

### Reviewer Sign-offs Required
- [x] Architect (architecture alignment ✅)
- [ ] Tech Lead (implementation quality — conditional on P0 fixes)
- [ ] Security Auditor (pending P0 remediation)
''',

  // QA Engineer – test suite
  'Write a comprehensive test suite': '''
// test/api_test.dart — Nexus API Test Suite (90%+ coverage target)
import 'package:test/test.dart';

void main() {
  group('Auth Service — Unit Tests', () {
    test('issues JWT with valid client_credentials grant', () async {
      final response = await authService.issueToken(
        grantType: GrantType.clientCredentials,
        clientId: 'test-client',
        clientSecret: 'test-secret',
      );
      expect(response.accessToken, isNotEmpty);
      expect(response.expiresIn, equals(3600));
      // Verify JWT claims
      final claims = JwtDecoder.decode(response.accessToken);
      expect(claims['sub'], equals('test-client'));
      expect(claims['scope'], contains('api:read'));
    });

    test('rejects forged tenant header — security regression (A01)', () async {
      final response = await httpClient.get(
        Uri.parse('/api/v1/resource'),
        headers: {'x-tenant-id': 'evil-tenant'},  // forged header
      );
      // Must use JWT-derived tenant, not header
      expect(response.statusCode, equals(401));
    });

    test('invalidates old refresh token after single use', () async {
      final token = await authService.issueToken(grantType: GrantType.password);
      final refreshed = await authService.refreshToken(token.refreshToken);
      expect(refreshed.accessToken, isNotEmpty);

      // Second use of same refresh token must fail (A07 regression)
      expect(
        () => authService.refreshToken(token.refreshToken),
        throwsA(isA<TokenRevokedException>()),
      );
    });

    test('rate limiter blocks after 1000 requests per minute', () async {
      // Exhaust rate limit
      for (var i = 0; i < 1000; i++) {
        await httpClient.get(Uri.parse('/api/v1/resource'));
      }
      final response = await httpClient.get(Uri.parse('/api/v1/resource'));
      expect(response.statusCode, equals(429));
    });
  });

  group('API Gateway — Integration Tests', () {
    test('proxies authenticated request to downstream service', () async { /* ... */ });
    test('rejects unauthenticated request with 401', () async { /* ... */ });
    test('enforces 1MB request body limit', () async { /* ... */ });
    test('writes audit event for every proxied request', () async { /* ... */ });
  });

  group('Multi-tenant Isolation', () {
    test('tenant A cannot access tenant B resources', () async { /* ... */ });
    test('rate limits are isolated per tenant', () async { /* ... */ });
  });
}
// Coverage: 94.2% (exceeds 90% quality gate)
''',

  // Tech Writer – documentation
  'Write complete API documentation': '''
# Nexus API — Developer Documentation

## OpenAPI 3.0 Specification
```yaml
openapi: 3.0.3
info:
  title: Nexus API Gateway
  version: 1.0.0
  description: Multi-tenant REST gateway for the Nexus platform
paths:
  /auth/token:
    post:
      summary: Issue access token
      requestBody:
        content:
          application/x-www-form-urlencoded:
            schema:
              properties:
                grant_type: { type: string, enum: [client_credentials, password] }
                client_id: { type: string }
                client_secret: { type: string }
      responses:
        '200': { description: JWT issued successfully }
        '401': { description: Invalid credentials }
```

## Getting Started
1. Request client credentials from the Nexus admin portal
2. Exchange credentials for an access token via POST /auth/token
3. Include `Authorization: Bearer {token}` on all API requests
4. Tokens expire after 1 hour; use /auth/refresh to renew

## Deployment Runbook (production / GCP / Kubernetes)
```bash
# 1. Build and push image
docker build -t gcr.io/nexus-prod/api-gateway:v1.0.0 .
docker push gcr.io/nexus-prod/api-gateway:v1.0.0

# 2. Apply Kubernetes manifests
kubectl apply -f k8s/production/
kubectl rollout status deployment/nexus-api-gateway

# 3. Verify health
curl https://api.nexus.io/health
```
''',

  // Architect – delivery report
  'final delivery report': '''
# Nexus API — Final Delivery Report v1.0.0

## Project Summary
Multi-tenant REST API gateway for the Nexus platform, built with Dart (shelf).
Delivered by a 7-agent pipeline: Architect, Tech Lead, Backend Dev, Frontend Dev,
Security Auditor, QA Engineer, and Technical Writer.

## Delivery Status: ✅ CONDITIONAL LAUNCH APPROVED

### Architecture ✅
- Shelf-based gateway with OAuth2, rate limiting, audit logging
- Redis Sentinel for state, PostgreSQL HA for persistence
- Kubernetes deployment on GCP — production topology complete

### Implementation ✅
- Backend: REST gateway with JWT auth, rate limiting, proxy routing
- Frontend: Flutter dashboard for tenant management
- All tech lead MUST items addressed

### Security ⚠️ → ✅ (post-remediation)
- 3 HIGH issues identified (A01, A02, A07)
- All P0 remediation items completed prior to launch
- Final CVSS max score: 5.3 (within policy limit of 6)

### Quality Gate ✅
- Test coverage: 94.2% (target: 90%)
- Documentation: Complete (OpenAPI 3.0 + runbook)
- Reviewer sign-offs: Architect ✅, Tech Lead ✅, Security Auditor ✅

### Known Risks
- Circuit breaker for downstream services: deferred to v1.1 (SHOULD priority)
- OpenTelemetry integration: deferred to v1.1

## Artefacts Produced
- /workspace/docs/architecture.md
- /workspace/src/backend/main.dart
- /workspace/src/frontend/app.dart
- /workspace/reports/security_audit.md
- /workspace/test/api_test.dart
- /workspace/docs/api_reference.md
- /workspace/reports/delivery_report.md
''',
};

/// Runs the full Nexus API multi-agent delivery pipeline.
Future<void> runPlayground() async {
  _printBanner();

  // ── 1. Compile AST → ISA bytecode ─────────────────────────────────────────
  _printPhase('COMPILATION', 'Compiling Nexus API Pipeline AST → ISA bytecode');
  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(nexusApiPipeline);
  _printCompilationStats(program);

  // ── 2. Bootstrap VM ────────────────────────────────────────────────────────
  _printPhase('VM BOOTSTRAP', 'Bootstrapping VasterVMEngine with FakeVasterModel');
  final fakeModel = FakeVasterModel(
    defaultResponseText: 'Agent response: task completed successfully.',
    // responseMap: _agentResponses,
  );
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: fakeModel, rootMountPath: '/workspace'),
  );
  stdout.writeln('  ✓ VM online — model: ${fakeModel.modelName}');
  stdout.writeln('  ✓ Response map: ${_agentResponses.length} agent personas loaded\n');

  // ── 3. Execute program ─────────────────────────────────────────────────────
  _printPhase('EXECUTION', 'Executing ${program.instructions.length} ISA instructions');
  final runtime = VasterRuntime(vm: vm);

  final stopwatch = Stopwatch()..start();
  final state = await runtime.executeProgram(program);
  stopwatch.stop();

  // ── 4. Print results ───────────────────────────────────────────────────────
  _printResults(state, stopwatch.elapsedMilliseconds);

  await vm.shutdown();
}

void _printBanner() {
  stdout.writeln('\n${'═' * 70}');
  stdout.writeln('  VASTER PLAYGROUND — Nexus API Multi-Agent Delivery Pipeline');
  stdout.writeln('  7 Agents · 7 Phases · ProviderNode<T> Context Injection');
  stdout.writeln('${'═' * 70}\n');
}

void _printPhase(String label, String description) {
  stdout.writeln('┌─ $label ${'─' * (64 - label.length - 3)}┐');
  stdout.writeln('│  $description');
  stdout.writeln('└${'─' * 69}┘\n');
}

void _printCompilationStats(VasterProgram program) {
  final opcodeCounts = <String, int>{};
  for (final inst in program.instructions) {
    final op = inst.toJson()['opcode'] as String;
    opcodeCounts[op] = (opcodeCounts[op] ?? 0) + 1;
  }

  stdout.writeln('  Pipeline: ${program.programName}');
  stdout.writeln('  Total ISA instructions: ${program.instructions.length}');
  stdout.writeln('  Instruction breakdown:');
  final sorted = opcodeCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted) {
    final bar = '█' * e.value;
    stdout.writeln('    ${e.key.padRight(28)} $bar (${e.value})');
  }
  stdout.writeln();
}

void _printResults(RuntimeState state, int elapsedMs) {
  final statusIcon = state.status == RuntimeStatus.halted ? '✅' : '❌';
  stdout.writeln('$statusIcon  Execution ${state.status.name.toUpperCase()} in ${elapsedMs}ms\n');

  if (state.status != RuntimeStatus.halted) {
    stdout.writeln('  Error: ${state.errorDetails}');
    return;
  }

  // Print all produced registers
  stdout.writeln('  Produced registers (${state.registers.length}):');
  for (final entry in state.registers.entries) {
    final value = entry.value?.toString() ?? '';
    final preview = value.length > 80 ? '${value.substring(0, 77)}...' : value;
    stdout.writeln('    [${entry.key}] ${preview.replaceAll('\n', ' ')}');
  }

  // Print delivery report
  if (state.registers.containsKey('delivery_report')) {
    stdout.writeln('\n${'─' * 70}');
    stdout.writeln('  FINAL DELIVERY REPORT');
    stdout.writeln('─' * 70);
    final report = state.registers['delivery_report']?.toString() ?? '';
    for (final line in report.split('\n').take(30)) {
      stdout.writeln('  $line');
    }
  }
}
