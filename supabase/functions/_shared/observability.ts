import * as Sentry from "@sentry/deno";

const dsn = Deno.env.get("SENTRY_DSN");
const posthogToken = Deno.env.get("POSTHOG_PROJECT_TOKEN");
const posthogHost = Deno.env.get("POSTHOG_HOST") ?? "https://us.i.posthog.com";
Sentry.init({ dsn, enabled: Boolean(dsn), environment: Deno.env.get("SENTRY_ENVIRONMENT") ?? "production", tracesSampleRate: Number(Deno.env.get("SENTRY_TRACES_SAMPLE_RATE") ?? "0.1"), sendDefaultPii: false });

type Context = { userId?: string; functionName: string; requestId: string };
type DependencyContext = { dependency: string; functionName?: string; requestId?: string };

export function setRequestContext(c: Context) {
  Sentry.setTag("edge_function", c.functionName);
  Sentry.setTag("request_id", c.requestId);
  if (c.userId) Sentry.setUser({ id: c.userId });
}

export function captureException(error: unknown, c: { functionName: string; requestId: string; userId?: string; tags?: Record<string, string>; extra?: Record<string, unknown> }) {
  Sentry.withScope((scope) => {
    scope.setTag("edge_function", c.functionName);
    scope.setTag("request_id", c.requestId);
    if (c.userId) scope.setUser({ id: c.userId });
    Object.entries(c.tags ?? {}).forEach(([k, v]) => scope.setTag(k, v));
    Object.entries(c.extra ?? {}).forEach(([k, v]) => scope.setExtra(k, sanitize(v)));
    Sentry.captureException(error);
  });
}

export async function capturePostHogEvent(i: { distinctId: string; event: string; properties: Record<string, unknown> }) {
  if (!posthogToken || Deno.env.get("POSTHOG_SERVER_ENABLED") === "0") return;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1500);
  try {
    await fetch(`${posthogHost.replace(/\/$/, "")}/i/v0/e/`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ api_key: posthogToken, event: i.event, distinct_id: i.distinctId, properties: { ...sanitize(i.properties), $lib: "flashi-supabase-edge" } }), signal: controller.signal });
  } catch (error) {
    console.warn(JSON.stringify({ event: "posthog_delivery_failed", error: error instanceof Error ? error.message : "unknown" }));
  } finally { clearTimeout(timeout); }
}

export function createObservedFetch(context: DependencyContext): typeof fetch {
  return async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const method = (init?.method ?? (typeof input !== "string" && !(input instanceof URL) ? input.method : "GET")).toUpperCase();
    const startedAt = performance.now();
    try {
      const response = await fetch(input, init);
      void capturePostHogEvent({ distinctId: context.requestId ?? crypto.randomUUID(), event: "dependency_request_completed", properties: { dependency: context.dependency, host: url.hostname, method, status: response.status, outcome: response.ok ? "success" : "error", duration_ms: Math.round(performance.now() - startedAt), function_name: context.functionName ?? "unknown" } });
      return response;
    } catch (error) {
      const typed = error instanceof Error ? error : new Error(String(error));
      captureException(typed, { functionName: context.functionName ?? "unknown", requestId: context.requestId ?? crypto.randomUUID(), tags: { area: "dependency", dependency: context.dependency }, extra: { host: url.hostname, method, duration_ms: Math.round(performance.now() - startedAt) } });
      void capturePostHogEvent({ distinctId: context.requestId ?? crypto.randomUUID(), event: "dependency_request_failed", properties: { dependency: context.dependency, host: url.hostname, method, outcome: "exception", error_code: typed.name, duration_ms: Math.round(performance.now() - startedAt), function_name: context.functionName ?? "unknown" } });
      throw error;
    }
  };
}

export function fetchWithObservability(input: RequestInfo | URL, init: RequestInit | undefined, context: DependencyContext): Promise<Response> {
  return createObservedFetch(context)(input, init);
}

export function withObservability(functionName: string, handler: (request: Request) => Response | Promise<Response>) {
  return async (request: Request): Promise<Response> => {
    const requestId = request.headers.get("x-request-id")?.trim() || crypto.randomUUID();
    const startedAt = performance.now();
    setRequestContext({ functionName, requestId });
    try {
      const headers = new Headers(request.headers);
      headers.set("x-request-id", requestId);
      headers.set("x-function-name", functionName);
      const observedRequest = new Request(request, { headers });
      const response = await handler(observedRequest);
      void capturePostHogEvent({ distinctId: requestId, event: "edge_request_completed", properties: { function_name: functionName, request_id: requestId, status: response.status, outcome: response.status >= 400 ? "error" : "success", duration_ms: Math.round(performance.now() - startedAt) } });
      console.log(JSON.stringify({ event: "edge_request_completed", function_name: functionName, request_id: requestId, status: response.status, duration_ms: Math.round(performance.now() - startedAt) }));
      return response;
    } catch (error) {
      captureException(error, { functionName, requestId, tags: { error_class: error instanceof Error ? error.name : "unknown" }, extra: { duration_ms: Math.round(performance.now() - startedAt) } });
      void capturePostHogEvent({ distinctId: requestId, event: "edge_request_failed", properties: { function_name: functionName, request_id: requestId, outcome: "exception", error_code: error instanceof Error ? error.name : "UNKNOWN_ERROR", duration_ms: Math.round(performance.now() - startedAt) } });
      throw error;
    }
  };
}

function sanitize(v: unknown): unknown {
  if (v === null || v === undefined || typeof v !== "object") return v;
  if (Array.isArray(v)) return `[array:${v.length}]`;
  return Object.fromEntries(Object.entries(v as Record<string, unknown>).filter(([k]) => !/token|secret|password|authorization|cookie|prompt|response|front|back|content|email|goal|target_date|weekly_minutes|idempotency_key|fingerprint/i.test(k)));
}
