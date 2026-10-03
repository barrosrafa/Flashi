import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.112.4";
import { assert, assertEquals } from "jsr:@std/assert@1.0.14";

const url = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const emailA = Deno.env.get("TEST_USER_A_EMAIL");
const passwordA = Deno.env.get("TEST_USER_A_PASSWORD");
const emailB = Deno.env.get("TEST_USER_B_EMAIL");
const passwordB = Deno.env.get("TEST_USER_B_PASSWORD");

function configured(): boolean { return [url, anonKey, emailA, passwordA, emailB, passwordB].every(Boolean); }
async function login(email: string, password: string): Promise<SupabaseClient> {
  const client = createClient(url!, anonKey!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await client.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return client;
}

Deno.test("RLS bloqueia leitura e escrita cross-user", async () => {
  if (!configured()) { console.warn("SKIP: configure SUPABASE_URL, SUPABASE_ANON_KEY and TEST_USER_{A,B}_{EMAIL,PASSWORD}"); return; }
  const userA = await login(emailA!, passwordA!); const userB = await login(emailB!, passwordB!);
  const { data: profile } = await userA.auth.getUser(); assert(profile.user);
  const { data: deck, error: deckError } = await userA.from("decks").insert({ user_id: profile.user.id, name: `RLS test ${crypto.randomUUID()}` }).select("id").single();
  if (deckError) throw deckError; assert(deck);
  const { data: hidden, error: readError } = await userB.from("decks").select("id").eq("id", deck.id);
  if (readError) throw readError; assertEquals(hidden?.length ?? 0, 0);
  const { data: changed, error: updateError } = await userB.from("decks").update({ name: "hacked" }).eq("id", deck.id).select("id");
  if (updateError) throw updateError; assertEquals(changed?.length ?? 0, 0);
  const { error: reviewError } = await userB.from("review_logs").insert({ user_id: profile.user.id, card_id: crypto.randomUUID(), rating: "good", new_state: "review", new_due_at: new Date().toISOString(), algorithm: "fsrs" });
  assert(reviewError, "RLS must reject a cross-user review insert");
  await userA.from("decks").delete().eq("id", deck.id);
});
