const { app, BrowserWindow, Menu, dialog, ipcMain, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const Store = require('electron-store');

// Initialize settings store
const store = new Store({
  defaults: {
    xmlSavePath: app.getPath('documents'),
    skCueSavePath: path.join(app.getPath('documents'), 'TC Supply', 'CUELIST'),
    projectSavePath: app.getPath('documents'),
    windowBounds: { width: 1400, height: 900 }
  }
});

let mainWindow;

function createWindow() {
  const { width, height } = store.get('windowBounds');
  const isMac = process.platform === 'darwin';
  
  // Determine icon path based on platform
  let iconPath;
  if (process.platform === 'win32') {
    iconPath = path.join(__dirname, 'assets', 'icon.ico');
  } else if (isMac) {
    iconPath = path.join(__dirname, 'assets', 'icon.icns');
  } else {
    iconPath = path.join(__dirname, 'assets', 'icon.png');
  }
  
  // Platform-specific window options
  const windowOptions = {
    width,
    height,
    minWidth: 1000,
    minHeight: 700,
    backgroundColor: '#0a0a0f',
    icon: iconPath,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js')
    }
  };

  // macOS: Use hidden inset title bar with custom traffic light position
  // Windows/Linux: Use default native title bar
  if (isMac) {
    windowOptions.titleBarStyle = 'hiddenInset';
    windowOptions.trafficLightPosition = { x: 12, y: 10 };
  } else {
    windowOptions.titleBarStyle = 'default';
  }

  mainWindow = new BrowserWindow(windowOptions);

  mainWindow.loadFile('index.html');

  // Save window size on resize
  mainWindow.on('resize', () => {
    const { width, height } = mainWindow.getBounds();
    store.set('windowBounds', { width, height });
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  // Open DevTools in development
  if (process.argv.includes('--dev')) {
    mainWindow.webContents.openDevTools();
  }
}

// Create application menu
function createMenu() {
  const isMac = process.platform === 'darwin';

  const template = [
    // App menu (macOS only)
    ...(isMac ? [{
      label: app.name,
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        {
          label: 'Preferences...',
          accelerator: 'CmdOrCtrl+,',
          click: () => mainWindow.webContents.send('menu-preferences')
        },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' }
      ]
    }] : []),

    // File menu
    {
      label: 'File',
      submenu: [
        {
          label: 'New Project',
          accelerator: 'CmdOrCtrl+N',
          click: () => mainWindow.webContents.send('menu-new')
        },
        {
          label: 'Open Project...',
          accelerator: 'CmdOrCtrl+O',
          click: () => openProject()
        },
        { type: 'separator' },
        {
          label: 'Save Project',
          accelerator: 'CmdOrCtrl+S',
          click: () => mainWindow.webContents.send('menu-save')
        },
        {
          label: 'Save Project As...',
          accelerator: 'CmdOrCtrl+Shift+S',
          click: () => saveProjectAs()
        },
        { type: 'separator' },
        {
          label: 'Import',
          submenu: [
            {
              label: 'Resolume Envelope...',
              click: () => importFile('resolume')
            },
            { type: 'separator' },
            {
              label: 'Rekordbox XML...',
              click: () => importFile('rekordbox')
            },
            {
              label: 'Serato Files...',
              click: () => importFile('serato')
            },
            {
              label: 'Engine DJ Database...',
              click: () => importFile('engine')
            },
            {
              label: 'ShowKontrol Cue...',
              click: () => importFile('showkontrol')
            }
          ]
        },
        { type: 'separator' },
        {
          label: 'Export',
          submenu: [
            {
              label: 'Resolume XML...',
              accelerator: 'CmdOrCtrl+E',
              click: () => exportXml()
            },
            {
              label: 'ShowKontrol Cue...',
              accelerator: 'CmdOrCtrl+Shift+E',
              click: () => exportSkCue()
            }
          ]
        },
        { type: 'separator' },
        {
          label: 'Set Default XML Export Path...',
          click: () => setDefaultPath('xml')
        },
        {
          label: 'Set Default SK Cue Export Path...',
          click: () => setDefaultPath('skCue')
        },
        { type: 'separator' },
        isMac ? { role: 'close' } : { role: 'quit' }
      ]
    },

    // Edit menu
    {
      label: 'Edit',
      submenu: [
        {
          label: 'Undo',
          accelerator: 'CmdOrCtrl+Z',
          click: () => mainWindow.webContents.send('menu-undo')
        },
        {
          label: 'Redo',
          accelerator: 'CmdOrCtrl+Shift+Z',
          click: () => mainWindow.webContents.send('menu-redo')
        },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' }
      ]
    },

    // View menu
    {
      label: 'View',
      submenu: [
        { role: 'resetZoom', label: 'Reset Zoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        {
          label: 'Toggle Full Screen',
          accelerator: isMac ? 'Ctrl+Command+F' : 'F11',
          click: () => {
            const win = BrowserWindow.getFocusedWindow();
            if (win) win.setFullScreen(!win.isFullScreen());
          }
        }
      ]
    },

    // Envelope menu
    {
      label: 'Envelope',
      submenu: [
        {
          label: 'Create Envelope',
          accelerator: 'CmdOrCtrl+Shift+N',
          click: () => mainWindow.webContents.send('menu-create-envelope')
        },
        { type: 'separator' },
        {
          label: 'Add Cue Point',
          accelerator: 'CmdOrCtrl+D',
          click: () => mainWindow.webContents.send('menu-add-cue')
        },
        { type: 'separator' },
        {
          label: 'Lock X Axis',
          type: 'checkbox',
          checked: true,
          click: (menuItem) => mainWindow.webContents.send('menu-toggle-lock-x', menuItem.checked)
        },
        {
          label: 'Lock Y Axis',
          type: 'checkbox',
          checked: false,
          click: (menuItem) => mainWindow.webContents.send('menu-toggle-lock-y', menuItem.checked)
        }
      ]
    },

    // Window menu
    {
      label: 'Window',
      submenu: [
        { role: 'minimize' },
        { role: 'zoom' },
        ...(isMac ? [
          { type: 'separator' },
          { role: 'front' }
        ] : [
          { role: 'close' }
        ])
      ]
    },

    // Help menu
    {
      label: 'Help',
      submenu: [
        {
          label: 'Documentation',
          click: async () => {
            await shell.openExternal('https://github.com/cuesync/docs');
          }
        },
        {
          label: 'Report Issue',
          click: async () => {
            await shell.openExternal('https://github.com/cuesync/issues');
          }
        }
      ]
    }
  ];

  const menu = Menu.buildFromTemplate(template);
  Menu.setApplicationMenu(menu);
}

// Open project file
async function openProject() {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: 'Open Project',
    defaultPath: store.get('projectSavePath'),
    filters: [
      { name: 'Cue Sync Project', extensions: ['cueproj', 'json'] }
    ],
    properties: ['openFile']
  });

  if (!result.canceled && result.filePaths.length > 0) {
    const filePath = result.filePaths[0];
    store.set('projectSavePath', path.dirname(filePath));
    
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      mainWindow.webContents.send('file-opened', { path: filePath, content });
    } catch (err) {
      dialog.showErrorBox('Error', `Failed to open file: ${err.message}`);
    }
  }
}

