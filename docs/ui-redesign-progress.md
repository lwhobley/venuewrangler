# UI redesign verification — September 22, 2026

The current direction pairs warm surfaces and Fraunces page headings with native sans-serif operational data. The earlier glass/cyberpunk concept document is historical, not the implementation target.

## Implemented

- Four role-aware primary mobile destinations plus a More disclosure. The disclosure uses the navigator's visible routes, preserving role restrictions and access to secondary tools.
- Desktop navigation grouped by workflow.
- Tonight header, contextual links, and collapsible Wrangler composer. Unknown or failed readiness is not labeled ready.
- Restaurant-only Home uses the same title treatment and compact metrics.
- Team roster precedes collapsed administrative tools. Form drafts survive collapse; selecting Edit opens the tools and scrolls to them.
- Schedule actions wrap at intermediate desktop widths. The wide calendar remains horizontally scrollable at all widths.

## Verification

TypeScript passed. The navigation, Team, Tonight, Home, and manager-calendar suites passed (39 tests), including a new navigation test that opens More, visits Clock, and checks that a role-hidden Reports route is absent.

The local Expo web server starts and the application reaches its welcome/sign-in screen in Chrome. No authenticated local session was available. Authenticated desktop/mobile screenshots, long-name wrapping, and touch interaction review remain unverified; unit tests do not establish visual quality.

No deployment has been performed.

## Mobile schedule agenda

The mobile manager planner now displays a seven-day selector and a daily agenda instead of the wide desktop grid. It shares overnight segmentation with the grid, opens the original shift for editing when selecting a continuation, and adds new shifts to the selected day. Previous-week carry-ins are labeled and read-only; their source shift is outside the current week's editor data.

An isolated preview uses the real `ShiftAgenda` component and theme with clearly labeled sample records. Start it with `npx vite --config scripts/ui-preview/vite.config.mts`, then open `http://127.0.0.1:5174`. It is outside Expo routes, does not load environment files, and does not call the API.

The populated agenda was visually reviewed in Chrome at 390 × 844. Day selection and overnight continuation were exercised in the browser. This verifies the component fixture, not the full authenticated application.
