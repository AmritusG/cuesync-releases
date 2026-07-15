const esbuild = require('esbuild');

// Plugin to resolve React imports to window globals
const reactGlobalsPlugin = {
  name: 'react-globals',
  setup(build) {
    // Intercept react imports
    build.onResolve({ filter: /^react$/ }, args => ({
      path: args.path,
      namespace: 'react-globals',
    }));
    
    build.onResolve({ filter: /^react-dom(\/client)?$/ }, args => ({
      path: args.path,
      namespace: 'react-globals',
    }));
    
    // Return code that exports from window
    build.onLoad({ filter: /.*/, namespace: 'react-globals' }, args => {
      if (args.path === 'react') {
        return {
          contents: `
            module.exports = window.React;
            module.exports.useState = window.React.useState;
            module.exports.useRef = window.React.useRef;
            module.exports.useEffect = window.React.useEffect;
            module.exports.useMemo = window.React.useMemo;
            module.exports.useCallback = window.React.useCallback;
          `,
          loader: 'js',
        };
      }
      // react-dom or react-dom/client
      return {
        contents: `
          module.exports = window.ReactDOM;
          module.exports.createRoot = window.ReactDOM.createRoot;
        `,
        loader: 'js',
      };
    });
  },
};

// Build the React app
esbuild.build({
  entryPoints: ['src/index.jsx'],
  bundle: true,
  outfile: 'src/app.js',
  format: 'iife',
  target: ['chrome100'],
  loader: {
    '.jsx': 'jsx',
    '.js': 'jsx'
  },
  jsx: 'transform',
  jsxFactory: 'React.createElement',
  jsxFragment: 'React.Fragment',
  plugins: [reactGlobalsPlugin],
  define: {
    'process.env.NODE_ENV': '"production"'
  },
  minify: process.argv.includes('--minify'),
  sourcemap: process.argv.includes('--sourcemap'),
}).then(() => {
  console.log('✓ Build complete: src/app.js');
}).catch((error) => {
  console.error('Build failed:', error);
  process.exit(1);
});
