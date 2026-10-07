import { RequestError } from "./http.ts";

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, idempotency-key, traceparent, x-request-id, x-worker-secret",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

export function handleCorsPreflight(request: Request): Response | null {
  return request.method === "OPTIONS" ? new Response(null, { status: 204, headers: corsHeaders }) : null;
}

function blockedIpv4(value: string): boolean {
  const p = value.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return true;
  const [a = 0, b = 0, c = 0] = p;
  return a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) || (a === 192 && (b === 0 || b === 168)) ||
    (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100)));
}

function blockedIpv6(value: string): boolean {
  const normalized = value.toLowerCase().replace(/^\[|\]$/g, "");
  if (normalized === "::1" || normalized === "::" || normalized.startsWith("fc") || normalized.startsWith("fd") || normalized.startsWith("fe8") || normalized.startsWith("fe9") || normalized.startsWith("fea") || normalized.startsWith("feb")) return true;
  if (normalized.startsWith("::ffff:")) {
    const tail = normalized.slice(7);
    return tail.includes(".") ? blockedIpv4(tail) : blockedIpv6(tail);
  }
  const first = Number.parseInt(normalized.split(":")[0] || "0", 16);
  return !Number.isFinite(first) || (first & 0xe000) !== 0x2000 || normalized.startsWith("2001:db8:");
}

function blockedAddress(value: string): boolean {
  return value.includes(":") ? blockedIpv6(value) : blockedIpv4(value);
}

async function assertPublicHost(hostname: string): Promise<void> {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  if (!host || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal") || host === "metadata.google.internal") throw new RequestError("URL host is not allowed", 400);
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(host) && blockedIpv4(host)) throw new RequestError("URL host is not allowed", 400);
  let addresses: string[] = [];
  try {
    const [a, aaaa] = await Promise.all([Deno.resolveDns(host, "A"), Deno.resolveDns(host, "AAAA")]);
    addresses = [...a, ...aaaa];
  } catch { throw new RequestError("URL host could not be resolved", 422); }
  if (!addresses.length || addresses.some(blockedAddress)) throw new RequestError("URL host must resolve only to public addresses", 400);
}

export async function secureDeterministicFetch(target: string, init: RequestInit = {}): Promise<Response> {
  let url: URL;
  try { url = new URL(target); } catch { throw new RequestError("URL is invalid", 400); }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || (url.port && !["80", "443"].includes(url.port))) throw new RequestError("Only public HTTP(S) URLs without credentials are allowed", 400);
  await assertPublicHost(url.hostname);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);
  try { return await fetch(url, { ...init, signal: controller.signal, redirect: "error" }); }
  catch (error) { throw new RequestError(`Secure external fetch failed: ${error instanceof Error ? error.message : "network error"}`, 502); }
  finally { clearTimeout(timeout); }
}
