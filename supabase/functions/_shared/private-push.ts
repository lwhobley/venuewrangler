// Transport alerts can outlive a sign-out while a device is offline. Keep all
// account-specific content in the RLS-protected inbox, never on the lock screen.
export const privatePushAlert = {
  title: "Venue Wrangler",
  body: "You have new activity. Open the app to view it.",
  data: { kind: "general" },
};
