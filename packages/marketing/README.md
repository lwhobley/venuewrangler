# Venue Wrangler marketing

Typed React + Vite landing page with Tailwind CSS, Lucide icons, and Framer Motion.

- `npm run dev:marketing` starts the local development server.
- `npm run build:marketing` type-checks and generates `site/index.html` and `site/marketing-assets/`.
- `npm run build:site` builds this page and the Expo web client into `dist-site` for deployment.

Serve the generated site over HTTP; ES modules are not intended to run through a `file://` URL. Edit `src/`, not the generated bundles.

Dashboard values are illustrative. Provider availability is qualified, and trial or setup-time promises must be confirmed before adding them to the copy. The tour uses the existing local video. The two-field form passes a session-only draft to `site/start/index.html`; that page retains the existing email-verified account and venue creation flow. No marketing build reads `.env.local`.
