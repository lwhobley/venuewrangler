/**
 * Membership rule for chat conversations, shared by the Chat controller and by
 * every other surface that can surface a message (Wrangler's SEARCH_CHAT, for
 * one). Venue scope alone is not access: a manager is not a participant in a
 * private staff conversation, and reading it through a side channel is the same
 * disclosure the Chat screen already refuses.
 */
export function canAccessConversation(memberIds: string[], type: string, profileId: string) {
  if (type === 'dm') {
    return memberIds.includes(profileId);
  }
  // Deny empty membership lists — until ensureContextualConversations
  // repopulates members, nobody (including managers) can read/send. Prefer a
  // brief access gap over an open venue-wide conversation.
  if (memberIds.length === 0) return false;
  if (type === 'group' || type === 'role' || type === 'shift') {
    return memberIds.includes(profileId);
  }
  return false;
}
