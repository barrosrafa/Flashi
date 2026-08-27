import { RequestError } from "./http.ts";

export const MODEL = Deno.env.get("EMBEDDING_MODEL") ?? "text-embedding-3-small";
export const DIMENSIONS = 1536;
const MAX_ATTEMPTS = 3;

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new RequestError(`${name} is not configured`, 503, "PROVIDER_UNAVAILABLE");
  return value;
}

export async function requestEmbedding(input: string): Promise<number[]> {
  let lastStatus = 0;
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const response = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: { Authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: MODEL, input, encoding_format: "float" }),
      signal: AbortSignal.timeout(30_000),
    });
    lastStatus = response.status;
    if (response.ok) {
      const payload = await response.json() as { data?: Array<{ embedding?: unknown }> };
      const embedding = payload.data?.[0]?.embedding;
      if (!Array.isArray(embedding) || embedding.length !== DIMENSIONS) throw new Error(`Embedding dimension mismatch for ${MODEL}`);
      const numericEmbedding = embedding.map(Number);
      if (numericEmbedding.some((value) => !Number.isFinite(value))) throw new Error("Embedding contains non-finite values");
      return numericEmbedding;
    }
    if (response.status !== 429 && response.status < 500) break;
    if (attempt < MAX_ATTEMPTS - 1) await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** attempt));
  }
  throw new RequestError(`Embedding provider returned HTTP ${lastStatus}`, lastStatus === 429 ? 429 : 503, lastStatus === 429 ? "RATE_LIMITED" : "PROVIDER_UNAVAILABLE");
}
