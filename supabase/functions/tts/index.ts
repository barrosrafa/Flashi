import { fetchWithObservability, withObservability } from "../_shared/observability.ts";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  errorResponse,
  getCorsHeaders,
  handleCors,
  handleError,
  requireString,
  RequestError,
  sha256Hex,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";

const CACHE_BUCKET = "tts_cache";
const MAX_TEXT_LENGTH = 5_000;
const DEFAULT_VOICE = "pt-BR-Neural";

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function adminClient(request: Request): SupabaseClient {
  return createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), {
    global: { fetch: createObservedFetch({ dependency: "supabase-admin", functionName: "tts", requestId: request.headers.get("x-request-id") ?? undefined }) },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function readRequestInput(request: Request): Promise<{ text: string; voiceId: string }> {
  const url = new URL(request.url);
  let text = url.searchParams.get("text") ?? "";
  let voiceId = url.searchParams.get("voiceId") ?? DEFAULT_VOICE;
  if (request.method === "POST" && request.headers.get("content-type")?.includes("application/json")) {
    const body = await request.json() as { text?: unknown; voiceId?: unknown };
    if (body.text !== undefined) text = typeof body.text === "string" ? body.text : "";
    if (body.voiceId !== undefined) voiceId = typeof body.voiceId === "string" ? body.voiceId : "";
  }
  return {
    text: requireString(text, "text", { maxLength: MAX_TEXT_LENGTH }),
    voiceId: requireString(voiceId, "voiceId", { maxLength: 120 }),
  };
}

async function cachedAudio(client: SupabaseClient, fileName: string): Promise<Response | null> {
  const { data, error } = await client.storage.from(CACHE_BUCKET).createSignedUrl(fileName, 3_600);
  if (error || !data?.signedUrl) return null;
  const response = await fetchWithObservability(data.signedUrl, undefined, { dependency: "tts-cache" });
  return response.ok ? response : null;
}

Deno.serve(withObservability("tts", async (request) => {
  const cors = handleCors(request);
  if (cors) return cors;
  if (request.method !== "GET" && request.method !== "POST") return errorResponse(request, "Method not allowed", 405, "METHOD_NOT_ALLOWED");

  try {
    const userClient = createUserClient(request);
    await requireUserId(userClient);
    const { text, voiceId } = await readRequestInput(request);
    if (!/^[A-Za-z0-9._-]+$/.test(voiceId)) throw new RequestError("voiceId contains unsupported characters", 400);

    const admin = adminClient(request);
    const fileName = `${await sha256Hex(JSON.stringify({ text, voiceId }))}.mp3`;
    const cached = await cachedAudio(admin, fileName);
    if (cached) {
      return new Response(cached.body, {
        status: 200,
        headers: { ...getCorsHeaders(request), "Content-Type": "audio/mpeg", "X-Cache": "HIT" },
      });
    }

    const providerKey = Deno.env.get("ELEVENLABS_API_KEY");
    if (!providerKey) throw new RequestError("TTS provider is not configured", 503, "PROVIDER_UNAVAILABLE");
    const provider = await fetchWithObservability(`https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}/stream`, {
      method: "POST",
      headers: { Accept: "audio/mpeg", "xi-api-key": providerKey, "Content-Type": "application/json" },
      body: JSON.stringify({ text, model_id: "eleven_multilingual_v2" }),
    }, { dependency: "elevenlabs-tts" });
    if (!provider.ok) {
      const status = provider.status === 429 ? 429 : 502;
      throw new RequestError("TTS provider request failed", status, status === 429 ? "RATE_LIMITED" : "PROVIDER_UNAVAILABLE");
    }

    const audio = await provider.arrayBuffer();
    const runtime = (globalThis as typeof globalThis & { EdgeRuntime?: { waitUntil(promise: Promise<unknown>): void } }).EdgeRuntime;
    runtime?.waitUntil(admin.storage.from(CACHE_BUCKET).upload(fileName, audio, {
      contentType: "audio/mpeg",
      upsert: true,
    }));
    return new Response(audio, {
      status: 200,
      headers: { ...getCorsHeaders(request), "Content-Type": "audio/mpeg", "X-Cache": "MISS" },
    });
  } catch (error) {
    return handleError(error, request, "tts");
  }
}));
