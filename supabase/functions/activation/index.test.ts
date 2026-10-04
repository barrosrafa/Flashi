Deno.test('activation preserves SDD safety contracts', async () => {
  const source = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  for (const fragment of ['idempotency-key', 'sha256Hex', 'process_activation', 'requireUserId', 'capturePostHogEvent', 'X-Request-Id']) {
    if (!source.includes(fragment)) throw new Error(`missing activation contract: ${fragment}`);
  }
});
