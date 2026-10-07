import { safeProperties,scrubSentryEvent,scrubBreadcrumb } from './privacy.ts';
import * as Sentry from "@sentry/deno";

let dsn = Deno.env.get("SENTRY_DSN");
let posthogToken = Deno.env.get("POSTHOG_PROJECT_TOKEN");
let posthogHost = Deno.env.get("POSTHOG_HOST") ?? "https://us.i.posthog.com";
function configureTelemetry() {
  Sentry.init({ dsn, enabled:Boolean(dsn),environment:Deno.env.get('SENTRY_ENVIRONMENT')??'production',release:`flashi@${Deno.env.get('FLASHI_COMMIT_SHA')??'local'}`,tracesSampleRate:0.1,sendDefaultPii: false,beforeSend:scrubSentryEvent,beforeBreadcrumb:scrubBreadcrumb });
}
configureTelemetry();
let configPromise:Promise<void>|null=null;
let lastConfigAttempt=0;
async function ensureTelemetryConfiguration() {
  if (dsn && posthogToken) return;
  if (configPromise) return configPromise;
  if (Date.now()-lastConfigAttempt<60_000) return;
  lastConfigAttempt=Date.now();
  configPromise=(async()=>{
    const url=Deno.env.get('SUPABASE_URL'); const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if(!url||!key)return;
    try {
      const response=await fetch(`${url}/rest/v1/rpc/read_observability_runtime_config`,{method:'POST',headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:'{}',signal:AbortSignal.timeout(1500)});
      if(!response.ok)return;
      const config=await response.json();
      if(config?.sentry_dsn)dsn=config.sentry_dsn;
      if(config?.posthog_token)posthogToken=config.posthog_token;
      if(config?.posthog_host)posthogHost=config.posthog_host;
      configureTelemetry();
    } catch { /* Observability configuration must not block product operations. */ }
  })().finally(()=>{configPromise=null;});
  return configPromise;
}
function keepAlive(task:Promise<unknown>) { const runtime=(globalThis as any).EdgeRuntime; if(runtime?.waitUntil)runtime.waitUntil(task); }


type Context = { userId?: string; functionName: string; requestId: string };
type DependencyContext = { dependency: string; functionName?: string; requestId?: string };

export function setRequestContext(_context:Context) { /* Per-request context is passed to captureException. */ }

export function captureException(error: unknown, c: { functionName: string; requestId: string; userId?: string; tags?: Record<string, string>; extra?: Record<string, unknown> }) {
  Sentry.withScope((scope) => {
    scope.setTag("edge_function", c.functionName);
    scope.setTag("request_id", c.requestId);
    if (c.userId) scope.setUser({ id: c.userId });
    Object.entries(c.tags ?? {}).forEach(([k, v]) => scope.setTag(k, v));
    Object.entries(c.extra ?? {}).forEach(([k, v]) => scope.setExtra(k, sanitize(v)));
    Sentry.captureException(error);
    keepAlive(Sentry.flush(1500));
  });
}

export function capturePostHogEvent(i:{distinctId:string;event:string;properties:Record<string,unknown>}) {
  const task=(async()=>{
    if(!posthogToken||Deno.env.get('POSTHOG_SERVER_ENABLED')==='0')return;
    try {
      await fetch(`${posthogHost.replace(/\/$/,'')}/i/v0/e/`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({api_key:posthogToken,event:i.event,distinct_id:i.distinctId,properties:{...safeProperties(i.properties),$lib:'flashi-supabase-edge',commit_sha:Deno.env.get('FLASHI_COMMIT_SHA'),environment:'production'}}),signal:AbortSignal.timeout(1500)});
    } catch { console.warn(JSON.stringify({event:'posthog_delivery_failed'})); }
  })();
  keepAlive(task); return task;
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

export function telemetryUserId(request:Request):string|undefined {
 // Correlation only; never used for authorization. Gateway/body authentication is separate.
 try { const part=(request.headers.get('authorization')??'').split('.')[1];if(!part)return undefined;const value=JSON.parse(atob(part.replaceAll('-','+').replaceAll('_','/'))).sub;return typeof value==='string'&&/^[0-9a-f-]{36}$/i.test(value)?value:undefined; } catch {return undefined;}
}

export function withObservability(functionName: string, handler: (request: Request) => Response | Promise<Response>) {
  return async (request: Request): Promise<Response> => {
    const suppliedId=request.headers.get('x-request-id')?.trim()??'';
    const requestId=/^[0-9a-f-]{36}$/i.test(suppliedId)?suppliedId:crypto.randomUUID();
    await ensureTelemetryConfiguration();
    const userId=telemetryUserId(request);
    const startedAt = performance.now();
    setRequestContext({ functionName, requestId });
    try {
      const headers = new Headers(request.headers);
      headers.set("x-request-id", requestId);
      headers.set("x-function-name", functionName);
      const observedRequest = new Request(request, { headers });
      const response = await handler(observedRequest);
      void capturePostHogEvent({ distinctId: userId??requestId, event: "edge_request_completed", properties: { user_id:userId,function_name: functionName, request_id: requestId, status: response.status, outcome: response.status >= 400 ? "error" : "success", duration_ms: Math.round(performance.now() - startedAt) } });
      console.log(JSON.stringify({ event: "edge_request_completed", function_name: functionName, request_id: requestId, status: response.status, duration_ms: Math.round(performance.now() - startedAt) }));
      const responseHeaders=new Headers(response.headers); responseHeaders.set('X-Request-Id',requestId);
      return new Response(response.body,{status:response.status,statusText:response.statusText,headers:responseHeaders});
    } catch (error) {
      captureException(error, { functionName, requestId,userId, tags: { error_class: error instanceof Error ? error.name : "unknown" }, extra: { duration_ms: Math.round(performance.now() - startedAt) } });
      void capturePostHogEvent({ distinctId: userId??requestId, event: "edge_request_failed", properties: { function_name: functionName, request_id: requestId, outcome: "exception", error_code: error instanceof Error ? error.name : "UNKNOWN_ERROR", duration_ms: Math.round(performance.now() - startedAt) } });
      return new Response(JSON.stringify({error:'Internal server error',code:'INTERNAL_ERROR',requestId,request_id:requestId,stage:functionName,retryable:true,status:500}),{status:500,headers:{'Content-Type':'application/json','X-Request-Id':requestId}});
    }
  };
}

function sanitize(v:unknown):unknown { return safeProperties(v); }
