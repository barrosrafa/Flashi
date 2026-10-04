import { getCorsHeaders, handleCors } from "./http.ts";

function equal(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(
      `${message}: got ${String(actual)}, expected ${String(expected)}`,
    );
  }
}

Deno.test("CORS combines exact preview origins with the existing allowlist", () => {
  const names = ["ALLOWED_ORIGINS", "PREVIEW_ALLOWED_ORIGINS"] as const;
  const previous = new Map(names.map((name) => [name, Deno.env.get(name)]));

  try {
    Deno.env.set(
      "ALLOWED_ORIGINS",
      "https://app.example.com, https://admin.example.com",
    );
    Deno.env.set("PREVIEW_ALLOWED_ORIGINS", "https://preview.example.com");

    const previewRequest = new Request("https://functions.example.com/sync", {
      method: "OPTIONS",
      headers: { Origin: "https://preview.example.com" },
    });
    const previewResponse = handleCors(previewRequest);
    equal(previewResponse?.status, 204, "preflight status");
    equal(
      previewResponse?.headers.get("Access-Control-Allow-Origin"),
      "https://preview.example.com",
      "preview allow-origin",
    );

    const existingRequest = new Request("https://functions.example.com/sync", {
      headers: { Origin: "https://app.example.com" },
    });
    equal(
      getCorsHeaders(existingRequest)["Access-Control-Allow-Origin"],
      "https://app.example.com",
      "existing allow-origin remains enabled",
    );

    const unlistedRequest = new Request("https://functions.example.com/sync", {
      headers: { Origin: "https://preview.example.com.attacker.test" },
    });
    equal(
      getCorsHeaders(unlistedRequest)["Access-Control-Allow-Origin"],
      undefined,
      "non-exact origin is rejected",
    );
  } finally {
    for (const name of names) {
      const value = previous.get(name);
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
});
