import { createRequire } from 'node:module';

// Metro resolves static assets to numeric modules. Node-based component tests
// only need a stable placeholder, otherwise a screen-level CommonJS require()
// tries to parse the image bytes as JavaScript before mocks can run.
const nodeRequire = createRequire(import.meta.url);
nodeRequire.extensions['.jpg'] = (module, filename) => {
  module.exports = filename;
};
nodeRequire.extensions['.png'] = (module, filename) => {
  module.exports = filename;
};

(globalThis as any).__DEV__ = true;
(globalThis as any).expo = (globalThis as any).expo || { EventEmitter: class {} };
