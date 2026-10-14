import { privatePushAlert } from "./private-push.ts";

Deno.test("device alerts carry no account content or routing identifiers", () => {
  if (JSON.stringify(privatePushAlert) !== JSON.stringify({
    title: "Venue Wrangler",
    body: "You have new activity. Open the app to view it.",
    data: { kind: "general" },
  })) throw new Error("Transport alert must remain generic on shared devices");
});
