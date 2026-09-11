// The native app keeps its existing route scheme. Only the Pages build is
// mounted below /app; Expo must prefix both navigation and bundled asset URLs.
module.exports = ({ config }) => process.env.EXPO_WEB_BASE_PATH === '/app'
  ? { ...config, web: { ...config.web, output: 'single' }, experiments: { ...config.experiments, baseUrl: '/app' } }
  : config;
