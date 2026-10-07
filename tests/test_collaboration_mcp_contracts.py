from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (ROOT / "0028_collaboration_invites.sql").read_text(encoding="utf-8")
FRONTEND_CLIENT = Path("/home/ubuntu/work/frontend/lib/services/mcp-client.ts")


class CollaborationInviteContracts(unittest.TestCase):
    def test_invite_is_owner_authorized_short_lived_and_one_time(self):
        self.assertIn("create_deck_collaboration_invite", MIGRATION)
        self.assertIn("and d.user_id = v_user_id", MIGRATION)
        self.assertIn("token_hash text not null unique", MIGRATION)
        self.assertIn("extensions.digest(v_token, 'sha256')", MIGRATION)
        self.assertIn("expires_at <= created_at + interval '24 hours'", MIGRATION)
        self.assertIn("used_at is null", MIGRATION)
        self.assertIn("set used_at = now(), used_by = v_user_id", MIGRATION)
        self.assertIn("on conflict (deck_id, user_id) do update", MIGRATION)
        self.assertIn("COLLABORATION_INVITE_INVALID_OR_EXPIRED", MIGRATION)

    def test_creation_does_not_enumerate_email_accounts_or_send_email(self):
        creation = MIGRATION.split("create or replace function public.create_deck_collaboration_invite", 1)[1]
        creation = creation.split("create or replace function public.accept_deck_collaboration_invite", 1)[0]
        self.assertNotIn("from auth.users", creation.lower())
        self.assertIn("never resolves or discloses email existence", MIGRATION)
        self.assertIn("pending_copy", MIGRATION)
        self.assertIn("No email is sent by this RPC", MIGRATION)

    def test_invite_table_has_no_direct_mutation_grant(self):
        self.assertIn("alter table public.deck_collaboration_invites enable row level security", MIGRATION)
        self.assertIn("revoke all on table public.deck_collaboration_invites from public, anon, authenticated", MIGRATION)
        self.assertIn("deck_collaboration_invites_owner_read", MIGRATION)
        self.assertIn("grant execute on function public.create_deck_collaboration_invite", MIGRATION)
        self.assertIn("grant execute on function public.accept_deck_collaboration_invite", MIGRATION)


class ExternalMcpBoundaryContracts(unittest.TestCase):
    def test_client_contains_real_handshake_and_safe_transport_boundary(self):
        source = FRONTEND_CLIENT.read_text(encoding="utf-8")
        for fragment in (
            "validateMcpEndpoint",
            "MCP_ENDPOINT_HTTPS_REQUIRED",
            "MCP_ENDPOINT_PRIVATE_HOST",
            "AbortController",
            "authorization: `Bearer ${this.token}`",
            "this.request('initialize'",
            "this.request('notifications/initialized'",
            "this.request('tools/list'",
            "MCP_EXTERNAL_TIMEOUT",
            "MCP_EXTERNAL_HTTP_ERROR",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, source)
        self.assertNotIn("console.log", source)
        self.assertNotIn("console.error", source)


if __name__ == "__main__":
    unittest.main()
