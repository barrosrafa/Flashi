import { createObservedFetch, fetchWithObservability, withObservability } from "../_shared/observability.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { load } from "npm:cheerio@1.0.0";
import { corsHeaders, handleCorsPreflight, secureDeterministicFetch } from "../_shared/security.ts";

type Job = { job_id: string; user_id: string; deck_id: string; source_type: string; source_reference: string | null };
type Card = { fields: Record<string, string>; card_kind: "basic" | "reverse" | "cloze"; card_ordinal: number; cloze_ordinal?: number | null };
type Note = { fields: Record<string, string>; cards: Card[] };

const MAX_PDF_BYTES = 15 * 1024 * 1024;
const MAX_SOURCE_CHARS = 250_000;
const MAX_WEB_BYTES = 600_000;
const BUCKET = Deno.env.get("INGESTION_BUCKET") ?? "import-media";

function required(name: string): string { const value = Deno.env.get(name); if (!value) throw new Error(`Missing ${name}`); return value; }
function admin(request: Request): SupabaseClient { return createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), { global: { fetch: createObservedFetch({ dependency: "supabase-admin", functionName: "ai-ingest-worker", requestId: request.headers.get("x-request-id") ?? undefined }) }, auth: { persistSession: false } }); }
function safeStoragePath(path: string, userId: string): void {
  if (!path || path.startsWith("/") || path.includes("..") || !path.startsWith(`${userId}/`)) throw new Error("Invalid storage path");
}
function validateNotes(value: unknown): Note[] {
  if (!Array.isArray(value) || value.length === 0) throw new Error("LLM returned no notes");
  return value.map((raw, index) => {
    const note = raw as Note;
    if (!note.fields || typeof note.fields !== "object" || Object.keys(note.fields).length === 0) throw new Error(`Note ${index} has empty fields`);
    if (!Array.isArray(note.cards) || note.cards.length === 0) throw new Error(`Note ${index} has no cards`);
    const ordinals = new Set<number>();
    const cards = note.cards.map((card, cardIndex) => {
      if (!card.fields || typeof card.fields !== "object" || Object.keys(card.fields).length === 0) throw new Error(`Card ${index}/${cardIndex} has empty fields`);
      if (!(["basic", "reverse", "cloze"] as string[]).includes(card.card_kind)) throw new Error("Invalid card_kind");
      if (!Number.isInteger(card.card_ordinal) || card.card_ordinal < 0 || ordinals.has(card.card_ordinal)) throw new Error(`Duplicate card_ordinal in note ${index}`);
      ordinals.add(card.card_ordinal);
      return card;
    });
    return { fields: note.fields, cards };
  });
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
  const parser = await import("npm:pdf-parse@1.1.1") as unknown as (input: Uint8Array) => Promise<{ text: string }>;
  const parsed = await parser(new Uint8Array(await data.arrayBuffer()));
  return parsed.text.replace(/\s+/g, " ").trim().slice(0, MAX_SOURCE_CHARS);
}
async function generateNotes(text: string): Promise<Note[]> {
  const key = required("OPENAI_API_KEY");
  const base = Deno.env.get("OPENAI_API_BASE") ?? "https://api.openai.com/v1";
  const response = await fetchWithObservability(`${base}/chat/completions`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` }, body: JSON.stringify({
    model: Deno.env.get("INGESTION_MODEL") ?? "gpt-4o-mini", temperature: 0,
    messages: [{ role: "system", content: "Transforme o texto em notas de estudo. Responda apenas no schema fornecido; crie campos e cartões úteis e não invente conteúdo." }, { role: "user", content: text }],
    response_format: { type: "json_schema", json_schema: { name: "flashi_ingestion", strict: true, schema: { type: "object", additionalProperties: false, properties: { notes: { type: "array", items: { type: "object", additionalProperties: false, properties: { fields: { type: "object", additionalProperties: { type: "string" } }, cards: { type: "array", items: { type: "object", additionalProperties: false, properties: { fields: { type: "object", additionalProperties: { type: "string" } }, card_kind: { type: "string", enum: ["basic", "reverse", "cloze"] }, card_ordinal: { type: "integer", minimum: 0 }, cloze_ordinal: { type: ["integer", "null"] } }, required: ["fields", "card_kind", "card_ordinal", "cloze_ordinal"] } } }, required: ["fields", "cards"] } } }, required: ["notes"] } } },
  }) }, { dependency: "llm-ingestion" });
  if (!response.ok) throw new Error(`LLM provider returned HTTP ${response.status}`);
  const body = await response.json(); const content = body.choices?.[0]?.message?.content;
  if (typeof content !== "string") throw new Error("LLM returned an invalid contract");
  return validateNotes(JSON.parse(content).notes);
}
async function processOne(client: SupabaseClient, job: Job): Promise<void> {
  try {
    const { data: allowed, error: quotaError } = await client.rpc("consume_user_quota", { p_user_id: job.user_id, p_service: "ai_ingest", p_cost_units: 1 });
    if (quotaError || allowed !== true) throw new Error("QUOTA_EXCEEDED");
    const notes = await generateNotes(await sourceText(job, client));
    const { error } = await client.rpc("materialize_ai_ingestion_batch", { p_job_id: job.job_id, p_user_id: job.user_id, p_deck_id: job.deck_id, p_notes: notes });
    if (error) throw new Error(error.message);
  } catch (error) {
    const message = error instanceof Error ? error.message.slice(0, 500) : "Worker failed";
    await client.from("ai_ingestion_jobs").update({ status: "failed", error_message: message, updated_at: new Date().toISOString() }).eq("id", job.job_id).eq("status", "processing");
    throw error;
  }
}
function jwtRole(request: Request): string | null {
  const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/, "");
  if (!token) return null;
  try { const payload = JSON.parse(atob(token.split(".")[1] ?? "")) as { role?: string }; return payload.role ?? null; } catch { return null; }
}
Deno.serve(withObservability("ai-ingest-worker", async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  if (jwtRole(request) !== "service_role" || request.headers.get("x-worker-secret") !== Deno.env.get("INGESTION_WORKER_SECRET")) return new Response("Unauthorized", { status: 401, headers: corsHeaders });
  const client = admin(request);
  const { data, error } = await client.rpc("claim_ai_ingestion_job");
  if (error) return new Response(JSON.stringify({ error: "claim failed" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  if (!data?.[0]) return new Response(JSON.stringify({ status: "idle" }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  const job = data[0] as Job;
  const task = processOne(client, job);
  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime.waitUntil) {
    EdgeRuntime.waitUntil(task);
    return new Response(JSON.stringify({ status: "accepted", job_id: job.job_id }), { status: 202, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
  try { await task; return new Response(JSON.stringify({ status: "completed", job_id: job.job_id }), { headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
  catch { return new Response(JSON.stringify({ status: "failed", job_id: job.job_id }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
}));
