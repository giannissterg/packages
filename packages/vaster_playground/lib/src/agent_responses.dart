// Raw string literals for fake agent responses — no escaping needed.
// ignore_for_file: unnecessary_string_escapes

final _architectureResponse = '''
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
''';

final _backendResponse = r'''
// nexus_api/main.dart — Production Nexus API Gateway
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

Future<void> main() async {
  final router = Router()
    ..post('/auth/token', _handleTokenIssuance)
    ..post('/auth/refresh', _handleTokenRefresh)
    ..delete('/auth/token', _handleTokenRevocation)
    ..all('/<service>/<path|.*>', _handleProxy);

  final handler = Pipeline()
    .addMiddleware(logRequests())
    .addMiddleware(_rateLimitMiddleware())
    .addMiddleware(_auditMiddleware())
    .addHandler(router.call);

  final server = await io.serve(handler, '0.0.0.0', 8080);
  print('Nexus API running on ${server.address.host}:${server.port}');
}

Handler _rateLimitMiddleware() => (Handler inner) => (Request req) async {
  // Token bucket — 1000 req/min per tenant derived from validated JWT
  final tenantId = _extractTenantFromJwt(req);
  final allowed = await _redisRateLimiter.isAllowed(tenantId, limit: 1000);
  if (!allowed) return Response(429, body: 'Rate limit exceeded');
  return inner(req);
};

Response _handleTokenIssuance(Request req) {
  // OAuth2 client_credentials + password flow with RS256 signing
  return Response.ok('{"access_token":"...","expires_in":3600,"token_type":"Bearer"}');
}
// ... (full implementation continues)
''';

final _frontendResponse = r'''
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

class _DashboardHomeState extends State<DashboardHome> {
  List<Map<String, dynamic>> _tenants = [];

  Future<void> _loadTenants() async {
    final resp = await http.get(Uri.parse('/api/tenants'));
    setState(() => _tenants = (jsonDecode(resp.body) as List).cast());
  }
  // ... (full dashboard continues)
}
''';

final _securityResponse = '''
# Security Audit Report — Nexus API

## Executive Summary
Audit completed against OWASP Top 10 2023 and CWE Top 25.
**Overall Risk: MEDIUM** (no CRITICAL issues found; 3 HIGH, 5 MEDIUM)

## Findings

### HIGH — A01: Broken Access Control [CVSS 7.5]
Rate limiter must derive tenant from JWT, never from request headers.
**Remediation**: Extract tenant from validated JWT claims only.

### HIGH — A02: Cryptographic Failures [CVSS 6.8]
JWT signing currently uses HS256 (symmetric).
**Remediation**: Migrate to RS256 (asymmetric) with key rotation.

### HIGH — A07: Auth Failures [CVSS 6.5]
Token refresh endpoint does not invalidate old refresh token.
**Remediation**: Implement single-use refresh tokens stored in Redis.

### MEDIUM — A04: Insecure Design [CVSS 5.3]
No request size limit on proxy endpoint.
**Remediation**: Enforce 1MB limit via shelf middleware.

### MEDIUM — A09: Security Logging [CVSS 4.7]
AuditEvent missing client IP and User-Agent.
**Remediation**: Add forensic fields to AuditEvent schema.

## Dependency Check
No known CVEs in current dependency tree.

## Remediation Priority
1. [P0] JWT header spoofing (A01)
2. [P0] RS256 migration (A02)
3. [P1] Single-use refresh tokens (A07)
4. [P2] Request size limits, audit enrichment
''';

final _reviewResponse = '''
# Tech Lead Implementation Review

## Overall Assessment: APPROVED WITH CONDITIONS

### Quality Gate Status
- Architecture alignment: PASS
- Security sign-off: CONDITIONAL (P0 fixes required before launch)
- Documentation: PASS

### Backend MUST Items
1. Fix JWT tenant header spoofing (security P0)
2. Migrate JWT to RS256 signing (security P0)
3. Implement single-use refresh tokens (security P1)
4. Add request body size limits (1MB max)
5. Add structured JSON logging (correlation IDs, trace headers)

### Frontend MUST Items
1. Add error boundary components for API failure states
2. Implement token refresh interceptor in HTTP client

### Reviewer Sign-offs Required
- [x] Architect (architecture alignment)
- [ ] Tech Lead (pending P0 fixes)
- [ ] Security Auditor (pending P0 remediation)
''';

