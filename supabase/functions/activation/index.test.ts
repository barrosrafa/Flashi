Deno.test('activation preserves SDD safety contracts', async () => {
  const source = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  for (const fragment of ['idempotency-key', 'sha256Hex', 'process_activation', 'requireUserId', 'capturePostHogEvent', 'X-Request-Id']) {
    if (!source.includes(fragment)) throw new Error(`missing activation contract: ${fragment}`);
  }
});

Deno.test('activation uses the deployed rate-limit RPC contract', async () => {
  const source = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  for (const fragment of [
    'enforceUserRateLimit(client, "activation-short", 10, 10)',
    'enforceUserRateLimit(client, "activation-sustained", 60, 60)',
  ]) {
    if (!source.includes(fragment)) throw new Error(`missing rate-limit contract: ${fragment}`);
  }
  if (source.includes('p_scope')) throw new Error('activation must not call consume_user_rate_limit with p_scope');
});
