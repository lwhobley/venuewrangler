// Shared CORS headers for Edge Functions called directly from the Flutter app (not via a
// browser page, but supabase-js's fetch transport still sends a preflight for non-simple
// requests such as our POST + Authorization + Content-Type combination).
export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function handleCorsPreflight(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  return null;
}