// Save project as
async function saveProjectAs() {
  mainWindow.webContents.send('request-project-data');
}

// Import files
async function importFile(type) {
  let filters, title;
  
  switch (type) {
    case 'resolume':
      title = 'Import Resolume Envelope';
      filters = [{ name: 'Resolume XML', extensions: ['xml'] }];
      break;
    case 'rekordbox':
      title = 'Import Rekordbox XML';
      filters = [{ name: 'Rekordbox XML', extensions: ['xml'] }];
      break;
    case 'serato':
      title = 'Import Serato Files';
      filters = [{ name: 'Audio Files', extensions: ['mp3', 'aif', 'aiff', 'wav', 'flac', 'm4a'] }];
      break;
    case 'engine':
      title = 'Import Engine DJ Database';
      filters = [{ name: 'Engine Library', extensions: ['db'] }];
      break;
    case 'showkontrol':
      title = 'Import ShowKontrol Cue';
      filters = [{ name: 'ShowKontrol Cue', extensions: ['cue'] }];
      break;
  }

  const result = await dialog.showOpenDialog(mainWindow, {
    title,
    filters,
    properties: type === 'serato' ? ['openFile', 'multiSelections'] : ['openFile']
  });

  if (!result.canceled && result.filePaths.length > 0) {
    mainWindow.webContents.send('import-files', { type, paths: result.filePaths });
  }
}

// Export XML
async function exportXml() {
  mainWindow.webContents.send('request-xml-export');
}

// Export SK Cue
async function exportSkCue() {
  mainWindow.webContents.send('request-skcue-export');
}

