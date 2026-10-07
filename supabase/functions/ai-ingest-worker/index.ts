import {getCorsHeaders,handleCors,handleError,RequestError} from '../_shared/http.ts';
import {ingestionSchema,validateIngestionNotes,type IngestionNote as Note} from '../_shared/ai-ingestion-contract.ts';
import { createObservedFetch, fetchWithObservability, withObservability, captureException,capturePostHogEvent } from "../_shared/observability.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { load } from "npm:cheerio@1.0.0";
import { secureDeterministicFetch } from "../_shared/security.ts";

type Job = { job_id: string; user_id: string; deck_id: string; source_type: string; source_reference: string | null };

const MAX_PDF_BYTES = 15 * 1024 * 1024;
const MAX_SOURCE_CHARS = 250_000;
const MAX_WEB_BYTES = 600_000;
const BUCKET = Deno.env.get("INGESTION_BUCKET") ?? "import-media";

function required(name: string): string { const value = Deno.env.get(name); if (!value) throw new Error(`Missing ${name}`); return value; }
function admin(request: Request): SupabaseClient { return createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), { global: { fetch: createObservedFetch({ dependency: "supabase-admin", functionName: "ai-ingest-worker", requestId: request.headers.get("x-request-id") ?? undefined }) }, auth: { persistSession: false } }); }
function safeStoragePath(path: string, userId: string): void {
  if (!path || path.startsWith("/") || path.includes("..") || !path.startsWith(`${userId}/`)) throw new Error("Invalid storage path");
}
async function sourceText(job: Job, client: SupabaseClient): Promise<string> {
  const ref = job.source_reference ?? "";
  if (job.source_type === "raw_text_block") return ref.slice(0, MAX_SOURCE_CHARS);
  if (job.source_type === "web_page") {
    const response = await secureDeterministicFetch(ref); if (!response.ok) throw new Error(`Web source returned HTTP ${response.status}`);
    const contentLength = Number(response.headers.get("content-length") ?? "0");
    if (contentLength > MAX_WEB_BYTES) throw new Error("Web source exceeds the memory limit");
    const buffer = await response.arrayBuffer();
    if (buffer.byteLength > MAX_WEB_BYTES) throw new Error("Web source exceeds the memory limit");
    const html = new TextDecoder().decode(buffer); const $ = load(html); $("script,style,noscript").remove();
    return $("body").text().replace(/\s+/g, " ").trim().slice(0, MAX_SOURCE_CHARS);
  }
  if (job.source_type === "youtube_url") {
    const mod = await import("npm:youtube-transcript@1.2.1") as { YoutubeTranscript?: { fetchTranscript(url: string): Promise<Array<{ text: string }>> } };
    if (!mod.YoutubeTranscript) throw new Error("YouTube transcript provider unavailable");
    const transcript = await mod.YoutubeTranscript.fetchTranscript(ref);
    return transcript.map((line) => line.text).join(" ").slice(0, MAX_SOURCE_CHARS);
  }
  safeStoragePath(ref, job.user_id);
  const { data, error } = await client.storage.from(BUCKET).download(ref);
  if (error || !data) throw new Error("Source file unavailable");
  if (data.size > MAX_PDF_BYTES) throw new Error("PDF exceeds the 15 MiB limit");
  const mod = await import("npm:pdf-parse@1.1.1/lib/pdf-parse.js");
  const parser=mod.default as unknown as (input:Uint8Array,options:{max:number})=>Promise<{text:string;numpages:number}>;
  const parsed=await parser(new Uint8Array(await data.arrayBuffer()),{max:100});
  if(parsed.numpages>100)throw new Error("PDF_PAGE_LIMIT_EXCEEDED");
  return parsed.text.replace(/\s+/g, " ").trim().slice(0, MAX_SOURCE_CHARS);
}
async function generateNotes(text: string): Promise<Note[]> {
  const key = required("OPENAI_API_KEY");
  const base = Deno.env.get("OPENAI_API_BASE") ?? "https://api.openai.com/v1";
  const response = await fetchWithObservability(`${base}/chat/completions`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` }, body: JSON.stringify({
    model: Deno.env.get("INGESTION_MODEL") ?? "gpt-4o-mini", temperature: 0,
    messages: [{ role: "system", content: "Transforme o texto em notas de estudo. Responda apenas no schema fornecido; crie campos e cartões úteis e não invente conteúdo." }, { role: "user", content: text }],
    response_format:{type:"json_schema",json_schema:{name:"flashi_ingestion",strict:true,schema:ingestionSchema}},
  }) }, { dependency: "llm-ingestion" });
  if (!response.ok) throw new Error(`LLM provider returned HTTP ${response.status}`);
  const body = await response.json(); const content = body.choices?.[0]?.message?.content;
  if (typeof content !== "string") throw new Error("LLM returned an invalid contract");
  return validateIngestionNotes(JSON.parse(content).notes);
}
async function processOne(client: SupabaseClient, job: Job,requestId:string): Promise<void> {
  const heartbeat=setInterval(()=>void client.from('ai_ingestion_jobs').update({heartbeat_at:new Date().toISOString()}).eq('id',job.job_id).eq('status','processing'),15_000);
  try {
    const { data: allowed, error: quotaError } = await client.rpc("consume_user_quota", { p_user_id: job.user_id, p_service: "ai_ingest", p_cost_units: 1 });
    if (quotaError || allowed !== true) throw new Error("QUOTA_EXCEEDED");
    const notes = await generateNotes(await sourceText(job, client));
    const { data:updated,error } = await client.from('ai_ingestion_jobs').update({result_draft:notes,status:'awaiting_review',notes_generated_count:notes.length,cards_generated_count:notes.reduce((sum,note)=>sum+note.cards.length,0),heartbeat_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq('id',job.job_id).eq('user_id',job.user_id).eq('status','processing').select('id');
    if (error) throw new Error("AI_DRAFT_PERSIST_FAILED");
    if(updated?.length)capturePostHogEvent({distinctId:job.user_id,event:"ai_job_suggestions_ready",properties:{user_id:job.user_id,job_id:job.job_id,request_id:requestId,function_name:"ai-ingest-worker",notes_generated:notes.length,cards_generated:notes.reduce((sum,n)=>sum+n.cards.length,0)}});
  } catch (error) {
    const raw=error instanceof Error?error.message:"";
    const message=/^(AI_|QUOTA_|PDF_)[A-Z_]+$/.test(raw)?raw:/^LLM provider returned HTTP \d{3}$/.test(raw)?raw:"AI_WORKER_FAILED";
    captureException(error,{functionName:"ai-ingest-worker",requestId,userId:job.user_id,tags:{error_code:message},extra:{job_id:job.job_id}});
    capturePostHogEvent({distinctId:job.user_id,event:"ai_job_failed",properties:{job_id:job.job_id,user_id:job.user_id,request_id:requestId,error_code:message,function_name:"ai-ingest-worker"}});
    await client.from("ai_ingestion_jobs").update({ status: "failed", error_message: message, updated_at: new Date().toISOString() }).eq("id", job.job_id).eq("status", "processing");
    throw error;
  } finally { clearInterval(heartbeat); }
}
function jwtRole(request: Request): string | null {
  const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/, "");
  if (!token) return null;
  try { const payload = JSON.parse(atob(token.split(".")[1] ?? "")) as { role?: string }; return payload.role ?? null; } catch { return null; }
}
Deno.serve(withObservability("ai-ingest-worker", async (request) => {
  const preflight = handleCors(request);
  const corsHeaders=getCorsHeaders(request);
  if (preflight) return preflight;
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  if (jwtRole(request) !== "service_role" || (Deno.env.get("INGESTION_WORKER_SECRET") && request.headers.get("x-worker-secret") !== Deno.env.get("INGESTION_WORKER_SECRET"))) return handleError(new RequestError("Worker authentication required",401,"WORKER_UNAUTHORIZED"),request,"ai-ingest-worker");
  const client = admin(request);
  const body=await request.json().catch(()=>({})) as {job_id?:string};
  const {data,error}=body.job_id?await client.rpc('claim_ai_ingestion_job_by_id',{p_job_id:body.job_id}):await client.rpc('claim_ai_ingestion_job');
  if (error) return new Response(JSON.stringify({ error: "claim failed" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  if (!data?.[0]) return new Response(JSON.stringify({ status: "idle" }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  const job = data[0] as Job;
  const task = processOne(client, job,request.headers.get("x-request-id")??crypto.randomUUID());
  const runtime=(globalThis as any).EdgeRuntime;
  if (runtime?.waitUntil) {
    runtime.waitUntil(task.catch(()=>undefined));
    return new Response(JSON.stringify({ status: "accepted", job_id: job.job_id }), { status: 202, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
  try { await task; return new Response(JSON.stringify({ status: "completed", job_id: job.job_id }), { headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
  catch { return new Response(JSON.stringify({ status: "failed", job_id: job.job_id }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
}));
