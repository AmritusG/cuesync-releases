const { contextBridge, ipcRenderer } = require('electron');

// Expose protected methods to the renderer process
contextBridge.exposeInMainWorld('electronAPI', {
  // Menu event listeners
  onMenuNew: (callback) => ipcRenderer.on('menu-new', callback),
  onMenuSave: (callback) => ipcRenderer.on('menu-save', callback),
  onMenuUndo: (callback) => ipcRenderer.on('menu-undo', callback),
  onMenuRedo: (callback) => ipcRenderer.on('menu-redo', callback),
  onMenuCreateEnvelope: (callback) => ipcRenderer.on('menu-create-envelope', callback),
  onMenuAddCue: (callback) => ipcRenderer.on('menu-add-cue', callback),
  onMenuToggleLockX: (callback) => ipcRenderer.on('menu-toggle-lock-x', (event, checked) => callback(checked)),
  onMenuToggleLockY: (callback) => ipcRenderer.on('menu-toggle-lock-y', (event, checked) => callback(checked)),
  onMenuPreferences: (callback) => ipcRenderer.on('menu-preferences', callback),
  
  // File operations
  onFileOpened: (callback) => ipcRenderer.on('file-opened', (event, data) => callback(data)),
  onImportFiles: (callback) => ipcRenderer.on('import-files', (event, data) => callback(data)),
  onRequestProjectData: (callback) => ipcRenderer.on('request-project-data', callback),
  onRequestXmlExport: (callback) => ipcRenderer.on('request-xml-export', callback),
  onRequestSkCueExport: (callback) => ipcRenderer.on('request-skcue-export', callback),
  onDefaultPathUpdated: (callback) => ipcRenderer.on('default-path-updated', (event, data) => callback(data)),
  
  // IPC invoke methods
  getDefaultPaths: () => ipcRenderer.invoke('get-default-paths'),
  chooseXmlDirectory: () => ipcRenderer.invoke('choose-xml-directory'),
  chooseSkCueDirectory: () => ipcRenderer.invoke('choose-skcue-directory'),
  openFolder: (path) => ipcRenderer.invoke('open-folder', path),
  saveProject: (data) => ipcRenderer.invoke('save-project', data),
  exportXml: (data) => ipcRenderer.invoke('export-xml', data),
  exportSkCue: (data) => ipcRenderer.invoke('export-skcue', data),
  readFile: (filePath) => ipcRenderer.invoke('read-file', filePath),
  showMessage: (data) => ipcRenderer.invoke('show-message', data),
  
  // Remove listeners
  removeAllListeners: (channel) => ipcRenderer.removeAllListeners(channel),
  
  // Platform info
  platform: process.platform,
  isElectron: true
});

// Also expose a simple flag to check if we're in Electron
contextBridge.exposeInMainWorld('isElectron', true);