// Set default export paths
async function setDefaultPath(type) {
  const currentPath = type === 'xml' ? store.get('xmlSavePath') : store.get('skCueSavePath');
  
  const result = await dialog.showOpenDialog(mainWindow, {
    title: `Set Default ${type === 'xml' ? 'XML' : 'SK Cue'} Export Path`,
    defaultPath: currentPath,
    properties: ['openDirectory', 'createDirectory']
  });

  if (!result.canceled && result.filePaths.length > 0) {
    if (type === 'xml') {
      store.set('xmlSavePath', result.filePaths[0]);
    } else {
      store.set('skCueSavePath', result.filePaths[0]);
    }
    mainWindow.webContents.send('default-path-updated', { type, path: result.filePaths[0] });
  }
}

// IPC Handlers
ipcMain.handle('get-default-paths', () => {
  return {
    xml: store.get('xmlSavePath'),
    skCue: store.get('skCueSavePath'),
    project: store.get('projectSavePath')
  };
});

ipcMain.handle('choose-xml-directory', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: 'Choose Default Envelope Export Folder',
    defaultPath: store.get('xmlSavePath'),
    properties: ['openDirectory', 'createDirectory']
  });

  if (!result.canceled && result.filePaths.length > 0) {
    const folderPath = result.filePaths[0];
    store.set('xmlSavePath', folderPath);
    return folderPath;
  }
  return null;
});

ipcMain.handle('choose-skcue-directory', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: 'Choose Default ShowKontrol Export Folder',
    defaultPath: store.get('skCueSavePath'),
    properties: ['openDirectory', 'createDirectory']
  });

  if (!result.canceled && result.filePaths.length > 0) {
    const folderPath = result.filePaths[0];
    store.set('skCueSavePath', folderPath);
    return folderPath;
  }
  return null;
});

ipcMain.handle('open-folder', async (event, folderPath) => {
  if (folderPath) {
    shell.openPath(folderPath);
  }
});

ipcMain.handle('save-project', async (event, { content, suggestedName }) => {
  const result = await dialog.showSaveDialog(mainWindow, {
    title: 'Save Project',
    defaultPath: path.join(store.get('projectSavePath'), `${suggestedName}.cueproj`),
    filters: [
      { name: 'Cue Sync Project', extensions: ['cueproj'] }
    ]
  });

  if (!result.canceled && result.filePath) {
    try {
      fs.writeFileSync(result.filePath, content);
      store.set('projectSavePath', path.dirname(result.filePath));
      return { success: true, path: result.filePath };
    } catch (err) {
      return { success: false, error: err.message };
    }
  }
  return { success: false, canceled: true };
});

ipcMain.handle('export-xml', async (event, { content, suggestedName }) => {
  const saveDir = store.get('xmlSavePath');
  
  // Ensure directory exists
  if (!fs.existsSync(saveDir)) {
    fs.mkdirSync(saveDir, { recursive: true });
  }
  
  // Generate unique filename with duplicate handling
  let baseName = suggestedName;
  let filePath = path.join(saveDir, `${baseName}.xml`);
  let counter = 1;
  
  while (fs.existsSync(filePath)) {
    filePath = path.join(saveDir, `${baseName} (${counter}).xml`);
    counter++;
  }
  
  try {
    fs.writeFileSync(filePath, content);
    return { success: true, path: filePath };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

ipcMain.handle('export-skcue', async (event, { content, suggestedName }) => {
  const saveDir = store.get('skCueSavePath');
  
  // Ensure directory exists
  if (!fs.existsSync(saveDir)) {
    fs.mkdirSync(saveDir, { recursive: true });
  }
  
  // Generate unique filename with duplicate handling
  let baseName = suggestedName;
  let filePath = path.join(saveDir, `${baseName}.cue`);
  let counter = 1;
  
  while (fs.existsSync(filePath)) {
    filePath = path.join(saveDir, `${baseName} (${counter}).cue`);
    counter++;
  }
  
  try {
    fs.writeFileSync(filePath, content);
    return { success: true, path: filePath };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

ipcMain.handle('read-file', async (event, filePath) => {
  try {
    const content = fs.readFileSync(filePath);
    return { success: true, content: content.toString('base64'), isBuffer: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

ipcMain.handle('show-message', async (event, { type, title, message }) => {
  dialog.showMessageBox(mainWindow, {
    type: type || 'info',
    title: title || 'Cue Sync',
    message
  });
});

// App lifecycle
app.whenReady().then(() => {
  createWindow();
  createMenu();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

// Handle uncaught errors
process.on('uncaughtException', (error) => {
  console.error('Uncaught Exception:', error);
  dialog.showErrorBox('Error', `An unexpected error occurred: ${error.message}`);
});
