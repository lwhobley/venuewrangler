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
(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
(globalThis as any).expo = (globalThis as any).expo || { EventEmitter: class {} };

import { vi } from 'vitest';
// Screen tests keep their Paper Button mocks; press feedback has dedicated
// coverage in components/AppButton.spec.tsx.
vi.mock('../../components/AppButton', async () => ({
  Button: (await import('react-native-paper')).Button,
}));
vi.mock('expo-file-system/legacy', () => ({
  documentDirectory: '/mock/documents/',
  getInfoAsync: vi.fn().mockResolvedValue({ exists: false }),
  readAsStringAsync: vi.fn().mockResolvedValue(''),
  writeAsStringAsync: vi.fn().mockResolvedValue(undefined),
  deleteAsync: vi.fn().mockResolvedValue(undefined),
}));
vi.mock('expo-file-system', () => ({
  documentDirectory: '/mock/documents/',
  getInfoAsync: vi.fn().mockResolvedValue({ exists: false }),
  readAsStringAsync: vi.fn().mockResolvedValue(''),
  writeAsStringAsync: vi.fn().mockResolvedValue(undefined),
  deleteAsync: vi.fn().mockResolvedValue(undefined),
}));
