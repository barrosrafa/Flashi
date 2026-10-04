import { RequestError } from "./http.ts";

export const MAX_IMPORT_BYTES = 15 * 1024 * 1024;
const MAX_REDIRECTS = 3;
const FETCH_TIMEOUT_MS = 20_000;

function isBlockedIpv4(address: string): boolean {
  const values = address.split(".").map(Number);
  if (
    values.length !== 4 ||
    values.some((part) => !Number.isInteger(part) || part < 0 || part > 255)
  ) return true;
  const [a = Number.NaN, b = Number.NaN, c = Number.NaN] = values;
  return a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 &&
      (b === 168 || (b === 0 && (c ?? 0) === 0) || (b === 0 && c === 2) ||
        (b === 88 && c === 99))) ||
    (a === 198 && ((b ?? 0) === 18 || b === 19 || b === 51 && c === 100)) ||
    (a === 203 && b === 0 && c === 113);
}

function isBlockedIpv6(address: string): boolean {
  const normalized = address.toLowerCase().replace(/^\[|\]$/g, "");
  const first = Number.parseInt(normalized.split(":")[0] || "0", 16);
  // Only globally routable 2000::/3 is accepted; block special/documentation/tunnel ranges too.
  return !Number.isFinite(first) || (first & 0xe000) !== 0x2000 ||
    normalized.startsWith("2001:db8:") || normalized.startsWith("2002:") ||
    normalized.startsWith("64:ff9b:");
}

function isIpLiteral(host: string): boolean {
  return host.startsWith("[") || host.includes(":") ||
    /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host);
}

async function validatePublicHttpsUrl(rawUrl: string): Promise<URL> {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new RequestError("URL is invalid", 400);
  }
  if (url.protocol !== "https:") {
    throw new RequestError("Import URL must use HTTPS", 400);
  }
  if (url.username || url.password) {
    throw new RequestError("Credentials in URLs are not allowed", 400);
  }
  if (url.port && url.port !== "443") {
    throw new RequestError("Only the standard HTTPS port is allowed", 400);
  }

  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (
    !host || isIpLiteral(host) || host === "localhost" ||
    host.endsWith(".localhost") || host.endsWith(".local") ||
    host.endsWith(".internal")
  ) {
    throw new RequestError("URL host is not allowed", 400);
  }

  const answers = await Promise.all(["A", "AAAA"].map(async (type) => {
    try {
      return await Deno.resolveDns(host, type as "A" | "AAAA");
    } catch {
      return [];
    }
  }));
  const addresses = answers.flat();
  if (addresses.length === 0) {
    throw new RequestError("URL host could not be resolved", 422);
  }
  if (
    addresses.some((address) =>
      address.includes(":") ? isBlockedIpv6(address) : isBlockedIpv4(address)
    )
  ) {
    throw new RequestError(
      "URL host must resolve only to public addresses",
      400,
    );
  }
  return url;
}

export async function readBoundedResponse(
  response: Response,
  maxBytes = MAX_IMPORT_BYTES,
): Promise<Uint8Array> {
  const contentLength = Number(response.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new RequestError("Import file exceeds 15 MiB", 413);
  }
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw new RequestError("Import file exceeds 15 MiB", 413);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export async function downloadImportUrl(
  rawUrl: string,
): Promise<{ bytes: Uint8Array; contentType: string }> {
  let current = rawUrl;
  for (
    let redirectCount = 0;
    redirectCount <= MAX_REDIRECTS;
    redirectCount += 1
  ) {
    const url = await validatePublicHttpsUrl(current);
    let response: Response;
    try {
      response = await fetch(url, {
        redirect: "manual",
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
        headers: { "User-Agent": "FlashiImport/1.0" },
      });
    } catch {
      throw new RequestError("Unable to download the import URL", 502);
    }
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      await response.body?.cancel();
      if (!location || redirectCount === MAX_REDIRECTS) {
        throw new RequestError("Import URL has too many redirects", 422);
      }
      try {
        current = new URL(location, url).toString();
      } catch {
        throw new RequestError("Import URL redirect is invalid", 422);
      }
      continue;
    }
    if (!response.ok) {
      throw new RequestError(
        `Import URL returned HTTP ${response.status}`,
        422,
      );
    }
    const contentType =
      response.headers.get("content-type")?.split(";", 1)[0]?.trim()
        .toLowerCase() ?? "";
    const bytes = await readBoundedResponse(response);
    if (bytes.byteLength === 0) {
      throw new RequestError("Import URL returned an empty file", 422);
    }
    return { bytes, contentType };
  }
  throw new RequestError("Import URL has too many redirects", 422);
}
