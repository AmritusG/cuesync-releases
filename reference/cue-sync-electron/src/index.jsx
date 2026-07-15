// Entry point for Cue Sync
import React from 'react';
import ReactDOM from 'react-dom/client';
import CueSync from './CueSync.jsx';

// Initialize the app
function initApp() {
  const container = document.getElementById('root');
  if (!container) {
    console.error('Root container not found');
    return;
  }
  
  if (!window.React || !window.ReactDOM) {
    container.innerHTML = '<div style="color: #ff4444; padding: 20px; text-align: center;">Failed to load React libraries</div>';
    return;
  }
  
  try {
    const root = ReactDOM.createRoot(container);
    root.render(React.createElement(CueSync));
    console.log('Cue Sync initialized successfully');
  } catch (error) {
    console.error('Failed to render app:', error);
    container.innerHTML = '<div style="color: #ff4444; padding: 20px; text-align: center;">Error: ' + error.message + '</div>';
  }
}

// Run when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initApp);
} else {
  initApp();
}
