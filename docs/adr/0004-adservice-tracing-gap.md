# 0004 — adservice (and shippingservice) tracing is not implemented upstream; we document it instead of faking it

- Status: accepted, gap OPEN
- Date: 2026-10-08
- Relates to: SPEC.md "Observability → Traces"; ROADMAP.md Phase 6 / Phase 11

## Context

The claim this repo is built to make is that Online Boutique's shipped manifests are a minimal
baseline and that a production rewrite can add every control they omit. Traces are one of those
controls. Upstream ships tracing behind an opt-in Kustomize component
(`kustomize/components/google-cloud-operations`), and that component patches seven services with
`ENABLE_TRACING=1`, `OTEL_SERVICE_NAME` and `COLLECTOR_SERVICE_ADDR`. The header of the patch list
starts with a line that is easy to read past:

```
# adservice - not yet implemented
# checkoutservice - tracing, profiler
```

That comment is not a TODO in passing. Verified in-tree at `v0.10.7`:

- `src/adservice/src/main/java/hipstershop/AdService.java` line 209:

  ```java
  private static void initTracing() {
      if (System.getenv("DISABLE_TRACING") != null) {
          logger.info("Tracing disabled.");
          return;
      }
      logger.info("Tracing enabled but temporarily unavailable");
      logger.info("See https://github.com/GoogleCloudPlatform/microservices-demo/issues/422 for more info.");
      // TODO(arbrown) Implement OpenTelemetry tracing
      logger.info("Tracing enabled - Stackdriver exporter initialized.");
  }
  ```

  The method body contains no tracer provider, no exporter and no instrumentation. It logs a
  Stackdriver message as its last line, for a service that on this platform has no Stackdriver
  in it.

- `src/shippingservice/main.go` line 159:

  ```go
  func initTracing() {
      // TODO(arbrown) Implement OpenTelemetry tracing
  }
  ```

  An empty function. The caller logs `"Tracing enabled, but temporarily unavailable"` while
  `DISABLE_TRACING` is unset, which is the upstream default.

  `shippingservice` was not in the brief — the task description named only `adservice`. It was
  found by grepping the whole tree for `DISABLE_TRACING`, and it is recorded here because an
  unrecorded gap is the thing this repo is supposed to be better than.

Two further findings, for completeness of the trace picture:

- `src/cartservice/` contains no OpenTelemetry reference of any kind. It is not a stubbed TODO,
  it was never instrumented.
- The six services that *are* instrumented — `frontend`, `checkoutservice`,
  `productcatalogservice`, `currencyservice`, `paymentservice`, `emailservice`,
  `recommendationservice` — all build their OTLP exporter from `COLLECTOR_SERVICE_ADDR`
  explicitly and hard-code `sdktrace.AlwaysSample()` (Go), `TracerProvider()` with the default
  parent-based/always sampler (Python), or a Node `NodeSDK` with the default sampler (JS). None
  of them read `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER` or
  `OTEL_TRACES_SAMPLER_ARG`.

Net effect: a full checkout journey produces spans from `frontend`, `checkoutservice`,
`productcatalogservice`, `currencyservice`, `paymentservice`, `recommendationservice` and
`emailservice`, and a hole where `shippingservice` and `cartservice` should be.

## Decision

Set `DISABLE_TRACING=1` on `adservice` and `shippingservice`, and wire the spec-standard OTel
environment variables (`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_TRACES_SAMPLER`, `OTEL_TRACES_SAMPLER_ARG`) into both so that an instrumented successor
image picks them up with no manifest change. Do not attach an OTel Java agent.

## Why not the Java agent

The obvious fix for `adservice` is the OpenTelemetry Java agent: an `initContainer` that copies
`opentelemetry-javaagent.jar` into a shared `emptyDir`, plus `JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar`.
It would genuinely produce traces, because the agent reads the `OTEL_*` environment natively and
does not need the application to know about it.

Three things stop it being the right call *in this build*:

1. **The version is not pinned anywhere this repo can point at.** SPEC.md's pinned-versions table
   does not contain a Java agent version, and the repo's own rule is "re-verify when a phase
   reopens; do not take versions from memory". Adding an unpinned agent to a hiring-visible repo
   to close a gap, rather than recording the gap and the condition for closing it, is the wrong
   trade.
2. **It cannot be verified.** There is no cluster yet, and `adservice`'s container runs with
   `readOnlyRootFilesystem: true`. The agent writes to a temp directory at start-up, which means
   either the agent's temp dir must be redirected onto a mounted `emptyDir` or the root
   filesystem has to be re-opened — and neither can be tested from a desk. Shipping an untested
   change to the security posture of a container to win a line on a diagram is worse than the
   line.
3. **It does not close the whole gap anyway.** `shippingservice` has a Go `initTracing()` that is
   an empty function, so the agent path would need a per-language answer per service; the honest
   fix for that one is upstream code, not a manifest.

## Consequences

- The trace query in SPEC.md ("a trace for a checkout request spans
  `frontend → checkout → payment` in Tempo") still holds: all three of those services are
  instrumented and none of them is one of the two stubs. What does not hold is a
  *shipping* span on the same trace.
- `DISABLE_TRACING=1` is a real behavioural change, not a comment. It makes the container log
  "Tracing disabled." instead of "Tracing enabled but temporarily unavailable". That is a
  deliberate trade in favour of a truthful log line.
- The egress rules for `adservice` and `shippingservice` in `apps/boutique/netpol/` already allow
  4317 to the collector, so the network path is open the day the gap closes. No manifest will
  need to change to enable it.

## What would close it

1. Pin an OTel Java agent version in SPEC.md's pinned-versions table.
2. Decide, with evidence from a running pod, where the agent's temp directory lives under
   `readOnlyRootFilesystem: true`.
3. Same question for `shippingservice`, which is a Go agent or a rebuild, not a Java one.
4. Delete this ADR and replace it with a trace query that includes a `shippingservice` span.

## What this ADR is not

This ADR does not claim the tracing gap is fixed. It records that it exists, why it was not
closed here, and what closing it would take.
