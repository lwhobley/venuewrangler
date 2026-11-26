/// Roles that may use the free-text "Ask Wrangler" assistant (`wrangler_ask`): venue managers
/// and organization admins/owners. The `ai-assistant` Edge Function answers 403
/// `not_a_venue_manager` for anyone else; this only decides what the app shows.
const wranglerAssistantRoles = {
  'venue_manager',
  'organization_admin',
  'organization_owner',
};

/// Whether [role] may open the assistant. Unknown or missing roles are refused.
bool canUseWranglerAssistant(String? role) =>
    wranglerAssistantRoles.contains(role);

const wranglerManagersOnlyMessage =
    'Ask Wrangler is available to venue managers and organization admins only.';
