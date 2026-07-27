import { useUserProfileQuery } from "@/features/profile/hooks";
import { UserProfilePopover } from "@/features/profile/ui/UserProfilePopover";
import { truncatePubkey } from "@/shared/lib/pubkey";
import { InlineChip } from "@/shared/ui/InlineChip";

/**
 * Chip for a NIP-27 `nostr:npub…`/`nostr:nprofile…` profile reference
 * (see `remarkNostrMentions`). Unlike Buzz's plaintext `@Name` mentions —
 * resolved name→pubkey from the message's `p` tags — this starts from the
 * decoded pubkey and resolves the display name from the profile store,
 * falling back to a truncated pubkey while it loads or when unknown.
 */
export function NostrMentionChip({
  interactive,
  pubkey,
}: {
  interactive: boolean;
  pubkey?: string;
}) {
  const profile = useUserProfileQuery(pubkey);
  if (!pubkey) {
    return null;
  }
  const label = profile.data?.displayName?.trim() || truncatePubkey(pubkey);
  const chip = (
    <InlineChip data-mention="" icon="human" interactive={interactive}>
      {label}
    </InlineChip>
  );

  return interactive ? (
    <UserProfilePopover
      botIdenticonValue={label}
      pubkey={pubkey}
      triggerElement="span"
    >
      {chip}
    </UserProfilePopover>
  ) : (
    chip
  );
}
