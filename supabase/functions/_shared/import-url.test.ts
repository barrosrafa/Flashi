import { downloadImportUrl, readBoundedResponse } from "./import-url.ts";

Deno.test("URL import rejects insecure schemes, private destinations and nonstandard ports", async () => {
  for (
    const url of [
      "http://example.com/cards.csv",
      "https://127.0.0.1/private.csv",
      "https://localhost/private.csv",
      "https://user:pass@example.com/cards.csv",
      "https://example.com:8443/cards.csv",
    ]
  ) {
    let rejected = false;
    try {
      await downloadImportUrl(url);
    } catch (error) {
      rejected = error instanceof Error;
    }
    if (!rejected) throw new Error(`Expected URL to be rejected: ${url}`);
  }
});

Deno.test("bounded response enforces limit without relying on Content-Length", async () => {
  const response = new Response(new Uint8Array([1, 2, 3]));
  let rejected = false;
  try {
    await readBoundedResponse(response, 2);
  } catch (error) {
    rejected = error instanceof Error &&
      error.message.includes("exceeds 15 MiB");
  }
  if (!rejected) throw new Error("Expected oversize response to be rejected");
});
