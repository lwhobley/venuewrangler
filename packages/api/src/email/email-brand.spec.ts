import { describe, expect, it } from 'vitest';
import { BRAND, button, codeBlock, compareTable, h, infoTable, list, p, renderEmailHtml, strong } from './email-brand';

describe('email-brand', () => {
  describe('HTML escaping — every helper that accepts user-controlled text', () => {
    // Profile names, venue names, and job titles are all set by app users
    // (a manager naming a venue, a staff member's own name) and flow
    // straight into these builders. Verify none of them can inject markup.
    const hostile = `<script>alert(1)</script> & "quoted" 'stuff'`;
    const escaped = '&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quoted&quot; &#039;stuff&#039;';

    it('h() escapes its heading text', () => {
      expect(h(hostile)).toContain(escaped);
      expect(h(hostile)).not.toContain('<script>');
    });

    it('strong() escapes its content', () => {
      expect(strong(hostile)).toContain(escaped);
      expect(strong(hostile)).not.toContain('<script>');
    });

    it('button() escapes both label and url', () => {
      const out = button(hostile, hostile);
      expect(out).not.toContain('<script>');
      expect(out).toContain(escaped);
    });

    it('codeBlock() escapes the code value', () => {
      expect(codeBlock(hostile)).not.toContain('<script>');
    });

    it('infoTable() escapes every label and value', () => {
      const out = infoTable([['Name', hostile]]);
      expect(out).not.toContain('<script>');
      expect(out).toContain(escaped);
    });

    it('compareTable() escapes header and every cell', () => {
      const out = compareTable(['A', 'B', 'C'], [[hostile, hostile, hostile]]);
      expect(out).not.toContain('<script>');
    });

    it('list() escapes every item', () => {
      const out = list([hostile]);
      expect(out).not.toContain('<script>');
    });

    it('renderEmailHtml() escapes the heading and preheader', () => {
      const out = renderEmailHtml({ preheader: hostile, heading: hostile, bodyRows: p`safe` });
      expect(out).not.toContain('<script>');
    });

    it('p() escapes only its interpolated values, not the literal markup around them', () => {
      // This is the contract every template relies on: `p`Hi ${name}`` must
      // escape `name` (a real user's profile name) while still letting the
      // author write literal <strong> tags around it.
      const out = p`Hi ${hostile}, <strong>welcome</strong>`;
      expect(out).toContain(escaped);
      expect(out).not.toContain('<script>');
      expect(out).toContain('<strong>welcome</strong>');
    });
  });

  describe('renderEmailHtml — structural contract', () => {
    const html = renderEmailHtml({ preheader: 'Preview text', heading: 'Test heading', bodyRows: p`Body content` });

    it('is a complete, well-formed document', () => {
      expect(html).toMatch(/^<!doctype html>/i);
      expect(html).toContain('<html');
      expect(html).toContain('</html>');
      expect(html).toContain('<body');
      expect(html).toContain('</body>');
    });

    it('references the real, publicly-hosted logo with explicit dimensions', () => {
      expect(html).toContain(`src="${BRAND.logoUrl}"`);
      expect(html).toContain(`width="${BRAND.logoWidth}"`);
      expect(html).toContain(`height="${BRAND.logoHeight}"`);
      expect(html).toContain('alt="Venue Wrangler"');
    });

    it('carries the support contact in the footer', () => {
      expect(html).toContain(BRAND.supportEmail);
    });

    it('includes the preheader as hidden preview text', () => {
      expect(html).toMatch(/display:none[^>]*>Preview text/);
    });

    it('uses the danger accent color when accent is "danger"', () => {
      const dangerHtml = renderEmailHtml({ preheader: 'x', heading: 'x', bodyRows: p`x`, accent: 'danger' });
      expect(dangerHtml).toContain(BRAND.colors.danger);
    });

    it('defaults to the primary brand color', () => {
      expect(html).toContain(BRAND.colors.primary);
    });

    it('layout is table-based, not flex/grid, for Outlook compatibility', () => {
      expect(html).not.toMatch(/display:\s*flex/);
      expect(html).not.toMatch(/display:\s*grid/);
      expect(html).toMatch(/<table/);
    });

    it('uses <a> rather than <button> for links', () => {
      const withButton = renderEmailHtml({ preheader: 'x', heading: 'x', bodyRows: button('Click me', 'https://venuewrangler.com') });
      expect(withButton).not.toContain('<button');
      expect(withButton).toContain('<a href="https://venuewrangler.com"');
    });
  });

  describe('infoTable / compareTable — value rendering', () => {
    it('infoTable renders every row label and value', () => {
      const out = infoTable([
        ['Role', 'Manager'],
        ['Venue', 'Test Venue'],
      ]);
      expect(out).toContain('Role');
      expect(out).toContain('Manager');
      expect(out).toContain('Venue');
      expect(out).toContain('Test Venue');
    });

    it('compareTable renders the header and every row across all columns', () => {
      const out = compareTable(['', 'Before', 'After'], [['Date', '9/1', '9/2']]);
      expect(out).toContain('Before');
      expect(out).toContain('After');
      expect(out).toContain('9/1');
      expect(out).toContain('9/2');
    });
  });
});
