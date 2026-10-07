const allowed = new Set('app app_version edge_function supabase_category supabase_operation idempotent commit_sha environment route feature operation status outcome error_code error_class request_id requestId function_name functionName retryable duration_ms deck_id card_id user_id dependency host method category area source surface locale interaction target rating response_time_bucket due_cards cards_reviewed source_type notes_created cards_created pending_mutations synced failed attempt attempts read_only source has_goal has_target_date weekly_minutes_bucket email_confirmation_required count retries permanent transport table_name action deferred'.split(' '));
export function safeRoute(value: string) {
  let route=(value.split(/[?#]/)[0] ?? '/');
  try { route=new URL(value).pathname; } catch { /* relative route */ }
  return route.replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/gi,':id').slice(0,200);
}
export function safeProperties(value: unknown): Record<string,string|number|boolean|null> {
  if (!value || typeof value!=='object' || Array.isArray(value)) return {};
  const result:Record<string,string|number|boolean|null>={};
  for(const [key,item] of Object.entries(value)) {
    if(!allowed.has(key)||/password|token|secret|cookie|authorization|content|prompt|response|email/i.test(key)) continue;
    if(typeof item==='string') result[key]=key==='route'?safeRoute(item):item.slice(0,160);
    else if(item===null||typeof item==='boolean'||(typeof item==='number'&&Number.isFinite(item))) result[key]=item;
  }
  return result;
}
export function scrubBreadcrumb<T>(breadcrumb:T):T {
  const item=breadcrumb as any;
  return {type:item.type,category:item.category,level:item.level,timestamp:item.timestamp,data:safeProperties(item.data)} as T;
}
export function scrubSentryEvent<T>(event:T):T {
  const result={...(event as any)};
  if(result.request) result.request={method:result.request.method,url:result.request.url?safeRoute(result.request.url):undefined};
  if(result.user) result.user={id:result.user.id};
  if(result.extra) result.extra=safeProperties(result.extra);
  if(result.tags) result.tags=safeProperties(result.tags);
  if(result.contexts) result.contexts=result.contexts.trace?{trace:result.contexts.trace}:{};
  if(result.message) result.message='Application operation failed';
  delete result.logentry;
  if(result.breadcrumbs) result.breadcrumbs=result.breadcrumbs.map(scrubBreadcrumb);
  if(result.exception?.values) result.exception={...result.exception,values:result.exception.values.map((item:any)=>({...item,value:'Application operation failed',stacktrace:item.stacktrace?{...item.stacktrace,frames:item.stacktrace.frames?.map((frame:any)=>{const clean={...frame};delete clean.vars; if(clean.filename)clean.filename=clean.filename.split(/[?#]/)[0];return clean;})}:undefined}))};
  return result as T;
}
