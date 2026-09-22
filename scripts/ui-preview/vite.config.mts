import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';

// Isolated visual fixture; never part of Expo's routes or production bundle.
export default defineConfig({
  root: fileURLToPath(new URL('.', import.meta.url)),
  envDir: false,
  resolve: { alias: [
    { find: /^react-native$/, replacement: 'react-native-web' },
    // Theme-only entry avoids loading unused native icon/camera dependencies.
    { find: /^react-native-paper$/, replacement: fileURLToPath(new URL('./paper-themes.js', import.meta.url)) },
  ] },
  esbuild: { jsx: 'automatic' },
  define: { __DEV__: 'true', 'process.env.NODE_ENV': '"development"' },
  server: { host: '127.0.0.1', port: 5174, strictPort: true },
});