final _testSuiteResponse = r'''
// test/api_test.dart — Nexus API Test Suite (94.2% coverage)
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
      final claims = JwtDecoder.decode(response.accessToken);
      expect(claims['sub'], equals('test-client'));
    });

    test('rejects forged tenant header (A01 regression)', () async {
      final response = await httpClient.get(
        Uri.parse('/api/v1/resource'),
        headers: {'x-tenant-id': 'evil-tenant'},
      );
      expect(response.statusCode, equals(401));
    });

    test('invalidates old refresh token after single use (A07 regression)', () async {
      final token = await authService.issueToken(grantType: GrantType.password);
      final refreshed = await authService.refreshToken(token.refreshToken);
      expect(refreshed.accessToken, isNotEmpty);
      expect(
        () => authService.refreshToken(token.refreshToken),
        throwsA(isA<TokenRevokedException>()),
      );
    });

    test('rate limiter blocks after 1000 requests per minute', () async {
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
  });

  group('Multi-tenant Isolation', () {
    test('tenant A cannot access tenant B resources', () async { /* ... */ });
    test('rate limits are isolated per tenant', () async { /* ... */ });
  });
}
// Coverage: 94.2% (exceeds 90% quality gate)
''';

final _documentationResponse = '''
# Nexus API — Developer Documentation v1.0

## OpenAPI 3.0 Specification (excerpt)
- POST /auth/token — Issue JWT (client_credentials / password grant)
- POST /auth/refresh — Refresh access token (single-use refresh tokens)
- DELETE /auth/token — Revoke token
- ANY /{service}/{path} — Authenticated proxy to downstream service

## Getting Started
1. Request client credentials from the Nexus admin portal
2. Exchange credentials: POST /auth/token with grant_type=client_credentials
3. Add Authorization: Bearer {token} to all requests
4. Tokens expire after 3600s — use /auth/refresh to renew

## Deployment Runbook (production / GCP / Kubernetes)
```bash
docker build -t gcr.io/nexus-prod/api-gateway:v1.0.0 .
docker push gcr.io/nexus-prod/api-gateway:v1.0.0
kubectl apply -f k8s/production/
kubectl rollout status deployment/nexus-api-gateway
curl https://api.nexus.io/health  # verify
```
''';

final _deliveryReportResponse = '''
# Nexus API — Final Delivery Report v1.0.0

## Project Summary
Multi-tenant REST API gateway for the Nexus platform, built with Dart (shelf).
Delivered by a 7-agent pipeline across 7 phases.

## Delivery Status: CONDITIONAL LAUNCH APPROVED

### Architecture: PASS
Shelf-based gateway with OAuth2 (RS256), rate limiting, audit logging.
Kubernetes on GCP — production topology complete.

### Implementation: PASS
Backend: REST gateway with JWT auth, rate limiting, proxy routing.
Frontend: Flutter dashboard for tenant management.

### Security: PASS (post-remediation)
3 HIGH issues identified and remediated.
Final CVSS max: 5.3 (within policy limit of 6).

### Quality Gate: PASS
Test coverage: 94.2% (target: 90%)
Documentation: Complete (OpenAPI 3.0 + runbook)
All reviewer sign-offs obtained.

### Artefacts Produced
- /workspace/docs/architecture.md
- /workspace/src/backend/main.dart
- /workspace/src/frontend/app.dart
- /workspace/reports/security_audit.md
- /workspace/test/api_test.dart
- /workspace/docs/api_reference.md
- /workspace/reports/delivery_report.md
''';

/// Aggregated response map used by [FakeVasterModel].
final agentResponseMap = {
  'comprehensive system architecture': _architectureResponse,
  'Implement the backend service': _backendResponse,
  'Implement the frontend client': _frontendResponse,
  'OWASP Top 10': _securityResponse,
  'Review the backend and frontend implementations': _reviewResponse,
  'Write a comprehensive test suite': _testSuiteResponse,
  'Write complete API documentation': _documentationResponse,
  'final delivery report': _deliveryReportResponse,
};
