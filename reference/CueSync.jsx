import React, { useState, useRef, useEffect, useMemo } from 'react';

// Resolume Envelope Curve Types - EXACT order matching Resolume Arena
const CURVE_TYPES = [
  { id: 1, name: 'Linear', category: 'Basic' },
  { id: 2, name: 'Quadratic In', category: 'Quadratic' },
  { id: 3, name: 'Quadratic Out', category: 'Quadratic' },
  { id: 4, name: 'Quadratic In/Out', category: 'Quadratic' },
  { id: 5, name: 'Sine In', category: 'Sine' },
  { id: 6, name: 'Sine Out', category: 'Sine' },
  { id: 7, name: 'Sine In/Out', category: 'Sine' },
  { id: 8, name: 'Circular In', category: 'Circular' },
  { id: 9, name: 'Circular Out', category: 'Circular' },
  { id: 10, name: 'Circular In/Out', category: 'Circular' },
  { id: 11, name: 'Exponential In', category: 'Exponential' },
  { id: 12, name: 'Exponential Out', category: 'Exponential' },
  { id: 13, name: 'Exponential In/Out', category: 'Exponential' },
  { id: 14, name: 'Elastic In', category: 'Elastic' },
  { id: 15, name: 'Elastic Out', category: 'Elastic' },
  { id: 16, name: 'Elastic In/Out', category: 'Elastic' },
  { id: 17, name: 'Back In', category: 'Back' },
  { id: 18, name: 'Back Out', category: 'Back' },
  { id: 19, name: 'Back In/Out', category: 'Back' },
  { id: 20, name: 'Bounce In', category: 'Bounce' },
  { id: 21, name: 'Bounce Out', category: 'Bounce' },
  { id: 22, name: 'Bounce In/Out', category: 'Bounce' },
  { id: 23, name: 'Hold', category: 'Basic' },
];

// Bounce Out helper
const bounceOut = (t) => {
  const n1 = 7.5625, d1 = 2.75;
  if (t < 1 / d1) return n1 * t * t;
  if (t < 2 / d1) return n1 * (t -= 1.5 / d1) * t + 0.75;
  if (t < 2.5 / d1) return n1 * (t -= 2.25 / d1) * t + 0.9375;
  return n1 * (t -= 2.625 / d1) * t + 0.984375;
};

// Easing functions
const getEasedValue = (t, curveType) => {
  const clampedT = Math.max(0, Math.min(1, t));
  switch (curveType) {
    case 1: return clampedT;
    case 2: return clampedT * clampedT;
    case 3: return clampedT * (2 - clampedT);
    case 4: return clampedT < 0.5 ? 2 * clampedT * clampedT : -1 + (4 - 2 * clampedT) * clampedT;
    case 5: return 1 - Math.cos((clampedT * Math.PI) / 2);
    case 6: return Math.sin((clampedT * Math.PI) / 2);
    case 7: return -(Math.cos(Math.PI * clampedT) - 1) / 2;
    case 8: return 1 - Math.sqrt(1 - clampedT * clampedT);
    case 9: return Math.sqrt(1 - (clampedT - 1) * (clampedT - 1));
    case 10: return clampedT < 0.5 ? (1 - Math.sqrt(1 - 4 * clampedT * clampedT)) / 2 : (Math.sqrt(1 - Math.pow(-2 * clampedT + 2, 2)) + 1) / 2;
    case 11: return clampedT === 0 ? 0 : Math.pow(2, 10 * (clampedT - 1));
    case 12: return clampedT === 1 ? 1 : 1 - Math.pow(2, -10 * clampedT);
    case 13: return clampedT === 0 ? 0 : clampedT === 1 ? 1 : clampedT < 0.5 ? Math.pow(2, 20 * clampedT - 10) / 2 : (2 - Math.pow(2, -20 * clampedT + 10)) / 2;
    case 14: return clampedT === 0 ? 0 : -Math.pow(2, 10 * clampedT - 10) * Math.sin((clampedT * 10 - 10.75) * ((2 * Math.PI) / 3));
    case 15: return clampedT === 1 ? 1 : Math.pow(2, -10 * clampedT) * Math.sin((clampedT * 10 - 0.75) * ((2 * Math.PI) / 3)) + 1;
    case 16: return clampedT === 0 ? 0 : clampedT === 1 ? 1 : clampedT < 0.5 ? -(Math.pow(2, 20 * clampedT - 10) * Math.sin((20 * clampedT - 11.125) * ((2 * Math.PI) / 4.5))) / 2 : (Math.pow(2, -20 * clampedT + 10) * Math.sin((20 * clampedT - 11.125) * ((2 * Math.PI) / 4.5))) / 2 + 1;
    case 17: return 2.70158 * clampedT * clampedT * clampedT - 1.70158 * clampedT * clampedT;
    case 18: return 1 + 2.70158 * Math.pow(clampedT - 1, 3) + 1.70158 * Math.pow(clampedT - 1, 2);
    case 19: return clampedT < 0.5 ? (Math.pow(2 * clampedT, 2) * ((2.59491 + 1) * 2 * clampedT - 2.59491)) / 2 : (Math.pow(2 * clampedT - 2, 2) * ((2.59491 + 1) * (clampedT * 2 - 2) + 2.59491) + 2) / 2;
    case 20: return 1 - bounceOut(1 - clampedT);
    case 21: return bounceOut(clampedT);
    case 22: return clampedT < 0.5 ? (1 - bounceOut(1 - 2 * clampedT)) / 2 : (1 + bounceOut(2 * clampedT - 1)) / 2;
    case 23: return 0;
    default: return clampedT;
  }
};

// Generate SVG path for curve icon
const generateCurveIconPath = (curveType, width = 32, height = 16) => {
  const padding = 2;
  const w = width - padding * 2;
  const h = height - padding * 2;
  const points = [];
  const steps = 24;
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    let y = getEasedValue(t, curveType);
    if (curveType === 23) y = 0;
    y = Math.max(-0.2, Math.min(1.2, y));
    const px = padding + t * w;
    const py = padding + h - y * h;
    points.push(`${i === 0 ? 'M' : 'L'} ${px.toFixed(1)} ${py.toFixed(1)}`);
  }
  return points.join(' ');
};

// Curve Icon Component
const CurveIcon = ({ curveType, size = 32, color = '#1ed760' }) => {
  const height = size / 2;
  const path = generateCurveIconPath(curveType, size, height);
  return (
    <svg width={size} height={height} viewBox={`0 0 ${size} ${height}`} style={{ display: 'block' }}>
      <path d={path} fill="none" stroke={color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
};

// Custom Dropdown Component
const CurveDropdown = ({ value, onChange, disabled, theme }) => {
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef(null);
  const selectedCurve = CURVE_TYPES.find(c => c.id === value) || CURVE_TYPES[0];
  const isLight = theme === 'light';
  
  const groupedCurves = useMemo(() => {
    const groups = {};
    const categoryOrder = ['Basic', 'Quadratic', 'Sine', 'Circular', 'Exponential', 'Elastic', 'Back', 'Bounce'];
    categoryOrder.forEach(cat => groups[cat] = []);
    CURVE_TYPES.forEach(curve => {
      if (groups[curve.category]) {
        if (curve.id === 23) groups[curve.category].push(curve);
        else if (curve.category === 'Basic') groups[curve.category].unshift(curve);
        else groups[curve.category].push(curve);
      }
    });
    return groups;
  }, []);
  
  useEffect(() => {
    const handleClickOutside = (e) => {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target)) setIsOpen(false);
    };
    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isOpen]);
  
  const themedDropdownStyles = {
    container: { position: 'relative', width: '160px' },
    button: { display: 'flex', alignItems: 'center', gap: '8px', width: '100%', padding: '6px 10px', backgroundColor: isLight ? 'rgba(0, 0, 0, 0.04)' : 'rgba(0, 0, 0, 0.5)', border: isLight ? '1px solid rgba(0, 0, 0, 0.12)' : '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '4px', color: isLight ? '#1d1d1f' : '#fff', fontSize: '11px', fontFamily: 'inherit', cursor: 'pointer', transition: 'all 0.15s', textAlign: 'left' },
    buttonDisabled: { opacity: 0.5, cursor: 'not-allowed' },
    buttonOpen: { borderColor: isLight ? '#0d7a3e' : '#1ed760', borderTopLeftRadius: 0, borderTopRightRadius: 0 },
    buttonText: { flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: disabled ? '#666' : (isLight ? '#1d1d1f' : '#fff') },
    arrow: { fontSize: '8px', color: isLight ? '#86868b' : '#888' },
    menu: { position: 'absolute', bottom: '100%', left: 0, right: 0, maxHeight: '300px', overflowY: 'auto', backgroundColor: isLight ? '#fff' : '#1a1a24', border: isLight ? '1px solid #0d7a3e' : '1px solid #1ed760', borderBottom: 'none', borderTopLeftRadius: '4px', borderTopRightRadius: '4px', zIndex: 100, boxShadow: isLight ? '0 -8px 24px rgba(0, 0, 0, 0.15)' : '0 -8px 24px rgba(0, 0, 0, 0.5)' },
    categoryLabel: { padding: '8px 12px 4px', fontSize: '9px', fontWeight: '700', color: isLight ? '#86868b' : '#666', textTransform: 'uppercase', letterSpacing: '1px', borderTop: isLight ? '1px solid rgba(0, 0, 0, 0.06)' : '1px solid rgba(255, 255, 255, 0.05)' },
    option: { display: 'flex', alignItems: 'center', gap: '8px', padding: '6px 12px', cursor: 'pointer', transition: 'background-color 0.1s' },
    optionSelected: { backgroundColor: isLight ? 'rgba(30, 215, 96, 0.12)' : 'rgba(30, 215, 96, 0.15)' },
    optionText: { fontSize: '11px', flex: 1 },
  };
  
  return (
    <div ref={dropdownRef} style={themedDropdownStyles.container}>
      <button onClick={() => !disabled && setIsOpen(!isOpen)} style={{ ...themedDropdownStyles.button, ...(disabled ? themedDropdownStyles.buttonDisabled : {}), ...(isOpen ? themedDropdownStyles.buttonOpen : {}) }} disabled={disabled}>
        <CurveIcon curveType={value} size={28} color={disabled ? '#666' : (isLight ? '#0d7a3e' : '#1ed760')} />
        <span style={themedDropdownStyles.buttonText}>{selectedCurve.name}</span>
        <span style={themedDropdownStyles.arrow}>{isOpen ? '▼' : '▲'}</span>
      </button>
      {isOpen && (
        <div style={themedDropdownStyles.menu}>
          {Object.entries(groupedCurves).map(([category, curves]) => curves.length > 0 && (
            <div key={category}>
              <div style={themedDropdownStyles.categoryLabel}>{category}</div>
              {curves.map(curve => (
                <div key={curve.id} onClick={() => { onChange(curve.id); setIsOpen(false); }} style={{ ...themedDropdownStyles.option, ...(curve.id === value ? themedDropdownStyles.optionSelected : {}) }}
                  onMouseEnter={(e) => { if (curve.id !== value) e.currentTarget.style.backgroundColor = isLight ? 'rgba(0, 0, 0, 0.04)' : 'rgba(30, 215, 96, 0.1)'; }}
                  onMouseLeave={(e) => { if (curve.id !== value) e.currentTarget.style.backgroundColor = 'transparent'; }}>
                  <CurveIcon curveType={curve.id} size={28} color={curve.id === value ? (isLight ? '#0d7a3e' : '#1ed760') : (isLight ? '#86868b' : '#888')} />
                  <span style={{ ...themedDropdownStyles.optionText, color: curve.id === value ? (isLight ? '#0d7a3e' : '#1ed760') : (isLight ? '#1d1d1f' : '#ccc') }}>{curve.name}</span>
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

const dropdownStyles = {
  container: { position: 'relative', width: '160px' },
  button: { display: 'flex', alignItems: 'center', gap: '8px', width: '100%', padding: '6px 10px', backgroundColor: 'rgba(0, 0, 0, 0.5)', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '4px', color: '#fff', fontSize: '11px', fontFamily: 'inherit', cursor: 'pointer', transition: 'all 0.15s', textAlign: 'left' },
  buttonDisabled: { opacity: 0.5, cursor: 'not-allowed' },
  buttonOpen: { borderColor: '#1ed760', borderTopLeftRadius: 0, borderTopRightRadius: 0 },
  buttonText: { flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
  arrow: { fontSize: '8px', color: '#888' },
  menu: { position: 'absolute', bottom: '100%', left: 0, right: 0, maxHeight: '300px', overflowY: 'auto', backgroundColor: '#1a1a24', border: '1px solid #1ed760', borderBottom: 'none', borderTopLeftRadius: '4px', borderTopRightRadius: '4px', zIndex: 100, boxShadow: '0 -8px 24px rgba(0, 0, 0, 0.5)' },
  categoryLabel: { padding: '8px 12px 4px', fontSize: '9px', fontWeight: '700', color: '#666', textTransform: 'uppercase', letterSpacing: '1px', borderTop: '1px solid rgba(255, 255, 255, 0.05)' },
  option: { display: 'flex', alignItems: 'center', gap: '8px', padding: '6px 12px', cursor: 'pointer', transition: 'background-color 0.1s' },
  optionSelected: { backgroundColor: 'rgba(30, 215, 96, 0.15)' },
  optionText: { fontSize: '11px', flex: 1 },
};

const interpolate = (x, x1, y1, x2, y2, curveType) => {
  if (x2 === x1) return y1;
  const t = (x - x1) / (x2 - x1);
  if (curveType === 23) return y1;
  const easedT = getEasedValue(t, curveType);
  return y1 + (y2 - y1) * easedT;
};

export default function CueSync() {
  const [tracks, setTracks] = useState([]);
  const [playlists, setPlaylists] = useState([]);
  const [selectedPlaylist, setSelectedPlaylist] = useState('all');
  const [searchQuery, setSearchQuery] = useState('');
  const [sortBy, setSortBy] = useState('name');
  const [selectedTrack, setSelectedTrack] = useState(null);
  const [cuePoints, setCuePoints] = useState([]);
  const [stateHistory, setStateHistory] = useState([]);
  const [stateFuture, setStateFuture] = useState([]);
  const [trackDuration, setTrackDuration] = useState(0);
  const [presetName, setPresetName] = useState('New Envelope');
  const [generatedXml, setGeneratedXml] = useState('');
  const [loading, setLoading] = useState(false);
  const [audioStatus, setAudioStatus] = useState('idle');
  const [audioFileName, setAudioFileName] = useState('');
  const [audioError, setAudioError] = useState('');
  const [hoveredTrack, setHoveredTrack] = useState(null);
  const [hoveredLayoutBtn, setHoveredLayoutBtn] = useState(null);
  const [copySuccess, setCopySuccess] = useState(false);
  const [lockXAxis, setLockXAxis] = useState(true);
  const [selectedPointIndex, setSelectedPointIndex] = useState(null);
  const [isDragging, setIsDragging] = useState(false);
  const [projectName, setProjectName] = useState('Untitled Project');
  const [hasUnsavedChanges, setHasUnsavedChanges] = useState(false);
  const [expandedFolders, setExpandedFolders] = useState({});
  const [envelopeMode, setEnvelopeMode] = useState(false);
  const [newCueSec, setNewCueSec] = useState(0);
  const [newCueMs, setNewCueMs] = useState(0);
  const [lockYAxis, setLockYAxis] = useState(false);
  const [defaultXmlPath, setDefaultXmlPath] = useState('');
  const [defaultSkCuePath, setDefaultSkCuePath] = useState('');
  
  // Section layout management for 2-column draggable layout
  const defaultSectionOrder = ['project', 'browse', 'configure', 'generate'];
  const defaultSectionColumns = {
    project: 'left',
    browse: 'left',
    configure: 'right',
    generate: 'right'
  };

  const [sectionOrder, setSectionOrder] = useState(() => {
    try {
      const saved = localStorage.getItem('cuesync-section-order');
      if (saved) {
        const parsed = JSON.parse(saved);
        if (Array.isArray(parsed) && defaultSectionOrder.every(s => parsed.includes(s))) {
          return parsed;
        }
      }
    } catch (e) {}
    return defaultSectionOrder;
  });
  
  const [sectionColumns, setSectionColumns] = useState(() => {
    try {
      const saved = localStorage.getItem('cuesync-section-columns');
      if (saved) {
        const parsed = JSON.parse(saved);
        if (typeof parsed === 'object' && defaultSectionOrder.every(s => parsed[s])) {
          return parsed;
        }
      }
    } catch (e) {}
    return defaultSectionColumns;
  });
  
  const [collapsedSections, setCollapsedSections] = useState(() => {
    try {
      const saved = localStorage.getItem('cuesync-collapsed-sections');
      if (saved) return JSON.parse(saved);
    } catch (e) {}
    return {};
  });
  
  const [draggedSection, setDraggedSection] = useState(null);
  
  const [sideBySideMode, setSideBySideMode] = useState(() => {
    try {
      const saved = localStorage.getItem('cuesync-side-by-side');
      if (saved) return JSON.parse(saved);
    } catch (e) {}
    return false;
  });
  
  const [configureSpanColumns, setConfigureSpanColumns] = useState(() => {
    try {
      const saved = localStorage.getItem('cuesync-configure-span');
      if (saved) return JSON.parse(saved);
    } catch (e) {}
    return false;
  });
  
  const [theme, setTheme] = useState(() => {
    try {
      const saved = localStorage.getItem('cuesync-theme');
      if (saved) return JSON.parse(saved);
    } catch (e) {}
    return 'dark';
  });
  
  const [savedLayout, setSavedLayout] = useState(() => {
    try {
      const saved = localStorage.getItem('cuesync-saved-layout');
      if (saved) return JSON.parse(saved);
    } catch (e) {}
    return null;
  });

  // Persist UI layout state to localStorage
  useEffect(() => {
    try {
      localStorage.setItem('cuesync-section-order', JSON.stringify(sectionOrder));
    } catch (e) {}
  }, [sectionOrder]);

  useEffect(() => {
    try {
      localStorage.setItem('cuesync-section-columns', JSON.stringify(sectionColumns));
    } catch (e) {}
  }, [sectionColumns]);

  useEffect(() => {
    try {
      localStorage.setItem('cuesync-collapsed-sections', JSON.stringify(collapsedSections));
    } catch (e) {}
  }, [collapsedSections]);

  useEffect(() => {
    try {
      localStorage.setItem('cuesync-side-by-side', JSON.stringify(sideBySideMode));
    } catch (e) {}
  }, [sideBySideMode]);

  useEffect(() => {
    try {
      localStorage.setItem('cuesync-configure-span', JSON.stringify(configureSpanColumns));
    } catch (e) {}
  }, [configureSpanColumns]);

  useEffect(() => {
    try {
      localStorage.setItem('cuesync-theme', JSON.stringify(theme));
    } catch (e) {}
  }, [theme]);

  useEffect(() => {
    try {
      if (savedLayout) {
        localStorage.setItem('cuesync-saved-layout', JSON.stringify(savedLayout));
      }
    } catch (e) {}
  }, [savedLayout]);

  // Check if current layout matches saved layout
  const isLayoutSaved = savedLayout && 
    sideBySideMode === savedLayout.sideBySideMode && 
    configureSpanColumns === savedLayout.configureSpanColumns &&
    JSON.stringify(sectionOrder) === JSON.stringify(savedLayout.sectionOrder) &&
    JSON.stringify(sectionColumns) === JSON.stringify(savedLayout.sectionColumns) &&
    theme === (savedLayout.theme || 'dark');

  // Save viewport layout (for "Last Saved" restore feature)
  const saveViewportLayout = () => {
    const layout = { sideBySideMode, configureSpanColumns, sectionOrder, sectionColumns, theme };
    setSavedLayout(layout);
  };

  // Restore viewport layout from saved snapshot
  const restoreViewportLayout = () => {
    if (savedLayout) {
      setSideBySideMode(savedLayout.sideBySideMode);
      setConfigureSpanColumns(savedLayout.configureSpanColumns);
      setSectionOrder(savedLayout.sectionOrder);
      setSectionColumns(savedLayout.sectionColumns);
      if (savedLayout.theme) setTheme(savedLayout.theme);
    }
  };
  
  const xmlInputRef = useRef(null);
  const audioInputRef = useRef(null);
  const projectInputRef = useRef(null);
  const seratoInputRef = useRef(null);
  const engineInputRef = useRef(null);
  const showKontrolInputRef = useRef(null);
  const resolumeInputRef = useRef(null);
  const svgRef = useRef(null);

  // Parse playlists recursively from Rekordbox XML
  const parsePlaylists = (xmlDoc) => {
    const playlistNodes = xmlDoc.querySelectorAll('PLAYLISTS > NODE');
    const result = [];
    
    const parseNode = (node, path = '') => {
      const type = node.getAttribute('Type');
      const name = node.getAttribute('Name') || 'Unnamed';
      const fullPath = path ? `${path}/${name}` : name;
      
      if (type === '0') { // Folder
        const children = node.querySelectorAll(':scope > NODE');
        const folder = { type: 'folder', name, path: fullPath, children: [] };
        children.forEach(child => {
          const parsed = parseNode(child, fullPath);
          if (parsed) folder.children.push(parsed);
        });
        if (folder.children.length > 0) return folder;
      } else if (type === '1') { // Playlist
        const trackRefs = node.querySelectorAll('TRACK');
        const trackIds = Array.from(trackRefs).map(t => t.getAttribute('Key'));
        return { type: 'playlist', name, path: fullPath, trackIds };
      }
      return null;
    };
    
    playlistNodes.forEach(node => {
      const parsed = parseNode(node);
      if (parsed) result.push(parsed);
    });
    
    return result;
  };

  const parseRekordboxXml = (xmlString) => {
    try {
      const parser = new DOMParser();
      const xmlDoc = parser.parseFromString(xmlString, 'text/xml');
      if (xmlDoc.querySelector('parsererror')) { alert('Error parsing XML file.'); return { tracks: [], playlists: [] }; }
      
      const trackElements = xmlDoc.querySelectorAll('COLLECTION > TRACK');
      const parsedTracks = [];
      
      trackElements.forEach((track, index) => {
        const positionMarks = track.querySelectorAll('POSITION_MARK');
        const cues = [];
        positionMarks.forEach((mark) => {
          cues.push({
            id: `cue-${index}-${parseFloat(mark.getAttribute('Start')) || 0}-${Math.random()}`,
            start: parseFloat(mark.getAttribute('Start')) || 0,
            name: mark.getAttribute('Name') || '',
            color: `rgb(${mark.getAttribute('Red') || '255'}, ${mark.getAttribute('Green') || '0'}, ${mark.getAttribute('Blue') || '0'})`,
            yValue: 100.00,
            curve: 1,
            enabled: true
          });
        });
        cues.sort((a, b) => a.start - b.start);

        const location = track.getAttribute('Location') || '';
        let decodedLocation = '';
        try { decodedLocation = decodeURIComponent(location.replace('file://localhost', '')); } catch (e) { decodedLocation = location; }
        
        parsedTracks.push({
          id: track.getAttribute('TrackID') || `track-${index}`,
          name: track.getAttribute('Name') || 'Unknown Track',
          artist: track.getAttribute('Artist') || '',
          album: track.getAttribute('Album') || '',
          genre: track.getAttribute('Genre') || '',
          totalTime: parseInt(track.getAttribute('TotalTime')) || 0,
          bpm: parseFloat(track.getAttribute('AverageBpm')) || 0,
          tonality: track.getAttribute('Tonality') || '',
          location: decodedLocation,
          cuePoints: cues
        });
      });

      const parsedPlaylists = parsePlaylists(xmlDoc);
      return { tracks: parsedTracks, playlists: parsedPlaylists };
    } catch (error) {
      alert('Error parsing XML: ' + error.message);
      return { tracks: [], playlists: [] };
    }
  };

  // ============================================================================
  // SERATO DJ PARSER - Extracts cue points from audio file ID3 GEOB tags
  // ============================================================================
  
  const SERATO_CUE_COLORS = [
    [0xCC, 0x00, 0x00], // Red
    [0xCC, 0x88, 0x00], // Orange
    [0xCC, 0xCC, 0x00], // Yellow
    [0x00, 0xCC, 0x00], // Green
    [0x00, 0xCC, 0xCC], // Cyan
    [0x00, 0x00, 0xCC], // Blue
    [0xCC, 0x00, 0xCC], // Purple
    [0xCC, 0x00, 0x88], // Pink
  ];

  const parseSeratoFile = async (file) => {
    const arrayBuffer = await file.arrayBuffer();
    const data = new Uint8Array(arrayBuffer);
    const fileName = file.name;
    const ext = fileName.split('.').pop().toLowerCase();
    
    let markers2Data = null;
    let title = fileName.replace(/\.[^/.]+$/, '');
    let artist = '';
    let album = '';
    let bpm = 0;
    let duration = 0;
    
    if (ext === 'mp3' || ext === 'aif' || ext === 'aiff') {
      const id3Result = parseID3v2(data);
      markers2Data = id3Result.seratoMarkers2;
      title = id3Result.title || title;
      artist = id3Result.artist || '';
      album = id3Result.album || '';
    } else if (ext === 'wav') {
      // WAV files: Look for ID3v2 tag embedded in RIFF container
      const wavResult = parseWAVSeratoTags(data);
      markers2Data = wavResult.seratoMarkers2;
      title = wavResult.title || title;
      artist = wavResult.artist || '';
      album = wavResult.album || '';
      duration = wavResult.duration || 0;
    } else if (ext === 'flac') {
      // FLAC: Look for VORBIS_COMMENT with SERATO_MARKERS_V2
      const flacResult = parseFLACVorbisComment(data);
      markers2Data = flacResult.seratoMarkers2;
      title = flacResult.title || title;
      artist = flacResult.artist || '';
    } else if (ext === 'm4a' || ext === 'mp4') {
      // MP4/M4A: Look for Serato atoms
      const mp4Result = parseMP4SeratoTags(data);
      markers2Data = mp4Result.seratoMarkers2;
      title = mp4Result.title || title;
      artist = mp4Result.artist || '';
    }
    
    if (!markers2Data) {
      return null;
    }
    
    const cuePoints = parseSeratoMarkers2(markers2Data);
    return { title, artist, album, bpm, duration, cuePoints, fileName };
  };

  // Parse WAV files for Serato tags (ID3v2 in RIFF container)
  const parseWAVSeratoTags = (data) => {
    const result = { seratoMarkers2: null, title: '', artist: '', album: '', duration: 0 };
    
    // Check for RIFF header
    if (data[0] !== 0x52 || data[1] !== 0x49 || data[2] !== 0x46 || data[3] !== 0x46) { // "RIFF"
      return result;
    }
    
    // Check for WAVE format
    if (data[8] !== 0x57 || data[9] !== 0x41 || data[10] !== 0x56 || data[11] !== 0x45) { // "WAVE"
      return result;
    }
    
    let pos = 12;
    let sampleRate = 0, channels = 0, bitsPerSample = 0, dataSize = 0;
    
    // Scan through RIFF chunks
    while (pos < data.length - 8) {
      const chunkId = String.fromCharCode(data[pos], data[pos+1], data[pos+2], data[pos+3]);
      const chunkSize = data[pos+4] | (data[pos+5] << 8) | (data[pos+6] << 16) | (data[pos+7] << 24);
      
      if (chunkSize <= 0 || chunkSize > data.length - pos) break;
      
      if (chunkId === 'fmt ') {
        // Parse format chunk
        // Bytes 0-1: audio format
        // Bytes 2-3: number of channels
        // Bytes 4-7: sample rate
        // Bytes 8-11: byte rate
        // Bytes 12-13: block align
        // Bytes 14-15: bits per sample
        const fmtData = data.slice(pos + 8, pos + 8 + Math.min(chunkSize, 16));
        channels = fmtData[2] | (fmtData[3] << 8);
        sampleRate = fmtData[4] | (fmtData[5] << 8) | (fmtData[6] << 16) | (fmtData[7] << 24);
        bitsPerSample = fmtData[14] | (fmtData[15] << 8);
      } else if (chunkId === 'data') {
        dataSize = chunkSize;
      } else if (chunkId === 'id3 ' || chunkId === 'ID3 ') {
        // Found ID3 chunk - parse it
        const id3Data = data.slice(pos + 8, pos + 8 + chunkSize);
        
        // Verify it starts with ID3 header
        if (id3Data[0] === 0x49 && id3Data[1] === 0x44 && id3Data[2] === 0x33) {
          const id3Result = parseID3v2(id3Data);
          result.seratoMarkers2 = id3Result.seratoMarkers2;
          result.title = id3Result.title;
          result.artist = id3Result.artist;
          result.album = id3Result.album;
        }
      }
      
      pos += 8 + chunkSize;
      // RIFF chunks are word-aligned (2 bytes)
      if (chunkSize % 2 !== 0) pos++;
    }
    
    // Calculate duration
    if (sampleRate > 0 && channels > 0 && bitsPerSample > 0 && dataSize > 0) {
      const bytesPerSample = bitsPerSample / 8;
      const totalSamples = dataSize / (channels * bytesPerSample);
      result.duration = totalSamples / sampleRate;
    }
    
    return result;
  };

  // Parse MP4/M4A files for Serato tags
  const parseMP4SeratoTags = (data) => {
    const result = { seratoMarkers2: null, title: '', artist: '', album: '' };
    
    // Simple MP4 atom parser - look for Serato metadata
    let pos = 0;
    
    while (pos < data.length - 8) {
      const size = (data[pos] << 24) | (data[pos+1] << 16) | (data[pos+2] << 8) | data[pos+3];
      const type = String.fromCharCode(data[pos+4], data[pos+5], data[pos+6], data[pos+7]);
      
      if (size < 8 || size > data.length - pos) break;
      
      // Look for ---- atoms which contain Serato metadata
      if (type === '----') {
        // Parse the contents for mean/name/data
        let innerPos = pos + 8;
        const atomEnd = pos + size;
        let mean = '', name = '';
        let atomData = null;
        
        while (innerPos < atomEnd - 8) {
          const innerSize = (data[innerPos] << 24) | (data[innerPos+1] << 16) | (data[innerPos+2] << 8) | data[innerPos+3];
          const innerType = String.fromCharCode(data[innerPos+4], data[innerPos+5], data[innerPos+6], data[innerPos+7]);
          
          if (innerSize < 8) break;
          
          if (innerType === 'mean') {
            mean = new TextDecoder('utf-8').decode(data.slice(innerPos + 12, innerPos + innerSize));
          } else if (innerType === 'name') {
            name = new TextDecoder('utf-8').decode(data.slice(innerPos + 12, innerPos + innerSize));
          } else if (innerType === 'data') {
            atomData = data.slice(innerPos + 16, innerPos + innerSize);
          }
          
          innerPos += innerSize;
        }
        
        if (mean === 'com.serato.dj' && name === 'markers2' && atomData) {
          // Decode base64
          try {
            let b64 = new TextDecoder('utf-8').decode(atomData).replace(/\n/g, '');
            while (b64.length % 4) b64 += '=';
            const decoded = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
            
            // Find actual data after preamble
            const marker = 'Serato Markers2\x00';
            let idx = -1;
            for (let j = 0; j < decoded.length - marker.length; j++) {
              let found = true;
              for (let k = 0; k < marker.length; k++) {
                if (decoded[j + k] !== marker.charCodeAt(k)) { found = false; break; }
              }
              if (found) { idx = j + marker.length; break; }
            }
            result.seratoMarkers2 = idx >= 0 ? decoded.slice(idx) : decoded;
          } catch (e) {}
        }
      } else if (type === 'moov' || type === 'udta' || type === 'meta' || type === 'ilst') {
        // Container atoms - descend into them
        pos += 8;
        if (type === 'meta') pos += 4; // meta has 4-byte version/flags
        continue;
      }
      
      pos += size;
    }
    
    return result;
  };

  const parseID3v2 = (data) => {
    const result = { seratoMarkers2: null, title: '', artist: '', album: '' };
    
    // Check for ID3v2 header
    if (data[0] !== 0x49 || data[1] !== 0x44 || data[2] !== 0x33) { // "ID3"
      return result;
    }
    
    const version = data[3];
    const flags = data[5];
    const size = ((data[6] & 0x7F) << 21) | ((data[7] & 0x7F) << 14) | ((data[8] & 0x7F) << 7) | (data[9] & 0x7F);
    
    let pos = 10;
    const end = 10 + size;
    
    // Handle extended header if present
    if (flags & 0x40) {
      const extSize = (data[pos] << 24) | (data[pos+1] << 16) | (data[pos+2] << 8) | data[pos+3];
      pos += 4 + extSize;
    }
    
    while (pos < end - 10) {
      // Frame header: 4 bytes ID, 4 bytes size, 2 bytes flags
      const frameId = String.fromCharCode(data[pos], data[pos+1], data[pos+2], data[pos+3]);
      
      if (frameId === '\x00\x00\x00\x00' || !frameId.match(/^[A-Z0-9]{4}$/)) {
        break; // Padding or invalid frame
      }
      
      let frameSize;
      if (version === 4) {
        frameSize = ((data[pos+4] & 0x7F) << 21) | ((data[pos+5] & 0x7F) << 14) | ((data[pos+6] & 0x7F) << 7) | (data[pos+7] & 0x7F);
      } else {
        frameSize = (data[pos+4] << 24) | (data[pos+5] << 16) | (data[pos+6] << 8) | data[pos+7];
      }
      
      const frameData = data.slice(pos + 10, pos + 10 + frameSize);
      
      if (frameId === 'TIT2') {
        result.title = decodeID3TextFrame(frameData);
      } else if (frameId === 'TPE1') {
        result.artist = decodeID3TextFrame(frameData);
      } else if (frameId === 'TALB') {
        result.album = decodeID3TextFrame(frameData);
      } else if (frameId === 'GEOB') {
        const geob = parseGEOBFrame(frameData);
        if (geob.description === 'Serato Markers2') {
          result.seratoMarkers2 = geob.data;
        }
      }
      
      pos += 10 + frameSize;
    }
    
    return result;
  };

  const decodeID3TextFrame = (frameData) => {
    const encoding = frameData[0];
    let text = '';
    const textData = frameData.slice(1);
    
    if (encoding === 0) { // ISO-8859-1
      text = Array.from(textData).map(c => String.fromCharCode(c)).join('').replace(/\x00/g, '');
    } else if (encoding === 1 || encoding === 2) { // UTF-16
      const decoder = new TextDecoder(encoding === 1 ? 'utf-16le' : 'utf-16be');
      text = decoder.decode(textData).replace(/\x00/g, '');
    } else if (encoding === 3) { // UTF-8
      const decoder = new TextDecoder('utf-8');
      text = decoder.decode(textData).replace(/\x00/g, '');
    }
    
    return text.trim();
  };

  const parseGEOBFrame = (frameData) => {
    let pos = 0;
    const encoding = frameData[pos++];
    
    // MIME type (null-terminated)
    let mimeType = '';
    while (pos < frameData.length && frameData[pos] !== 0) {
      mimeType += String.fromCharCode(frameData[pos++]);
    }
    pos++; // Skip null
    
    // Filename (null-terminated, encoded)
    while (pos < frameData.length && frameData[pos] !== 0) pos++;
    pos++; // Skip null
    
    // Description (null-terminated, encoded)
    let description = '';
    if (encoding === 0 || encoding === 3) {
      while (pos < frameData.length && frameData[pos] !== 0) {
        description += String.fromCharCode(frameData[pos++]);
      }
      pos++;
    } else {
      // UTF-16
      while (pos < frameData.length - 1 && !(frameData[pos] === 0 && frameData[pos+1] === 0)) {
        description += String.fromCharCode(frameData[pos] | (frameData[pos+1] << 8));
        pos += 2;
      }
      pos += 2;
    }
    
    // Rest is the data
    const data = frameData.slice(pos);
    return { mimeType, description, data };
  };

  const parseFLACVorbisComment = (data) => {
    const result = { seratoMarkers2: null, title: '', artist: '' };
    
    // Check FLAC signature
    if (data[0] !== 0x66 || data[1] !== 0x4C || data[2] !== 0x61 || data[3] !== 0x43) { // "fLaC"
      return result;
    }
    
    let pos = 4;
    
    while (pos < data.length) {
      const isLast = (data[pos] & 0x80) !== 0;
      const blockType = data[pos] & 0x7F;
      const blockSize = (data[pos+1] << 16) | (data[pos+2] << 8) | data[pos+3];
      pos += 4;
      
      if (blockType === 4) { // VORBIS_COMMENT
        const vendorLength = data[pos] | (data[pos+1] << 8) | (data[pos+2] << 16) | (data[pos+3] << 24);
        pos += 4 + vendorLength;
        
        const commentCount = data[pos] | (data[pos+1] << 8) | (data[pos+2] << 16) | (data[pos+3] << 24);
        pos += 4;
        
        for (let i = 0; i < commentCount; i++) {
          const commentLength = data[pos] | (data[pos+1] << 8) | (data[pos+2] << 16) | (data[pos+3] << 24);
          pos += 4;
          const comment = new TextDecoder('utf-8').decode(data.slice(pos, pos + commentLength));
          pos += commentLength;
          
          const [key, ...valueParts] = comment.split('=');
          const value = valueParts.join('=');
          
          if (key.toUpperCase() === 'SERATO_MARKERS_V2') {
            // Base64 decode
            try {
              let b64 = value.replace(/\n/g, '');
              while (b64.length % 4) b64 += '=';
              const decoded = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
              // Find actual data after preamble
              const marker = 'Serato Markers2\x00';
              const markerBytes = new TextEncoder().encode(marker);
              let idx = -1;
              for (let j = 0; j < decoded.length - markerBytes.length; j++) {
                let found = true;
                for (let k = 0; k < markerBytes.length; k++) {
                  if (decoded[j + k] !== markerBytes[k]) { found = false; break; }
                }
                if (found) { idx = j + markerBytes.length; break; }
              }
              result.seratoMarkers2 = idx >= 0 ? decoded.slice(idx) : decoded;
            } catch (e) {}
          } else if (key.toUpperCase() === 'TITLE') {
            result.title = value;
          } else if (key.toUpperCase() === 'ARTIST') {
            result.artist = value;
          }
        }
        break;
      }
      
      pos += blockSize;
      if (isLast) break;
    }
    
    return result;
  };

  const parseSeratoMarkers2 = (data) => {
    const cuePoints = [];
    
    if (!data || data.length < 4) return cuePoints;
    
    let stream;
    
    // The GEOB data format is: \x01\x01 + base64-encoded content (with newlines)
    // After decoding: \x01\x01 + entries
    
    if (data[0] === 0x01 && data[1] === 0x01) {
      // Skip version header, base64 decode the rest
      try {
        let b64Data = '';
        for (let i = 2; i < data.length; i++) {
          const c = data[i];
          // Skip nulls, newlines, carriage returns
          if (c !== 0 && c !== 10 && c !== 13) {
            b64Data += String.fromCharCode(c);
          }
        }
        // Add padding if needed
        while (b64Data.length % 4) b64Data += '=';
        
        const decoded = Uint8Array.from(atob(b64Data), c => c.charCodeAt(0));
        
        // Decoded data should also start with \x01\x01
        if (decoded[0] === 0x01 && decoded[1] === 0x01) {
          stream = decoded;
        } else {
          console.log('Decoded data missing version header');
          return cuePoints;
        }
      } catch (e) {
        console.log('Base64 decode error:', e);
        return cuePoints;
      }
    } else {
      // Try direct base64 decode (for some formats)
      try {
        let b64Data = '';
        for (let i = 0; i < data.length; i++) {
          const c = data[i];
          if (c !== 0 && c !== 10 && c !== 13) {
            b64Data += String.fromCharCode(c);
          }
        }
        while (b64Data.length % 4) b64Data += '=';
        
        const decoded = Uint8Array.from(atob(b64Data), c => c.charCodeAt(0));
        if (decoded[0] === 0x01 && decoded[1] === 0x01) {
          stream = decoded;
        } else {
          return cuePoints;
        }
      } catch (e) {
        return cuePoints;
      }
    }
    
    // Now parse the decoded stream starting after \x01\x01
    let pos = 2;
    
    while (pos < stream.length - 4) {
      // Read entry type (null-terminated)
      let entryType = '';
      while (pos < stream.length && stream[pos] !== 0) {
        entryType += String.fromCharCode(stream[pos++]);
      }
      pos++; // Skip null
      
      if (!entryType || pos + 4 > stream.length) break;
      
      // Read payload length (4 bytes big-endian)
      const payloadLength = (stream[pos] << 24) | (stream[pos+1] << 16) | (stream[pos+2] << 8) | stream[pos+3];
      pos += 4;
      
      if (payloadLength <= 0 || pos + payloadLength > stream.length) break;
      const payload = stream.slice(pos, pos + payloadLength);
      pos += payloadLength;
      
      if (entryType === 'CUE' && payload.length >= 13) {
        // CUE format:
        // byte 0: always 0
        // byte 1: cue index
        // bytes 2-5: position in ms (big-endian uint32)
        // byte 6: always 0
        // bytes 7-9: RGB color
        // bytes 10-12: padding or name start
        
        const index = payload[1];
        const positionMs = (payload[2] << 24) | (payload[3] << 16) | (payload[4] << 8) | payload[5];
        const r = payload[7], g = payload[8], b = payload[9];
        
        // Name starts at byte 11 if present
        let name = '';
        if (payload.length > 11) {
          for (let i = 11; i < payload.length && payload[i] !== 0; i++) {
            name += String.fromCharCode(payload[i]);
          }
        }
        
        if (positionMs >= 0 && positionMs < 86400000) { // Sanity check: < 24 hours
          cuePoints.push({
            id: `serato-cue-${index}-${Math.random()}`,
            start: positionMs / 1000,
            name: name || `Cue ${index + 1}`,
            color: `rgb(${r}, ${g}, ${b})`,
            yValue: 100.00,
            curve: 1,
            enabled: true
          });
        }
      }
    }
    
    cuePoints.sort((a, b) => a.start - b.start);
    return cuePoints;
  };

  const handleSeratoUpload = async (event) => {
    const files = event.target.files;
    if (!files || files.length === 0) return;
    
    setLoading(true);
    const newTracks = [];
    
    for (const file of files) {
      try {
        const result = await parseSeratoFile(file);
        if (result && result.cuePoints.length > 0) {
          newTracks.push({
            id: `serato-${Date.now()}-${Math.random()}`,
            name: result.title,
            artist: result.artist,
            album: result.album || '',
            genre: '',
            totalTime: Math.round(result.duration || 0),
            bpm: result.bpm,
            tonality: '',
            location: result.fileName,
            cuePoints: result.cuePoints
          });
        }
      } catch (err) {
        console.error('Error parsing Serato file:', file.name, err);
      }
    }
    
    if (newTracks.length > 0) {
      setTracks(prev => [...prev, ...newTracks]);
      setProjectName(prev => prev === 'Untitled Project' ? 'Serato Import' : prev);
      setHasUnsavedChanges(true);
      alert(`Imported ${newTracks.length} track(s) with Serato cue points!`);
    } else {
      alert('No Serato cue points found in the selected file(s). Make sure the files have been analyzed by Serato DJ.');
    }
    
    setLoading(false);
    if (seratoInputRef.current) seratoInputRef.current.value = '';
  };

  // ============================================================================
  // DENON ENGINE DJ PARSER - Reads cue points from SQLite database
  // ============================================================================

  const handleEngineUpload = async (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    
    setLoading(true);
    
    try {
      // Load sql.js and pako (for zlib decompression) dynamically
      if (!window.initSqlJs) {
        const script = document.createElement('script');
        script.src = 'https://cdnjs.cloudflare.com/ajax/libs/sql.js/1.8.0/sql-wasm.js';
        await new Promise((resolve, reject) => {
          script.onload = resolve;
          script.onerror = reject;
          document.head.appendChild(script);
        });
      }
      
      if (!window.pako) {
        const pakoScript = document.createElement('script');
        pakoScript.src = 'https://cdnjs.cloudflare.com/ajax/libs/pako/2.1.0/pako.min.js';
        await new Promise((resolve, reject) => {
          pakoScript.onload = resolve;
          pakoScript.onerror = reject;
          document.head.appendChild(pakoScript);
        });
      }
      
      const SQL = await window.initSqlJs({
        locateFile: file => `https://cdnjs.cloudflare.com/ajax/libs/sql.js/1.8.0/${file}`
      });
      
      const arrayBuffer = await file.arrayBuffer();
      const db = new SQL.Database(new Uint8Array(arrayBuffer));
      
      // Get list of tables
      const tables = db.exec("SELECT name FROM sqlite_master WHERE type='table'");
      const tableNames = tables[0]?.values.map(v => v[0]) || [];
      
      console.log('Engine DJ Tables:', tableNames);
      
      const newTracks = [];
      const newPlaylists = [];
      
      // ========== PARSE TRACKS ==========
      if (tableNames.includes('Track')) {
        const tracksResult = db.exec("SELECT * FROM Track");
        if (tracksResult[0]) {
          const columns = tracksResult[0].columns;
          const rows = tracksResult[0].values;
          
          for (const row of rows) {
            const track = {};
            columns.forEach((col, i) => track[col] = row[i]);
            
            // Engine DJ stores length in seconds (integer)
            const trackLengthSec = track.length || 0;
            
            newTracks.push({
              id: `engine-${track.id}`,
              name: track.title || track.filename || 'Unknown Track',
              artist: track.artist || '',
              album: track.album || '',
              genre: track.genre || '',
              totalTime: trackLengthSec,
              bpm: track.bpmAnalyzed || track.bpm || 0,
              tonality: track.key ? getKeyName(track.key) : '',
              location: (track.path || '') + (track.filename || ''),
              cuePoints: [],
              engineTrackId: track.id
            });
          }
        }
      }
      
      // ========== PARSE CUE POINTS FROM PerformanceData ==========
      if (tableNames.includes('PerformanceData')) {
        const perfResult = db.exec("SELECT trackId, quickCues FROM PerformanceData");
        if (perfResult[0]) {
          const perfCols = perfResult[0].columns;
          
          for (const perfRow of perfResult[0].values) {
            const trackId = perfRow[0];
            const quickCuesBlob = perfRow[1];
            
            const track = newTracks.find(t => t.engineTrackId === trackId);
            if (!track || !quickCuesBlob) continue;
            
            try {
              // Format: 4-byte size header + zlib compressed data
              const blobData = new Uint8Array(quickCuesBlob);
              if (blobData.length < 5) continue;
              
              // Skip 4-byte size header, decompress the rest
              const compressed = blobData.slice(4);
              const decompressed = window.pako.inflate(compressed);
              
              // Parse decompressed data
              // Header: 8 bytes (last byte = number of cue slots)
              if (decompressed.length < 8) continue;
              
              let pos = 8;
              const cueColors = [
                [244, 211, 56],  // Yellow
                [239, 129, 48],  // Orange
                [170, 85, 196],  // Purple
                [206, 50, 57],   // Red
                [134, 198, 75],  // Green
                [32, 198, 112],  // Teal
                [0, 168, 169],   // Cyan
                [21, 113, 226],  // Blue
              ];
              
              let cueIndex = 0;
              while (pos < decompressed.length - 12) {
                const nameLen = decompressed[pos];
                
                if (nameLen === 0) {
                  // Empty cue slot - skip 13 bytes (1 + 8 + 4)
                  pos += 13;
                  cueIndex++;
                  continue;
                }
                
                if (nameLen > 0 && nameLen < 50) {
                  // Valid cue with name
                  const nameBytes = decompressed.slice(pos + 1, pos + 1 + nameLen);
                  const name = new TextDecoder('utf-8').decode(nameBytes);
                  pos += 1 + nameLen;
                  
                  // Position: 8-byte big-endian double (in samples at 44100 Hz)
                  const posBytes = decompressed.slice(pos, pos + 8);
                  const dataView = new DataView(posBytes.buffer, posBytes.byteOffset, 8);
                  const positionSamples = dataView.getFloat64(0, false); // big-endian
                  const positionSec = positionSamples / 44100;
                  pos += 8;
                  
                  // Color: 4-byte ARGB (big-endian)
                  const colorBytes = decompressed.slice(pos, pos + 4);
                  const r = colorBytes[1];
                  const g = colorBytes[2];
                  const b = colorBytes[3];
                  pos += 4;
                  
                  if (positionSec >= 0 && positionSec < 86400) { // Sanity check: < 24 hours
                    track.cuePoints.push({
                      id: `engine-cue-${trackId}-${cueIndex}-${Math.random()}`,
                      start: positionSec,
                      name: name || `Cue ${cueIndex + 1}`,
                      color: `rgb(${r}, ${g}, ${b})`,
                      yValue: 100.00,
                      curve: 1,
                      enabled: true
                    });
                  }
                  
                  cueIndex++;
                } else {
                  break;
                }
              }
              
              track.cuePoints.sort((a, b) => a.start - b.start);
              
            } catch (e) {
              console.log(`Error parsing cues for track ${trackId}:`, e);
            }
          }
        }
      }
      
      // ========== PARSE PLAYLISTS ==========
      if (tableNames.includes('Playlist') && tableNames.includes('PlaylistEntity')) {
        const playlistResult = db.exec("SELECT id, title FROM Playlist WHERE title IS NOT NULL");
        if (playlistResult[0]) {
          for (const plRow of playlistResult[0].values) {
            const playlistId = plRow[0];
            const playlistTitle = plRow[1];
            
            // Get tracks in this playlist
            const entityResult = db.exec(`SELECT trackId FROM PlaylistEntity WHERE listId = ${playlistId}`);
            const trackIds = entityResult[0]?.values.map(v => `engine-${v[0]}`) || [];
            
            if (trackIds.length > 0 || playlistTitle) {
              newPlaylists.push({
                type: 'playlist',
                name: playlistTitle || `Playlist ${playlistId}`,
                path: playlistTitle || `Playlist ${playlistId}`,
                trackIds: trackIds
              });
            }
          }
        }
      }
      
      db.close();
      
      // Helper to convert Engine DJ key number to musical key name
      function getKeyName(keyNum) {
        const keys = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B',
                      'Cm', 'C#m', 'Dm', 'Ebm', 'Em', 'Fm', 'F#m', 'Gm', 'G#m', 'Am', 'Bbm', 'Bm'];
        return keys[keyNum - 1] || '';
      }
      
      if (newTracks.length > 0) {
        setTracks(prev => [...prev, ...newTracks]);
        if (newPlaylists.length > 0) {
          setPlaylists(prev => [...prev, ...newPlaylists]);
        }
        setProjectName(prev => prev === 'Untitled Project' ? 'Engine DJ Import' : prev);
        setHasUnsavedChanges(true);
        
        const withCues = newTracks.filter(t => t.cuePoints.length > 0).length;
        const withLength = newTracks.filter(t => t.totalTime > 0).length;
        const totalCues = newTracks.reduce((sum, t) => sum + t.cuePoints.length, 0);
        
        alert(`✓ Imported from Engine DJ:\n• ${newTracks.length} tracks\n• ${withLength} with duration\n• ${withCues} with cue points (${totalCues} total)\n• ${newPlaylists.length} playlist(s)`);
      } else {
        alert('No tracks found in the Engine DJ database.');
      }
    } catch (err) {
      console.error('Engine DJ import error:', err);
      alert('Error reading Engine DJ database: ' + err.message);
    }
    
    setLoading(false);
    if (engineInputRef.current) engineInputRef.current.value = '';
  };

  // ============================================================================
  // SHOWKONTROL CUE PARSER - Reads cue points from .cue files
  // ============================================================================
  
  const [showDurationModal, setShowDurationModal] = useState(false);
  const [pendingShowKontrolData, setPendingShowKontrolData] = useState(null);
  const [showResolumeModal, setShowResolumeModal] = useState(false);
  const [pendingResolumeData, setPendingResolumeData] = useState(null);
  const [durationMinutes, setDurationMinutes] = useState(0);
  const [durationSeconds, setDurationSeconds] = useState(0);
  const [durationMs, setDurationMs] = useState(0);
  
  const handleShowKontrolUpload = (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    
    setLoading(true);
    const reader = new FileReader();
    
    reader.onload = (e) => {
      try {
        const content = e.target?.result;
        if (typeof content !== 'string') {
          alert('Error reading ShowKontrol file.');
          setLoading(false);
          return;
        }
        
        // ShowKontrol uses \r line endings
        const lines = content.split(/\r|\n|\r\n/).filter(line => line.trim());
        const cuePoints = [];
        let maxTimeMs = 0;
        let cue0DurationMs = null;
        
        for (const line of lines) {
          // Format: HH:MM:SS:FF,compact,milliseconds,name,TAG,commands,,,,,
          // If name is CUE0 and field 4 has a time instead of TAG, use it as duration
          const parts = line.split(',');
          if (parts.length < 4) continue;
          
          const timecode = parts[0]; // HH:MM:SS:FF
          const milliseconds = parseInt(parts[2]) || 0;
          const cueName = parts[3] || `Cue ${cuePoints.length + 1}`;
          const tagOrTime = parts[4] || '';
          const commands = parts[5] || '';
          
          // Check if this is CUE0 with a duration time instead of TAG
          if (cueName === 'CUE0' && tagOrTime && tagOrTime !== 'TAG') {
            // Try to parse time from field 4 (MM:SS:MS or MM:SS format)
            const timeMatchMs = tagOrTime.match(/^(\d+):(\d{2}):(\d+)$/);
            const timeMatchNoMs = tagOrTime.match(/^(\d+):(\d{2})$/);
            if (timeMatchMs) {
              const minutes = parseInt(timeMatchMs[1]) || 0;
              const seconds = parseInt(timeMatchMs[2]) || 0;
              const milliseconds = parseInt(timeMatchMs[3]) || 0;
              cue0DurationMs = (minutes * 60 + seconds) * 1000 + milliseconds;
            } else if (timeMatchNoMs) {
              const minutes = parseInt(timeMatchNoMs[1]) || 0;
              const seconds = parseInt(timeMatchNoMs[2]) || 0;
              cue0DurationMs = (minutes * 60 + seconds) * 1000;
            }
          }
          
          // Track max time to determine duration suggestion
          if (milliseconds > maxTimeMs) {
            maxTimeMs = milliseconds;
          }
          
          // Skip CUE0 if it's at position 0:00:000
          if (cueName === 'CUE0' && milliseconds === 0) {
            continue;
          }
          
          cuePoints.push({
            id: `showkontrol-cue-${Date.now()}-${Math.random()}`,
            start: milliseconds / 1000,
            name: cueName,
            color: 'rgb(239, 40, 138)', // ShowKontrol pink
            yValue: 0,
            curve: 1,
            enabled: true,
            commands: commands // Store commands for reference
          });
        }
        
        // Check if there's a cue at position 0, if not add Start
        const hasCueAtZero = cuePoints.some(cue => cue.start === 0);
        if (!hasCueAtZero) {
          cuePoints.unshift({
            id: `showkontrol-start-${Date.now()}`,
            start: 0,
            name: 'Start',
            color: 'rgb(239, 40, 138)',
            yValue: 0,
            curve: 1,
            enabled: true
          });
        }
        
        if (cuePoints.length > 0) {
          // Sort by position
          cuePoints.sort((a, b) => a.start - b.start);
          
          // Use CUE0 duration if found, otherwise suggest based on last cue + buffer
          const suggestedDurationMs = cue0DurationMs !== null ? cue0DurationMs : 60000;
          const suggestedMinutes = Math.floor(suggestedDurationMs / 60000);
          const suggestedSeconds = Math.floor((suggestedDurationMs % 60000) / 1000);
          const suggestedMs = suggestedDurationMs % 1000;
          
          // Store data and show duration modal
          setPendingShowKontrolData({
            cuePoints,
            fileName: file.name
          });
          setDurationMinutes(suggestedMinutes);
          setDurationSeconds(suggestedSeconds);
          setDurationMs(suggestedMs);
          setShowDurationModal(true);
        } else {
          alert('No cue points found in the ShowKontrol file.');
        }
      } catch (err) {
        console.error('ShowKontrol import error:', err);
        alert('Error reading ShowKontrol file: ' + err.message);
      }
      
      setLoading(false);
      if (showKontrolInputRef.current) showKontrolInputRef.current.value = '';
    };
    
    reader.readAsText(file);
  };
  
  const confirmShowKontrolImport = () => {
    if (!pendingShowKontrolData) return;
    
    const duration = (durationMinutes * 60) + durationSeconds + (durationMs / 1000);
    const { cuePoints, fileName } = pendingShowKontrolData;
    
    // Always add End cue at track duration (X=1) if not already present
    const hasCueAtEnd = cuePoints.some(cue => Math.abs(cue.start - duration) < 0.001);
    if (!hasCueAtEnd) {
      cuePoints.push({
        id: `showkontrol-end-${Date.now()}`,
        start: duration,
        name: 'End',
        color: 'rgb(239, 40, 138)',
        yValue: 0,
        curve: 1,
        enabled: true
      });
    }
    
    // Create a virtual track for the ShowKontrol cues
    const trackName = fileName.replace('.cue', '');
    const newTrack = {
      id: `showkontrol-${Date.now()}`,
      name: trackName,
      artist: 'ShowKontrol Import',
      album: '',
      genre: '',
      totalTime: duration,
      bpm: 0,
      tonality: '',
      location: fileName,
      cuePoints: cuePoints
    };
    
    setTracks(prev => [...prev, newTrack]);
    setProjectName(prev => prev === 'Untitled Project' ? trackName : prev);
    setHasUnsavedChanges(true);
    
    // Close modal and clear pending data
    setShowDurationModal(false);
    setPendingShowKontrolData(null);
    
    alert(`✓ Imported from ShowKontrol:\n• ${cuePoints.length} cue point(s)\n• Duration: ${durationMinutes}:${String(durationSeconds).padStart(2, '0')}:${String(durationMs).padStart(3, '0')}`);
  };
  
  const cancelShowKontrolImport = () => {
    setShowDurationModal(false);
    setPendingShowKontrolData(null);
    setDurationMinutes(0);
    setDurationSeconds(0);
    setDurationMs(0);
  };

  // Parse Resolume Envelope XML
  const handleResolumeEnvelopeImport = (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    
    setLoading(true);
    const reader = new FileReader();
    
    reader.onload = (e) => {
      try {
        const xmlString = e.target?.result;
        if (typeof xmlString !== 'string') {
          alert('Error reading Resolume envelope file.');
          setLoading(false);
          return;
        }
        
        const parser = new DOMParser();
        const xmlDoc = parser.parseFromString(xmlString, 'text/xml');
        
        // Check for parse errors
        const parseError = xmlDoc.querySelector('parsererror');
        if (parseError) {
          alert('Invalid XML file.');
          setLoading(false);
          return;
        }
        
        // Get preset name
        const presetElement = xmlDoc.querySelector('Preset');
        const envelopeName = presetElement?.getAttribute('name') || file.name.replace('.xml', '');
        
        // Get all points
        const pointElements = xmlDoc.querySelectorAll('point');
        if (pointElements.length === 0) {
          alert('No envelope points found in the file.');
          setLoading(false);
          return;
        }
        
        // Parse points
        const points = Array.from(pointElements).map((point, index) => ({
          x: parseFloat(point.getAttribute('x')) || 0,
          y: parseFloat(point.getAttribute('y')) || 0,
          curve: parseInt(point.getAttribute('curve')) || 1
        }));
        
        // Sort by x position
        points.sort((a, b) => a.x - b.x);
        
        // Store data and show duration modal for Resolume import
        setPendingResolumeData({
          points,
          envelopeName,
          fileName: file.name
        });
        
        // Default to 60 seconds duration
        setDurationMinutes(1);
        setDurationSeconds(0);
        setDurationMs(0);
        setShowResolumeModal(true);
        
      } catch (err) {
        console.error('Resolume envelope import error:', err);
        alert('Error reading Resolume envelope file: ' + err.message);
      }
      
      setLoading(false);
      if (resolumeInputRef.current) resolumeInputRef.current.value = '';
    };
    
    reader.readAsText(file);
  };
  
  const confirmResolumeImport = () => {
    if (!pendingResolumeData) return;
    
    const duration = (durationMinutes * 60) + durationSeconds + (durationMs / 1000);
    const { points, envelopeName } = pendingResolumeData;
    
    // Convert points to cue points
    const cuePoints = points.map((point, index) => ({
      id: `resolume-cue-${Date.now()}-${index}`,
      start: point.x * duration, // Convert normalized x to seconds
      name: index === 0 ? 'Start' : index === points.length - 1 ? 'End' : `Point ${index}`,
      color: '#ffd700', // Gold for Resolume imports
      yValue: point.y * 100,
      curve: point.curve,
      enabled: true
    }));
    
    // Create envelope mode
    createEnvelope();
    
    // Set the cue points and other data
    setTimeout(() => {
      setCuePoints(cuePoints);
      setTrackDuration(duration);
      setPresetName(envelopeName);
      setProjectName(envelopeName);
      setGeneratedXml(''); // Clear any existing XML
      setHasUnsavedChanges(true);
    }, 100);
    
    // Close modal
    setShowResolumeModal(false);
    setPendingResolumeData(null);
    
    alert(`✓ Imported Resolume envelope:\n• ${points.length} point(s)\n• Duration: ${durationMinutes}:${String(durationSeconds).padStart(2, '0')}`);
  };
  
  const cancelResolumeImport = () => {
    setShowResolumeModal(false);
    setPendingResolumeData(null);
    setDurationMinutes(0);
    setDurationSeconds(0);
    setDurationMs(0);
  };

  const handleXmlUpload = (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    setLoading(true);
    const reader = new FileReader();
    reader.onload = (e) => {
      const xmlString = e.target?.result;
      if (typeof xmlString === 'string') {
        const { tracks: parsedTracks, playlists: parsedPlaylists } = parseRekordboxXml(xmlString);
        setTracks(parsedTracks);
        setPlaylists(parsedPlaylists);
        setSelectedTrack(null);
        setCuePoints([]);
        setTrackDuration(0);
        setAudioStatus('idle');
        setAudioFileName('');
        setAudioError('');
        setGeneratedXml('');
        setSelectedPlaylist('all');
        setSearchQuery('');
        setProjectName(file.name.replace('.xml', ''));
        setHasUnsavedChanges(true);
      }
      setLoading(false);
    };
    reader.onerror = () => { alert('Error reading file'); setLoading(false); };
    reader.readAsText(file);
    if (xmlInputRef.current) xmlInputRef.current.value = '';
  };

  const clearProject = () => {
    setTracks([]);
    setPlaylists([]);
    setSelectedTrack(null);
    setCuePoints([]);
    setTrackDuration(0);
    setAudioStatus('idle');
    setAudioFileName('');
    setAudioError('');
    setGeneratedXml('');
    setPresetName('New Envelope');
    setSelectedPointIndex(null);
    setSelectedPlaylist('all');
    setSearchQuery('');
    setProjectName('Untitled Project');
    setHasUnsavedChanges(false);
    setExpandedFolders({});
    setEnvelopeMode(false);
    setNewCueSec(0);
    setNewCueMs(0);
    setLockYAxis(false);
    setStateHistory([]);
    setStateFuture([]);
    if (xmlInputRef.current) xmlInputRef.current.value = '';
    if (audioInputRef.current) audioInputRef.current.value = '';
    if (seratoInputRef.current) seratoInputRef.current.value = '';
    if (engineInputRef.current) engineInputRef.current.value = '';
    if (showKontrolInputRef.current) showKontrolInputRef.current.value = '';
    if (resolumeInputRef.current) resolumeInputRef.current.value = '';
    setShowDurationModal(false);
    setPendingShowKontrolData(null);
    setShowResolumeModal(false);
    setPendingResolumeData(null);
    setDurationMinutes(0);
    setDurationSeconds(0);
    setDurationMs(0);
  };

  const createEnvelope = () => {
    // Create a new envelope (virtual track for manual cue point creation)
    const envelopeId = `envelope-${Date.now()}`;
    const defaultDuration = 60; // Default 60 seconds
    
    // Create cue points at x=0 and x=1 (required by Resolume)
    const initialCuePoints = [
      {
        id: `cue-start-${Date.now()}`,
        start: 0,
        name: 'Start',
        color: 'rgb(30, 215, 96)',
        yValue: 0,
        curve: 1,
        enabled: true
      },
      {
        id: `cue-end-${Date.now()}`,
        start: defaultDuration,
        name: 'End',
        color: 'rgb(30, 215, 96)',
        yValue: 0,
        curve: 1,
        enabled: true
      }
    ];
    
    const newEnvelope = {
      id: envelopeId,
      name: projectName,
      artist: '',
      album: '',
      genre: '',
      totalTime: defaultDuration,
      bpm: 0,
      tonality: '',
      location: '',
      cuePoints: initialCuePoints
    };
    
    setSelectedTrack(newEnvelope);
    setCuePoints(initialCuePoints);
    setTrackDuration(defaultDuration);
    setPresetName(projectName);
    setEnvelopeMode(true);
    setGeneratedXml('');
    setSelectedPointIndex(null);
    setHasUnsavedChanges(true);
    setNewCueSec(0);
    setNewCueMs(0);
    setLockYAxis(false);
  };

  // Check if a cue already exists at the given position
  const cueExistsAtPosition = (seconds) => {
    const tolerance = 0.001; // 1ms tolerance
    // Special handling for start (0) and end (trackDuration)
    if (seconds <= tolerance) {
      return cuePoints.some(cue => cue.start <= tolerance);
    }
    if (seconds >= trackDuration - tolerance) {
      return cuePoints.some(cue => cue.start >= trackDuration - tolerance);
    }
    return cuePoints.some(cue => Math.abs(cue.start - seconds) < tolerance);
  };

  // Save current state to history (for undo)
  const saveToHistory = () => {
    const currentState = {
      cuePoints: cuePoints,
      trackDuration: trackDuration,
      presetName: presetName,
      projectName: projectName
    };
    setStateHistory(prev => [...prev, currentState].slice(-50)); // Keep last 50 states
    setStateFuture([]); // Clear redo stack when new action is performed
  };

  // Undo - restore previous state
  const undo = () => {
    if (stateHistory.length === 0) return;
    
    const currentState = {
      cuePoints: cuePoints,
      trackDuration: trackDuration,
      presetName: presetName,
      projectName: projectName
    };
    const previousState = stateHistory[stateHistory.length - 1];
    setStateHistory(prev => prev.slice(0, -1));
    setStateFuture(prev => [currentState, ...prev]);
    
    setCuePoints(previousState.cuePoints);
    setTrackDuration(previousState.trackDuration);
    setPresetName(previousState.presetName);
    setProjectName(previousState.projectName);
    setHasUnsavedChanges(true);
  };

  // Redo - restore next state
  const redo = () => {
    if (stateFuture.length === 0) return;
    
    const currentState = {
      cuePoints: cuePoints,
      trackDuration: trackDuration,
      presetName: presetName,
      projectName: projectName
    };
    const nextState = stateFuture[0];
    setStateFuture(prev => prev.slice(1));
    setStateHistory(prev => [...prev, currentState]);
    
    setCuePoints(nextState.cuePoints);
    setTrackDuration(nextState.trackDuration);
    setPresetName(nextState.presetName);
    setProjectName(nextState.projectName);
    setHasUnsavedChanges(true);
  };

  // Keyboard shortcuts for undo/redo
  useEffect(() => {
    const handleKeyDown = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'z' && !e.shiftKey) {
        e.preventDefault();
        undo();
      } else if ((e.ctrlKey || e.metaKey) && e.key === 'z' && e.shiftKey) {
        e.preventDefault();
        redo();
      } else if ((e.ctrlKey || e.metaKey) && e.key === 'y') {
        e.preventDefault();
        redo();
      }
    };
    
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [cuePoints, trackDuration, presetName, projectName, stateHistory, stateFuture]);

  // ========== SECTION LAYOUT MANAGEMENT ==========
  
  // Section configuration
  const sectionConfigs = {
    project: { title: 'PROJECT', stepNumber: '01' },
    browse: { title: 'BROWSE & SELECT TRACK', stepNumber: '02' },
    configure: { title: 'CONFIGURE CUE POINTS', stepNumber: '03' },
    generate: { title: 'EXPORT ENVELOPE', stepNumber: '04' }
  };

  // Toggle section collapsed state
  const toggleSection = (sectionId) => {
    setCollapsedSections(prev => ({
      ...prev,
      [sectionId]: !prev[sectionId]
    }));
  };

  // Move section to a specific column
  const moveToColumn = (sectionId, column) => {
    setSectionColumns(prev => ({
      ...prev,
      [sectionId]: column
    }));
  };

  // Drag start handler
  const handleDragStart = (e, sectionId) => {
    // Prevent dragging when interacting with form elements
    const target = e.target;
    const tagName = target.tagName.toLowerCase();
    if (tagName === 'input' || tagName === 'textarea' || tagName === 'select' || tagName === 'button') {
      e.preventDefault();
      return;
    }
    if (target.closest('input, textarea, select, button')) {
      e.preventDefault();
      return;
    }
    
    setDraggedSection(sectionId);
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', sectionId);
  };

  // Drag over handler - reorder sections
  const handleDragOver = (e, targetSectionId, targetColumn) => {
    e.preventDefault();
    if (!draggedSection || draggedSection === targetSectionId) return;

    // Move to target column if different
    if (targetColumn && sectionColumns[draggedSection] !== targetColumn) {
      setSectionColumns(prev => ({
        ...prev,
        [draggedSection]: targetColumn
      }));
    }

    // Reorder within section list
    setSectionOrder(prev => {
      const newOrder = [...prev];
      const draggedIdx = newOrder.indexOf(draggedSection);
      const targetIdx = newOrder.indexOf(targetSectionId);

      if (draggedIdx !== -1 && targetIdx !== -1) {
        newOrder.splice(draggedIdx, 1);
        newOrder.splice(targetIdx, 0, draggedSection);
      }
      return newOrder;
    });
  };

  // Handle drop on empty column area
  const handleColumnDrop = (e, column) => {
    e.preventDefault();
    if (!draggedSection) return;
    setSectionColumns(prev => ({
      ...prev,
      [draggedSection]: column
    }));
  };

  // Drag end handler
  const handleDragEnd = () => {
    setDraggedSection(null);
  };

  // Get sections filtered by column (exclude configure when spanning in side-by-side mode)
  const leftColumnSections = sectionOrder.filter(id => {
    if (id === 'configure' && sideBySideMode && configureSpanColumns) return false;
    return sectionColumns[id] === 'left';
  });
  const rightColumnSections = sectionOrder.filter(id => {
    if (id === 'configure' && sideBySideMode && configureSpanColumns) return false;
    return sectionColumns[id] === 'right';
  });

  // Calculate arrow direction for a section pointing to the next section
  // Fixed logical order: project → browse → configure → generate
  const logicalOrder = ['project', 'browse', 'configure', 'generate'];
  
  const getArrowForSection = (sectionId) => {
    const currentLogicalIndex = logicalOrder.indexOf(sectionId);
    
    // Last section (generate/export) or not found - show diamond
    if (currentLogicalIndex === -1 || currentLogicalIndex === logicalOrder.length - 1) {
      return '◇';
    }
    
    const nextSectionId = logicalOrder[currentLogicalIndex + 1];
    const currentColumn = sectionColumns[sectionId] || 'left';
    const nextColumn = sectionColumns[nextSectionId] || 'left';
    
    // In single column mode, check visual order
    if (!sideBySideMode) {
      const currentVisualIndex = sectionOrder.indexOf(sectionId);
      const nextVisualIndex = sectionOrder.indexOf(nextSectionId);
      return nextVisualIndex > currentVisualIndex ? '↓' : '↑';
    }
    
    // Get positions within columns (visual positions)
    const leftSections = sectionOrder.filter(id => (sectionColumns[id] || 'left') === 'left');
    const rightSections = sectionOrder.filter(id => sectionColumns[id] === 'right');
    
    const currentIndexInColumn = currentColumn === 'left' 
      ? leftSections.indexOf(sectionId) 
      : rightSections.indexOf(sectionId);
    const nextIndexInColumn = nextColumn === 'left' 
      ? leftSections.indexOf(nextSectionId) 
      : rightSections.indexOf(nextSectionId);
    
    // Same column - check if up or down
    if (currentColumn === nextColumn) {
      return nextIndexInColumn > currentIndexInColumn ? '↓' : '↑';
    }
    
    // Moving to right column
    if (currentColumn === 'left' && nextColumn === 'right') {
      if (nextIndexInColumn < currentIndexInColumn) {
        return '↗'; // Up and right
      } else if (nextIndexInColumn > currentIndexInColumn) {
        return '↘'; // Down and right
      }
      return '→'; // Same row - straight right
    }
    
    // Moving to left column
    if (currentColumn === 'right' && nextColumn === 'left') {
      if (nextIndexInColumn < currentIndexInColumn) {
        return '↖'; // Up and left
      } else if (nextIndexInColumn > currentIndexInColumn) {
        return '↙'; // Down and left
      }
      return '←'; // Same row - straight left
    }
    
    return '↓'; // Default
  };

  // Add a new cue point at the specified position
  const addCuePoint = () => {
    const positionSec = newCueSec + (newCueMs / 1000);
    addCuePointAt(positionSec);
  };

  // Add a cue point at a specific position (used by both addCuePoint and anchor buttons)
  const addCuePointAt = (positionSec) => {
    if (cueExistsAtPosition(positionSec)) return;
    
    // Snap to exact boundaries
    let finalPosition = positionSec;
    if (positionSec <= 0.001) finalPosition = 0;
    else if (positionSec >= trackDuration - 0.001) finalPosition = trackDuration;
    
    // Count existing cues excluding Start and End
    const cueNumber = cuePoints.filter(c => c.name !== 'Start' && c.name !== 'End').length + 1;
    
    const newCue = {
      id: `cue-manual-${Date.now()}-${Math.random()}`,
      start: finalPosition,
      name: `Cue ${cueNumber}`,
      color: `rgb(30, 215, 96)`,
      yValue: 0,
      curve: 1,
      enabled: true
    };
    
    saveToHistory();
    setCuePoints(prev => [...prev, newCue].sort((a, b) => a.start - b.start));
    setHasUnsavedChanges(true);
  };

  // Update preset name when project name changes in envelope mode
  useEffect(() => {
    if (envelopeMode && selectedTrack) {
      setPresetName(projectName);
    }
  }, [projectName, envelopeMode, selectedTrack]);

  // Update End cue point position when envelope duration changes
  useEffect(() => {
    if (envelopeMode && cuePoints.length > 0) {
      // Find the End cue point (the one at the furthest position)
      const endCueIndex = cuePoints.findIndex(cue => cue.name === 'End');
      if (endCueIndex !== -1) {
        setCuePoints(prev => {
          const updated = [...prev];
          updated[endCueIndex] = { ...updated[endCueIndex], start: trackDuration };
          return updated;
        });
      }
    }
  }, [trackDuration, envelopeMode]);

  // Electron menu command handlers
  useEffect(() => {
    if (typeof window !== 'undefined' && window.electronAPI) {
      const api = window.electronAPI;
      
      // Load default paths
      api.getDefaultPaths().then(paths => {
        if (paths.xml) setDefaultXmlPath(paths.xml);
        if (paths.skCue) setDefaultSkCuePath(paths.skCue);
      });
      
      // Menu commands
      api.onMenuNew(() => clearProject());
      api.onMenuSave(() => saveProject());
      api.onMenuUndo(() => undo());
      api.onMenuRedo(() => redo());
      api.onMenuCreateEnvelope(() => createEnvelope());
      api.onMenuAddCue(() => addCuePoint());
      api.onMenuToggleLockX((checked) => setLockXAxis(checked));
      api.onMenuToggleLockY((checked) => setLockYAxis(checked));
      
      // File operations
      api.onFileOpened((data) => {
        try {
          const projectData = JSON.parse(data.content);
          loadProjectData(projectData, data.path);
        } catch (err) {
          console.error('Error loading project:', err);
        }
      });
      
      api.onRequestProjectData(async () => {
        const projectData = {
          version: '3.0',
          name: projectName,
          savedAt: new Date().toISOString(),
          tracks: tracks,
          playlists: playlists,
          selectedTrackId: selectedTrack?.id || null,
          cuePoints: cuePoints,
          trackDuration: trackDuration,
          presetName: presetName
        };
        const result = await api.saveProject({
          content: JSON.stringify(projectData, null, 2),
          suggestedName: projectName.replace(/[^a-zA-Z0-9]/g, '_')
        });
        if (result.success) {
          setHasUnsavedChanges(false);
          api.showMessage({ type: 'info', title: 'Saved', message: `Project saved to ${result.path}` });
        }
      });
      
      api.onRequestXmlExport(async () => {
        if (!generatedXml) {
          generateResolumeXml();
        }
        if (generatedXml) {
          const result = await api.exportXml({
            content: generatedXml,
            suggestedName: presetName.replace(/[^a-zA-Z0-9]/g, '_')
          });
          if (result.success) {
            api.showMessage({ type: 'info', title: 'Exported', message: `XML exported to ${result.path}` });
          }
        }
      });
      
      api.onRequestSkCueExport(async () => {
        const content = generateShowKontrolContent();
        if (content) {
          const result = await api.exportSkCue({
            content: content,
            suggestedName: presetName.replace(/[^a-zA-Z0-9]/g, '_')
          });
          if (result.success) {
            api.showMessage({ type: 'info', title: 'Exported', message: `ShowKontrol cue exported to ${result.path}` });
          }
        }
      });
      
      // Handle file imports from menu
      api.onImportFiles(async (data) => {
        const { type, paths } = data;
        if (!paths || paths.length === 0) return;
        
        if (type === 'resolume') {
          // Read and parse Resolume envelope XML
          const result = await api.readFile(paths[0]);
          if (result.success) {
            const xmlString = atob(result.content);
            // Trigger the same import logic as the UI button
            const parser = new DOMParser();
            const xmlDoc = parser.parseFromString(xmlString, 'text/xml');
            const parseError = xmlDoc.querySelector('parsererror');
            if (parseError) {
              api.showMessage({ type: 'error', title: 'Error', message: 'Invalid XML file.' });
              return;
            }
            const presetElement = xmlDoc.querySelector('Preset');
            const envelopeName = presetElement?.getAttribute('name') || paths[0].split('/').pop().replace('.xml', '');
            const pointElements = xmlDoc.querySelectorAll('point');
            if (pointElements.length === 0) {
              api.showMessage({ type: 'error', title: 'Error', message: 'No envelope points found in the file.' });
              return;
            }
            const points = Array.from(pointElements).map((point) => ({
              x: parseFloat(point.getAttribute('x')) || 0,
              y: parseFloat(point.getAttribute('y')) || 0,
              curve: parseInt(point.getAttribute('curve')) || 1
            }));
            points.sort((a, b) => a.x - b.x);
            setPendingResolumeData({ points, envelopeName, fileName: paths[0].split('/').pop() });
            setDurationMinutes(1);
            setDurationSeconds(0);
            setDurationMs(0);
            setShowResolumeModal(true);
          }
        }
        // Other import types can be added here
      });
      
      return () => {
        // Cleanup listeners
        api.removeAllListeners('menu-new');
        api.removeAllListeners('menu-save');
        api.removeAllListeners('menu-undo');
        api.removeAllListeners('menu-redo');
        api.removeAllListeners('menu-create-envelope');
        api.removeAllListeners('menu-add-cue');
        api.removeAllListeners('menu-toggle-lock-x');
        api.removeAllListeners('menu-toggle-lock-y');
        api.removeAllListeners('file-opened');
        api.removeAllListeners('request-project-data');
        api.removeAllListeners('request-xml-export');
        api.removeAllListeners('request-skcue-export');
        api.removeAllListeners('import-files');
      };
    }
  }, [projectName, tracks, playlists, selectedTrack, cuePoints, trackDuration, presetName, generatedXml]);

  // Helper to load project data (shared between web and Electron)
  const loadProjectData = (projectData, filePath = null) => {
    setTracks(projectData.tracks || []);
    setPlaylists(projectData.playlists || []);
    setCuePoints(projectData.cuePoints || []);
    setTrackDuration(projectData.trackDuration || 0);
    setPresetName(projectData.presetName || 'New Envelope');
    setProjectName(projectData.name || 'Loaded Project');
    
    if (projectData.selectedTrackId && projectData.tracks) {
      const track = projectData.tracks.find(t => t.id === projectData.selectedTrackId);
      setSelectedTrack(track || null);
    } else {
      setSelectedTrack(null);
    }
    
    setHasUnsavedChanges(false);
    setStateHistory([]);
    setStateFuture([]);
  };

  // Generate ShowKontrol content (extracted for reuse)
  const generateShowKontrolContent = () => {
    if (cuePoints.length === 0) return null;
    
    const toTimecode = (seconds) => {
      const totalFrames = Math.round(seconds * 30);
      const frames = totalFrames % 30;
      const totalSeconds = Math.floor(totalFrames / 30);
      const secs = totalSeconds % 60;
      const totalMinutes = Math.floor(totalSeconds / 60);
      const mins = totalMinutes % 60;
      const hours = Math.floor(totalMinutes / 60);
      
      return {
        formatted: `${String(hours).padStart(2, '0')}:${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}:${String(frames).padStart(2, '0')}`,
        compact: `${String(hours).padStart(2, '0')}${String(mins).padStart(2, '0')}${String(secs).padStart(2, '0')}${String(frames).padStart(2, '0')}`,
        milliseconds: Math.round(seconds * 1000)
      };
    };
    
    const lines = cuePoints
      .filter(cue => cue.enabled)
      .map((cue, index) => {
        const tc = toTimecode(cue.start);
        const cueName = cue.name || `CUE${index + 1}`;
        return `${tc.formatted},${tc.compact},${tc.milliseconds},${cueName.replace(/,/g, ' ')},TAG,,,,,,`;
      });
    
    return lines.join('\r');
  };

  // Save project to JSON file
  const saveProject = async () => {
    const projectData = {
      version: '3.0',
      name: projectName,
      savedAt: new Date().toISOString(),
      tracks: tracks,
      playlists: playlists,
      selectedTrackId: selectedTrack?.id || null,
      cuePoints: cuePoints,
      trackDuration: trackDuration,
      presetName: presetName
    };
    
    // Use Electron native dialog if available
    if (typeof window !== 'undefined' && window.electronAPI) {
      const result = await window.electronAPI.saveProject({
        content: JSON.stringify(projectData, null, 2),
        suggestedName: projectName.replace(/[^a-zA-Z0-9]/g, '_')
      });
      if (result.success) {
        setHasUnsavedChanges(false);
      }
      return;
    }
    
    // Fallback to browser download
    const blob = new Blob([JSON.stringify(projectData, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${projectName.replace(/[^a-zA-Z0-9]/g, '_')}.cuesync`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    setHasUnsavedChanges(false);
  };

  // Load project from JSON file
  const loadProject = (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    
    const reader = new FileReader();
    reader.onload = (e) => {
      try {
        const projectData = JSON.parse(e.target?.result);
        setTracks(projectData.tracks || []);
        setPlaylists(projectData.playlists || []);
        setProjectName(projectData.name || 'Loaded Project');
        setCuePoints(projectData.cuePoints || []);
        setTrackDuration(projectData.trackDuration || 0);
        setPresetName(projectData.presetName || 'New Envelope');
        
        if (projectData.selectedTrackId && projectData.tracks) {
          const track = projectData.tracks.find(t => t.id === projectData.selectedTrackId);
          setSelectedTrack(track || null);
        } else {
          setSelectedTrack(null);
        }
        
        setSelectedPlaylist('all');
        setSearchQuery('');
        setHasUnsavedChanges(false);
        setGeneratedXml('');
        setAudioStatus('idle');
        setAudioFileName('');
        setExpandedFolders({});
      } catch (err) {
        alert('Error loading project file: ' + err.message);
      }
    };
    reader.readAsText(file);
    if (projectInputRef.current) projectInputRef.current.value = '';
  };

  const handleTrackSelect = (track) => {
    // Save current cue points back to track before switching
    if (selectedTrack && !envelopeMode) {
      setTracks(prev => prev.map(t => t.id === selectedTrack.id ? { ...t, cuePoints: cuePoints } : t));
    }
    
    setSelectedTrack(track);
    
    // Process cue points: filter out cues at position 0, add Start/End if needed
    let processedCues = track.cuePoints
      .filter(cp => cp.start > 0.001) // Skip cue points at position 0
      .map(cp => ({ ...cp, curve: cp.curve || 1, enabled: cp.enabled !== false }));
    
    // Add Start cue at X=0 if none exists
    const hasCueAtZero = track.cuePoints.some(cp => cp.start <= 0.001 && cp.name === 'Start');
    if (!hasCueAtZero) {
      processedCues.unshift({
        id: `cue-start-${Date.now()}`,
        start: 0,
        name: 'Start',
        color: 'rgb(30, 215, 96)',
        yValue: 0,
        curve: 1,
        enabled: true
      });
    }
    
    // Add End cue at X=1 (track duration) if none exists
    const hasCueAtEnd = track.cuePoints.some(cp => Math.abs(cp.start - track.totalTime) < 0.001 && cp.name === 'End');
    if (!hasCueAtEnd && track.totalTime > 0) {
      processedCues.push({
        id: `cue-end-${Date.now()}`,
        start: track.totalTime,
        name: 'End',
        color: 'rgb(30, 215, 96)',
        yValue: 0,
        curve: 1,
        enabled: true
      });
    }
    
    // Sort by position
    processedCues.sort((a, b) => a.start - b.start);
    
    setCuePoints(processedCues);
    setTrackDuration(track.totalTime);
    setPresetName(track.name.replace(/[^a-zA-Z0-9 ]/g, '').trim() || 'New Envelope');
    setAudioStatus('idle');
    setAudioFileName('');
    setAudioError('');
    setGeneratedXml('');
    setSelectedPointIndex(null);
    setHasUnsavedChanges(true);
    setEnvelopeMode(false);
    setNewCueSec(0);
    setNewCueMs(0);
    setLockYAxis(false);
    if (audioInputRef.current) audioInputRef.current.value = '';
  };

  const handleAudioUpload = async (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    setAudioStatus('loading');
    setAudioFileName(file.name);
    setAudioError('');
    try {
      const arrayBuffer = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error('Failed to read file'));
        reader.readAsArrayBuffer(file);
      });
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) throw new Error('Web Audio API not supported');
      const audioContext = new AudioContextClass();
      try {
        const audioBuffer = await audioContext.decodeAudioData(arrayBuffer);
        setTrackDuration(audioBuffer.duration);
        setAudioStatus('loaded');
        setHasUnsavedChanges(true);
        audioContext.close();
      } catch (decodeError) {
        audioContext.close();
        throw new Error('Could not decode audio file.');
      }
    } catch (error) {
      setAudioStatus('error');
      setAudioError(error.message || 'Unknown error');
    }
    if (audioInputRef.current) audioInputRef.current.value = '';
  };

  const updateCuePointY = (index, value) => {
    const numValue = parseFloat(value);
    const newValue = isNaN(numValue) ? 0 : Math.max(0, Math.min(100, numValue));
    setCuePoints(prev => {
      const updated = [...prev];
      updated[index] = { ...updated[index], yValue: Math.round(newValue * 100) / 100 };
      return updated;
    });
    setHasUnsavedChanges(true);
  };

  const updateCuePointCurve = (index, curveId) => {
    saveToHistory();
    setCuePoints(prev => {
      const updated = [...prev];
      updated[index] = { ...updated[index], curve: parseInt(curveId) };
      return updated;
    });
    setHasUnsavedChanges(true);
  };

  const updateCuePointPosition = (index, value) => {
    const numValue = parseFloat(value);
    if (isNaN(numValue)) return;
    const newPosition = Math.max(0, Math.min(trackDuration, numValue));
    setCuePoints(prev => {
      const updated = [...prev];
      updated[index] = { ...updated[index], start: Math.round(newPosition * 1000) / 1000 };
      // Re-sort by position
      updated.sort((a, b) => a.start - b.start);
      return updated;
    });
    setHasUnsavedChanges(true);
  };

  const toggleCuePointEnabled = (index) => {
    saveToHistory();
    setCuePoints(prev => {
      const updated = [...prev];
      updated[index] = { ...updated[index], enabled: !updated[index].enabled };
      return updated;
    });
    setSelectedPointIndex(null);
    setHasUnsavedChanges(true);
  };

  // Update duration and scale all cue point positions proportionally
  const updateDurationWithScaling = (newDuration) => {
    if (newDuration <= 0 || trackDuration <= 0) {
      setTrackDuration(newDuration);
      return;
    }
    
    const scaleFactor = newDuration / trackDuration;
    
    // Scale all cue point positions
    setCuePoints(prev => prev.map(cue => ({
      ...cue,
      start: Math.round(cue.start * scaleFactor * 1000) / 1000
    })));
    
    setTrackDuration(newDuration);
    setHasUnsavedChanges(true);
  };

  // Get all track IDs in a playlist (including nested folders)
  const getPlaylistTrackIds = (playlist) => {
    if (playlist.type === 'playlist') return playlist.trackIds;
    if (playlist.type === 'folder') {
      return playlist.children.flatMap(child => getPlaylistTrackIds(child));
    }
    return [];
  };

  // Filter and sort tracks
  const filteredTracks = useMemo(() => {
    let result = [...tracks];
    
    // Filter by playlist
    if (selectedPlaylist !== 'all') {
      const findPlaylist = (items, path) => {
        for (const item of items) {
          if (item.path === path) return item;
          if (item.type === 'folder' && item.children) {
            const found = findPlaylist(item.children, path);
            if (found) return found;
          }
        }
        return null;
      };
      
      const playlist = findPlaylist(playlists, selectedPlaylist);
      if (playlist) {
        const trackIds = getPlaylistTrackIds(playlist);
        result = result.filter(t => trackIds.includes(t.id));
      }
    }
    
    // Filter by search
    if (searchQuery.trim()) {
      const query = searchQuery.toLowerCase();
      result = result.filter(t => 
        t.name.toLowerCase().includes(query) ||
        t.artist.toLowerCase().includes(query) ||
        t.album.toLowerCase().includes(query) ||
        t.genre.toLowerCase().includes(query)
      );
    }
    
    // Sort
    result.sort((a, b) => {
      switch (sortBy) {
        case 'name': return a.name.localeCompare(b.name);
        case 'artist': return a.artist.localeCompare(b.artist);
        case 'album': return a.album.localeCompare(b.album);
        case 'bpm': return (b.bpm || 0) - (a.bpm || 0);
        case 'duration': return b.totalTime - a.totalTime;
        case 'cues': return b.cuePoints.length - a.cuePoints.length;
        default: return 0;
      }
    });
    
    return result;
  }, [tracks, selectedPlaylist, searchQuery, sortBy, playlists]);

  const formatTime = (seconds) => {
    if (!seconds || isNaN(seconds)) return '0:00.000';
    const mins = Math.floor(seconds / 60);
    const secs = (seconds % 60).toFixed(3);
    return `${mins}:${secs.padStart(6, '0')}`;
  };

  const getMilliseconds = (seconds) => (!seconds || isNaN(seconds)) ? 0 : Math.round((seconds % 1) * 1000);
  const getWholeSeconds = (seconds) => (!seconds || isNaN(seconds)) ? 0 : Math.floor(seconds);

  const envPoints = useMemo(() => {
    if (!trackDuration || trackDuration === 0) return [{ x: 0, y: 0, curve: 1, isAuto: true }, { x: 1, y: 0, curve: 1, isAuto: true }];
    const enabledCues = cuePoints.filter(cp => cp.enabled);
    const points = enabledCues.map(cp => {
      // Calculate x position, ensuring exact 0 and 1 for start/end
      let x = cp.start / trackDuration;
      if (cp.start <= 0.001) x = 0;  // Snap to exactly 0
      else if (cp.start >= trackDuration - 0.001) x = 1;  // Snap to exactly 1
      else x = Math.min(1, Math.max(0, x));
      
      return {
        x: x,
        y: cp.yValue / 100,
        curve: cp.curve || 1,
        name: cp.name,
        color: cp.color,
        isAuto: false
      };
    });
    points.sort((a, b) => a.x - b.x);
    
    // Resolume requires points at exactly x=0 and x=1
    const hasStartPoint = points.some(p => p.x === 0);
    if (!hasStartPoint) {
      points.unshift({ x: 0, y: 0, curve: 1, isAuto: true });
    }
    
    const hasEndPoint = points.some(p => p.x === 1);
    if (!hasEndPoint) {
      points.push({ x: 1, y: 0, curve: 1, isAuto: true });
    }
    
    return points;
  }, [cuePoints, trackDuration]);

  const curvePath = useMemo(() => {
    if (envPoints.length < 2) return '';
    const width = 800, graphTop = 40, graphBottom = 200, graphHeight = 160;
    let path = '';
    const segments = 60;
    for (let i = 0; i < envPoints.length - 1; i++) {
      const p1 = envPoints[i], p2 = envPoints[i + 1];
      for (let j = 0; j <= segments; j++) {
        const t = j / segments;
        const x = p1.x + (p2.x - p1.x) * t;
        const y = interpolate(x, p1.x, p1.y, p2.x, p2.y, p2.curve);
        const px = 20 + x * 760;
        const py = graphBottom - y * graphHeight;
        path += (i === 0 && j === 0) ? `M ${px} ${py}` : ` L ${px} ${py}`;
      }
    }
    return path;
  }, [envPoints]);

  const handlePointMouseDown = (index, e) => {
    e.preventDefault();
    e.stopPropagation();
    saveToHistory();
    setSelectedPointIndex(index);
    setIsDragging(true);
  };

  useEffect(() => {
    if (!isDragging) return;
    const handleMouseMove = (e) => {
      if (selectedPointIndex === null || !svgRef.current) return;
      const svg = svgRef.current;
      const rect = svg.getBoundingClientRect();
      const viewBoxWidth = 850, viewBoxHeight = 240, viewBoxX = -25;
      const scaleX = viewBoxWidth / rect.width;
      const scaleY = viewBoxHeight / rect.height;
      const mouseX = (e.clientX - rect.left) * scaleX + viewBoxX;
      const mouseY = (e.clientY - rect.top) * scaleY;
      
      let newY = 1 - (mouseY - 40) / 160;
      newY = Math.max(0, Math.min(1, newY));
      
      const envPoint = envPoints[selectedPointIndex];
      if (envPoint && !envPoint.isAuto) {
        const cueIndex = cuePoints.findIndex(cp => cp.enabled && Math.abs(cp.start / trackDuration - envPoint.x) < 0.001);
        if (cueIndex !== -1) {
          setCuePoints(prev => {
            const updated = [...prev];
            const currentCue = updated[cueIndex];
            const updatedCue = { ...currentCue };
            
            // Handle Y-axis movement if not locked
            if (!lockYAxis) {
              updatedCue.yValue = Math.round(newY * 10000) / 100;
            }
            
            // Handle X-axis movement if not locked AND not start/end point
            const isStartOrEnd = cueIndex === 0 || cueIndex === updated.length - 1;
            if (!lockXAxis && !isStartOrEnd) {
              let newX = (mouseX - 20) / 760;
              newX = Math.max(0, Math.min(1, newX));
              const newStartTime = newX * trackDuration;
              
              // Check if new position would conflict with another cue
              const wouldConflict = updated.some((cp, idx) => 
                idx !== cueIndex && cp.enabled && Math.abs(cp.start - newStartTime) < 0.01
              );
              
              if (!wouldConflict) {
                updatedCue.start = Math.round(newStartTime * 1000) / 1000;
              }
            }
            
            updated[cueIndex] = updatedCue;
            return updated;
          });
          setHasUnsavedChanges(true);
        }
      }
    };
    const handleMouseUp = () => setIsDragging(false);
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, [isDragging, selectedPointIndex, envPoints, cuePoints, trackDuration, lockXAxis, lockYAxis]);

  const generateResolumeXml = () => {
    if (!trackDuration || trackDuration === 0) { alert('Please set the track duration first.'); return; }
    
    // Ensure we have points at x=0 and x=1 (Resolume requirement)
    let finalPoints = [...envPoints];
    
    // Check for point at x=0
    if (!finalPoints.some(p => p.x === 0)) {
      finalPoints.unshift({ x: 0, y: 0, curve: 1 });
    }
    
    // Check for point at x=1
    if (!finalPoints.some(p => p.x === 1)) {
      finalPoints.push({ x: 1, y: 0, curve: 1 });
    }
    
    // Sort by x position
    finalPoints.sort((a, b) => a.x - b.x);
    
    const uniqueId = Date.now();
    const pointsXml = finalPoints.map(p => `\t\t\t<point x="${p.x}" y="${p.y}" curve="${p.curve}"/>`).join('\n');
    const xml = `<?xml version="1.0" encoding="utf-8"?>
<Preset name="${presetName}" uniqueId="MOD_ENVELOPE" className="Envelope" default="0">
\t<versionInfo name="Resolume Arena" majorVersion="7" minorVersion="23" microVersion="2" revision="51094"/>
\t<ModifierEnvelope name="ModifierEnvelope" altName="Envelope" uniqueId="${uniqueId}">
\t\t<points>
${pointsXml}
\t\t</points>
\t</ModifierEnvelope>
</Preset>`;
    setGeneratedXml(xml);
  };

  const downloadXml = async () => {
    if (!generatedXml) return;
    
    // Use Electron native dialog if available
    if (typeof window !== 'undefined' && window.electronAPI) {
      const result = await window.electronAPI.exportXml({
        content: generatedXml,
        suggestedName: presetName.replace(/[^a-zA-Z0-9]/g, '_') || 'envelope'
      });
      return;
    }
    
    // Fallback to browser download
    const blob = new Blob([generatedXml], { type: 'application/xml' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${presetName.replace(/[^a-zA-Z0-9]/g, '_') || 'envelope'}.xml`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const downloadShowKontrolCue = async () => {
    if (cuePoints.length === 0) return;
    
    // Convert seconds to ShowKontrol timecode format (HH:MM:SS:FF at 30fps)
    const toTimecode = (seconds) => {
      const totalFrames = Math.round(seconds * 30);
      const frames = totalFrames % 30;
      const totalSeconds = Math.floor(totalFrames / 30);
      const secs = totalSeconds % 60;
      const totalMinutes = Math.floor(totalSeconds / 60);
      const mins = totalMinutes % 60;
      const hours = Math.floor(totalMinutes / 60);
      
      return {
        formatted: `${String(hours).padStart(2, '0')}:${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}:${String(frames).padStart(2, '0')}`,
        compact: `${String(hours).padStart(2, '0')}${String(mins).padStart(2, '0')}${String(secs).padStart(2, '0')}${String(frames).padStart(2, '0')}`,
        milliseconds: Math.round(seconds * 1000)
      };
    };
    
    // Generate .cue file content
    const lines = cuePoints
      .filter(cue => cue.enabled)
      .map((cue, index) => {
        const tc = toTimecode(cue.start);
        const cueName = cue.name || `CUE${index + 1}`;
        // Format: timecode,compact,milliseconds,name,TAG,commands,,,,,
        return `${tc.formatted},${tc.compact},${tc.milliseconds},${cueName.replace(/,/g, ' ')},TAG,,,,,,`;
      });
    
    // ShowKontrol uses \r (carriage return) line endings
    const content = lines.join('\r');
    
    // Use Electron native dialog if available
    if (typeof window !== 'undefined' && window.electronAPI) {
      const result = await window.electronAPI.exportSkCue({
        content: content,
        suggestedName: presetName.replace(/[^a-zA-Z0-9]/g, '_') || 'cues'
      });
      return;
    }
    
    // Fallback to browser download
    const blob = new Blob([content], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${presetName.replace(/[^a-zA-Z0-9]/g, '_') || 'cues'}.cue`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const copyXml = async () => {
    if (!generatedXml) return;
    try {
      await navigator.clipboard.writeText(generatedXml);
      setCopySuccess(true);
      setTimeout(() => setCopySuccess(false), 2000);
    } catch (err) {
      const textarea = document.createElement('textarea');
      textarea.value = generatedXml;
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand('copy');
      document.body.removeChild(textarea);
      setCopySuccess(true);
      setTimeout(() => setCopySuccess(false), 2000);
    }
  };

  const toggleFolder = (path) => {
    setExpandedFolders(prev => ({ ...prev, [path]: !prev[path] }));
  };

  const renderPlaylistTree = (items, level = 0) => {
    return items.map(item => (
      <div key={item.path}>
        <div
          onClick={() => item.type === 'folder' ? toggleFolder(item.path) : setSelectedPlaylist(item.path)}
          style={{
            ...themedStyles.playlistItem,
            paddingLeft: `${12 + level * 16}px`,
            backgroundColor: selectedPlaylist === item.path ? 'rgba(30, 215, 96, 0.2)' : 'transparent',
            borderLeft: selectedPlaylist === item.path ? '2px solid #1ed760' : '2px solid transparent'
          }}
        >
          <span style={themedStyles.playlistIcon}>
            {item.type === 'folder' ? (expandedFolders[item.path] ? '📂' : '📁') : '🎵'}
          </span>
          <span style={themedStyles.playlistName}>{item.name}</span>
          {item.type === 'playlist' && <span style={themedStyles.playlistCount}>{item.trackIds.length}</span>}
        </div>
        {item.type === 'folder' && expandedFolders[item.path] && item.children && (
          <div>{renderPlaylistTree(item.children, level + 1)}</div>
        )}
      </div>
    ));
  };

  const getAudioButtonStyle = () => {
    switch (audioStatus) {
      case 'loading': return { ...themedStyles.audioButton, ...themedStyles.audioButtonLoading };
      case 'loaded': return { ...themedStyles.audioButton, ...themedStyles.audioButtonLoaded };
      case 'error': return { ...themedStyles.audioButton, ...themedStyles.audioButtonError };
      default: return styles.audioButton;
    }
  };

  const getAudioButtonText = () => {
    const musicIcon = (
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="audio-icon">
        <path d="M9 18V5l12-2v13"/>
        <circle cx="6" cy="18" r="3"/>
        <circle cx="18" cy="16" r="3"/>
      </svg>
    );
    switch (audioStatus) {
      case 'loading': return <><span>⏳</span><span>Analyzing...</span></>;
      case 'loaded': return <><span>✓</span><span>{audioFileName}</span></>;
      case 'error': return <><span>⚠</span><span>Error - Try Again</span></>;
      default: return <>{musicIcon}<span>Load Audio File</span></>;
    }
  };

  const getCurveName = (curveId) => CURVE_TYPES.find(c => c.id === curveId)?.name || 'Linear';
  const enabledCount = cuePoints.filter(cp => cp.enabled).length;
  const themedStyles = getThemedStyles(theme);

  // ========== SECTION RENDER FUNCTIONS ==========

  // Render Project Section Content
  const renderProjectContent = () => (
    <div style={themedStyles.projectControls}>
      {/* Main row with all groups */}
      <div style={themedStyles.projectMainRow}>
        {/* Project group */}
        <div style={themedStyles.buttonGroupWithLabel}>
          <span style={themedStyles.buttonGroupLabel}>Project</span>
          <div style={themedStyles.buttonGroupRow}>
            <button onClick={clearProject} style={themedStyles.clearButton} className="clear-btn">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
              <span>New</span>
            </button>
            <label style={themedStyles.openButton} className="open-btn">
              <input ref={projectInputRef} type="file" accept=".cuesync,.json" onChange={loadProject} style={themedStyles.hiddenInput} />
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>
              <span>Open</span>
            </label>
            <button onClick={saveProject} style={themedStyles.saveButton} className="save-btn" disabled={tracks.length === 0 && !envelopeMode}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/></svg>
              <span>Save</span>
            </button>
          </div>
        </div>
        {/* Project Name group */}
        <div style={themedStyles.buttonGroupWithLabel}>
          <span style={themedStyles.buttonGroupLabel}>Project Name</span>
          <div style={themedStyles.projectNameInputRow}>
            <input
              type="text"
              value={projectName}
              onChange={(e) => { setProjectName(e.target.value); setHasUnsavedChanges(true); }}
              onFocus={saveToHistory}
              style={themedStyles.presetInputInline}
              className="preset-input"
            />
          </div>
        </div>
        {/* Design from Scratch group */}
        <div style={themedStyles.buttonGroupWithLabel}>
          <span style={themedStyles.buttonGroupLabel}>Design from Scratch</span>
          <div style={themedStyles.buttonGroupRow}>
            <button onClick={createEnvelope} style={themedStyles.createEnvelopeButton} className="create-envelope-btn" title="Create an envelope for use in Resolume">
              <svg width="20" height="16" viewBox="0 0 36 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M2 4C8 10 14 16 18 18C22 16 28 10 34 4"/>
                <path d="M2 4L2 20C2 21.5 3 22 4 22L32 22C33 22 34 21.5 34 20L34 4"/>
              </svg>
              <span>Create Envelope</span>
            </button>
          </div>
        </div>
        {/* Import Envelope group */}
        <div style={themedStyles.buttonGroupWithLabel}>
          <span style={themedStyles.buttonGroupLabel}>Import Envelope</span>
          <div style={themedStyles.buttonGroupRow}>
            <label style={themedStyles.resolumeImportButton} className="resolume-import-btn">
              <input ref={resolumeInputRef} type="file" accept=".xml" onChange={handleResolumeEnvelopeImport} style={themedStyles.hiddenInput} />
              <svg width="16" height="16" viewBox="0 0 100 100">
                <rect x="0" y="0" width="100" height="100" rx="22" fill="#1a3a35"/>
                <clipPath id="aClip">
                  <path d="M50 12L15 88H32L40 70H60L68 88H85L50 12ZM45 55L50 42L55 55H45Z"/>
                </clipPath>
                <g clipPath="url(#aClip)">
                  <rect x="0" y="0" width="100" height="100" fill="#5de4c7"/>
                  <line x1="10" y1="100" x2="60" y2="0" stroke="#1a3a35" strokeWidth="6"/>
                  <line x1="30" y1="100" x2="80" y2="0" stroke="#1a3a35" strokeWidth="6"/>
                  <line x1="50" y1="100" x2="100" y2="0" stroke="#1a3a35" strokeWidth="6"/>
                  <line x1="70" y1="100" x2="120" y2="0" stroke="#1a3a35" strokeWidth="6"/>
                </g>
              </svg>
              <span>Resolume</span>
            </label>
          </div>
        </div>
        {/* Import Cues group */}
        <div style={themedStyles.buttonGroupWithLabel}>
          <span style={themedStyles.buttonGroupLabel}>Import Cues</span>
          <div style={themedStyles.buttonGroupRow}>
            <label style={themedStyles.importButtonLabel} className="import-btn">
              <input ref={xmlInputRef} type="file" accept=".xml" onChange={handleXmlUpload} style={themedStyles.hiddenInput} />
              <svg width="16" height="16" viewBox="0 0 150 150" fill="currentColor">
                <path d="M105.006,81.466C105.437,72.853 105.433,72.89 103.797,64.444C103.339,62.081 104.235,62.321 106.257,61.102C110.19,58.731 113.691,56.614 114.338,56.223C124.789,49.907 127.626,47.556 127.711,50.466C127.805,53.683 127.659,97.417 127.645,101.5C127.594,116.865 123.795,115.899 110.674,123.796C75.42,145.016 73.49,147.841 72.96,144.443C72.916,144.164 73.082,121.486 73.097,119.49C73.15,112.219 98.079,118.106 105.006,81.466Z" transform="translate(0,10)"/>
                <path d="M58.576,34.975C35.847,40.243 38.779,49.942 33.456,47.588C28.342,45.326 14.316,36.27 12.691,35.221C9.412,33.104 14.074,33.316 53.361,8.264C66.429,-0.069 67.901,2.974 81.279,10.87C98.927,21.286 98.634,21.576 116.277,31.873C118.258,33.029 119.475,34.133 116.215,36.014C96.44,47.422 95.969,49.136 93.877,47.104C81.476,35.061 72.364,33.637 58.576,34.975Z" transform="translate(0,10)"/>
                <path d="M24.999,72.53C25.183,77.143 23.883,83.698 29.893,96.305C36.638,110.453 52.146,115.519 54.561,116.308C58.408,117.565 56.988,120.872 57.16,141.5C57.172,142.986 58.373,147.347 53.661,144.232C39.504,134.874 6.718,118.107 3.835,112.332C1.625,107.907 2.473,107.609 2.616,50.513C2.623,47.498 6.283,50.37 12.655,54.236C23.982,61.107 26.991,61.912 26.477,64.496C25.675,68.525 25.749,68.451 24.999,72.53Z" transform="translate(0,10)"/>
                <path d="M65.494,97.026C32.814,94.574 43.266,47.661 71.522,56.44C87.9,61.529 93.684,92.957 65.494,97.026Z" transform="translate(0,10)"/>
              </svg>
              <span>Rekordbox</span>
            </label>
            <label style={themedStyles.seratoButton} className="serato-btn">
              <input ref={seratoInputRef} type="file" accept=".mp3,.aif,.aiff,.flac,.m4a,.wav" multiple onChange={handleSeratoUpload} style={themedStyles.hiddenInput} />
              <svg width="16" height="16" viewBox="0 0 135 135">
                <circle cx="67.5" cy="67.5" r="66.5" fill="currentColor"/>
                <circle cx="67.5" cy="67.5" r="60" fill={theme === 'light' ? '#f5f5f7' : '#1a1a2e'}/>
                <path d="m116.8261 76.12984c-1.83412.00056-3.32228-1.48424-3.32588-3.31836v-10.5048c-.03293-1.45866.87311-2.77408 2.2477-3.26327 1.73938-.58846 3.62646.34455 4.21492 2.08393.11598.3428.1752.70225.17535 1.06414v10.62c.00068 1.83052-1.48157 3.31559-3.31209 3.31836" fill={theme === 'light' ? '#1d1d1f' : '#fff'}/>
                <path d="m105.66388 87.09008c-.00819 2.02657-1.6577 3.6628-3.68427 3.65461-.54073-.00219-1.07428-.12385-1.5625-.35628-1.26659-.59086-2.06645-1.87214-2.04111-3.26953v-10.94559c-.01509-2.28357-1.87852-4.12254-4.16209-4.10745-2.26763.01498-4.1001 1.85356-4.10752 4.12123v26.2952c.02257 1.72868-1.06023 3.27907-2.691 3.85306-2.13928.76463-4.49336-.34975-5.258-2.48901-.13699-.38326-.21633-.7847-.23545-1.19124l-.00749-.18784v-8.00289c-.10468-2.52773-2.23867-4.492-4.7664-4.38731-.26611.01102-.53077.04523-.79094.10224-2.13165.51159-3.62104 2.43635-3.58131 4.62817v24.30418c.04697 2.53339-1.68507 4.75417-4.15361 5.32565-2.83054.59808-5.60998-1.21169-6.20806-4.04222-.07369-.34875-.11159-.7041-.11311-1.06055v-24.71112c-.01446-2.52628-2.07413-4.56253-4.60042-4.54807-2.45818.01407-4.46571 1.96844-4.54572 4.42535v7.96658l-.00627.15152c-.08072 2.25977-1.97806 4.02623-4.23782 3.94551-2.18513-.07805-3.92332-1.8593-3.94787-4.04568v-26.35908c-.02547-2.28665-1.89982-4.11971-4.18647-4.09423-.24325.00271-.48578.02685-.72478.07214-1.99526.43576-3.40276 2.22319-3.35844 4.265v10.605c.04909 2.01427-1.54401 3.68694-3.55827 3.73602-2.01427.04909-3.68694-1.544-3.73603-3.55827-.00077-.0317-.00113-.06341-.00108-.09512v-39.08152c-.05095-2.01424 1.54062-3.6884 3.55486-3.73935 2.01424-.05094 3.6884 1.54062 3.73934 3.55486.00081.03185.0012.06371.00117.09557v10.68764c-.04433 2.04182 1.36316 3.82927 3.35844 4.26504 2.24682.42571 4.41334-1.05059 4.83905-3.29741.04527-.23898.06941-.48148.07212-.72469v-26.35406c-.02992-1.56581.86591-3.00212 2.28526-3.664 2.05708-.98139 4.52024-.10938 5.50163 1.94769.24068.5045.37637 1.05264.39883 1.61117l.00627.15151v7.96649c.08223 2.52499 2.1958 4.50523 4.72079 4.423 2.45692-.08001 4.41129-2.08755 4.42535-4.54572v-24.7324c-.0349-2.05205 1.16658-3.92412 3.04669-4.74713 2.65852-1.18982 5.77823.00079 6.96805 2.65932.30106.67266.45779 1.40096.46008 2.13791v24.49952c-.03967 2.19154 1.44981 4.1159 3.58131 4.62692 2.4719.54087 4.91425-1.02454 5.45512-3.49644.0573-.26187.09151-.52827.10223-.79613v-7.99537l.00749-.18782c.10673-2.26932 2.03289-4.02244 4.30221-3.91571.40654.01912.80799.09846 1.19124.23545 1.63054.57428 2.71321 2.12448 2.691 3.85305v26.28769c.004 2.28362 1.85847 4.13161 4.14209 4.12762 2.26966-.00397 4.11187-1.83671 4.12753-4.10632v-10.94561c-.02534-1.39739.77452-2.67867 2.04111-3.26953 1.8298-.87114 4.01935-.09399 4.89049 1.73582.23244.48822.3541 1.02179.35628 1.56252z" fill={theme === 'light' ? '#1d1d1f' : '#fff'}/>
                <path d="m21.56144 72.81123c-.00071 1.8345-1.48843 3.32108-3.32293 3.32037-.20304-.00008-.40566-.01878-.60529-.05585-1.60754-.34486-2.74396-1.78233-2.70855-3.42606v-10.29693c-.03541-1.64372 1.10101-3.08118 2.70853-3.42605 1.80407-.33465 3.53785.85656 3.8725 2.66064.03695.19917.0556.40131.05572.60387z" fill={theme === 'light' ? '#1d1d1f' : '#fff'}/>
                <circle cx="67.5" cy="67.5" r="5.67" fill="currentColor"/>
              </svg>
              <span>Serato</span>
            </label>
            <label style={themedStyles.engineButton} className="engine-btn">
              <input ref={engineInputRef} type="file" accept=".db" onChange={handleEngineUpload} style={themedStyles.hiddenInput} />
              <svg width="16" height="18" viewBox="0 0 167 189" fill="currentColor">
                <g transform="matrix(1.005859,0,0,1.005859,21,16)">
                  <path d="M59.528,21.99C22.768,28.688 27.181,57.523 27.181,96.5C27.181,133.888 28.917,139.37 17.5,139.56C8.407,139.711 10.933,134.049 5.554,129.436C1.259,125.753 0.924,125.107 1.195,94.499C1.285,84.415 7.83,86.447 7.845,80.503C7.894,60.634 7.727,60.672 7.389,58.513C7.118,56.783 10.422,32.883 21.514,21.512C26.859,16.033 33.695,7.606 52.499,3.497C80.86,-2.702 102.941,12.997 110.867,25.247C111.835,26.744 116.9,32.272 119.727,44.45C125.91,71.079 116.699,79.063 124.354,84.706C128.796,87.981 126.724,89.245 127.46,120.5C127.601,126.47 126.684,126.338 122.563,130.569C119.552,133.661 123.126,140.093 109.502,139.484C99.913,139.055 102.095,119.272 102.095,116.5C102.095,51.817 103.512,46.749 93.388,34.59C80.068,18.591 60.472,21.939 59.528,21.99Z"/>
                  <path d="M74.835,61.5C74.835,134.494 75.153,135.048 72.31,138.344C69.348,141.778 55.138,145.746 55.004,129.501C54.419,58.605 54.539,57.667 55.328,51.475C56.585,41.617 74.503,41.028 74.822,54.488C74.907,58.082 74.828,57.979 74.835,61.5Z"/>
                  <path d="M88.502,76.134C100.266,77.342 98.508,82.279 98.509,124.5C98.51,147.749 100.896,157.639 85.536,156.262C76.973,155.495 78.418,144.906 78.418,108.5C78.418,86.244 76.472,77.273 88.502,76.134Z"/>
                  <path d="M50.929,147.51C49.393,161.796 31.761,156.559 31.552,149.492C31.112,134.699 31.543,92.459 31.594,87.5C31.765,70.744 50.819,73.872 50.928,86.5C50.964,90.597 50.932,142.63 50.929,147.51Z"/>
                </g>
              </svg>
              <span>Engine DJ</span>
            </label>
            <label style={themedStyles.showKontrolImportButton} className="showkontrol-import-btn">
              <input ref={showKontrolInputRef} type="file" accept=".cue" onChange={handleShowKontrolUpload} style={themedStyles.hiddenInput} />
              <svg width="16" height="16" viewBox="0 0 455 454"><g transform="matrix(3.68042,0,0,3.68042,-1796.433953,-4.224491)"><path d="M500.966,57.564C500.669,65.882 499.426,79.329 513.65,96.382C515.54,98.649 519.265,100.289 516.294,102.21C508.043,107.545 507.326,107.856 505.756,106.238C466.73,66.004 496.747,-1.395 553.51,1.222C565.585,1.778 583.389,8.96 581.366,11.375C580.863,11.976 553.171,29.301 550.708,30.842C546.624,33.397 546.371,31.901 546.348,31.549C545.962,25.622 547.15,14.314 544.557,14.02C543.238,13.871 528.793,16.724 519.845,23.914C502.675,37.71 501.553,54.992 500.966,57.564Z" fill="rgb(239, 40, 138)"/></g><g transform="matrix(3.68042,0,0,3.68042,-1796.433953,-4.224491)"><path d="M609.981,76.6C598.342,122.795 551.469,133.735 520.211,116.982C515.477,114.445 521.051,113.685 547.805,95.925C548.436,95.506 553.444,91.835 553.51,94.498C553.895,110.067 552.529,112.005 555.5,111.703C595.949,107.59 613.181,57.176 585.232,28.756C582.842,26.327 580.836,25.638 583.711,23.815C590.01,19.82 591.221,16.175 596.071,21.907C617.274,46.969 611.159,72.075 609.981,76.6Z" fill="rgb(239, 40, 138)"/></g></svg>
              <span>ShowKontrol</span>
            </label>
          </div>
        </div>
      </div>
      <div style={themedStyles.settingsRow}>
        <div style={themedStyles.settingsGroup}>
          <span style={themedStyles.settingsLabel}>Viewport</span>
          <div style={themedStyles.settingsButtons}>
            <button onClick={() => { setSideBySideMode(false); setConfigureSpanColumns(false); setSectionOrder(defaultSectionOrder); setSectionColumns(defaultSectionColumns); setSavedLayout({ sideBySideMode: false, configureSpanColumns: false, sectionOrder: defaultSectionOrder, sectionColumns: defaultSectionColumns, theme }); }} style={{...themedStyles.settingsBtn, ...(!sideBySideMode ? themedStyles.settingsBtnActive : {})}} className="settings-btn">Reset</button>
            <button onClick={() => { setSideBySideMode(true); setConfigureSpanColumns(false); }} style={{...themedStyles.settingsBtn, ...(sideBySideMode && !configureSpanColumns ? themedStyles.settingsBtnActive : {})}} className="settings-btn">Side-By-Side</button>
            <button onClick={saveViewportLayout} style={themedStyles.settingsBtn} className="settings-btn">Save</button>
            {savedLayout && <button onClick={restoreViewportLayout} style={{...themedStyles.settingsBtn, ...(isLayoutSaved ? themedStyles.settingsBtnActive : {})}} className="settings-btn">Last Saved</button>}
          </div>
        </div>
        <div style={themedStyles.settingsGroup}>
          <span style={themedStyles.settingsLabel}>Theme</span>
          <div style={themedStyles.settingsButtons}>
            <button onClick={() => setTheme('dark')} style={{...themedStyles.settingsBtn, ...(theme === 'dark' ? themedStyles.settingsBtnActive : {})}} className="settings-btn">Dark</button>
            <button onClick={() => setTheme('light')} style={{...themedStyles.settingsBtn, ...(theme === 'light' ? themedStyles.settingsBtnActive : {})}} className="settings-btn">Light</button>
          </div>
        </div>
      </div>
      {tracks.length > 0 && <span style={themedStyles.trackCount}>✓ {tracks.length} track{tracks.length !== 1 ? 's' : ''} loaded</span>}
    </div>
  );

  // Render Browse Section Content
  const renderBrowseContent = () => (
    tracks.length > 0 ? (
      <div style={themedStyles.browserContainer}>
        <div style={themedStyles.sidebar}>
          <div style={themedStyles.sidebarHeader}>Playlists</div>
          <div onClick={() => setSelectedPlaylist('all')} style={{...themedStyles.playlistItem, backgroundColor: selectedPlaylist === 'all' ? 'rgba(30, 215, 96, 0.2)' : 'transparent', borderLeft: selectedPlaylist === 'all' ? '2px solid #1ed760' : '2px solid transparent'}} className="playlist-item">
            <span style={themedStyles.playlistIcon}>📚</span>
            <span style={themedStyles.playlistName}>All Tracks</span>
            <span style={themedStyles.playlistCount}>{tracks.length}</span>
          </div>
          {renderPlaylistTree(playlists)}
        </div>
        <div style={themedStyles.trackBrowser}>
          <div style={themedStyles.searchBar}>
            <input type="text" placeholder="🔍 Search tracks, artists, albums..." value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} style={themedStyles.searchInput} className="search-input"/>
            <select value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={themedStyles.sortSelect}>
              <option value="name">Sort: Name</option>
              <option value="artist">Sort: Artist</option>
              <option value="album">Sort: Album</option>
              <option value="bpm">Sort: BPM</option>
              <option value="duration">Sort: Duration</option>
              <option value="cues">Sort: Cue Count</option>
            </select>
          </div>
          <div style={themedStyles.trackList}>
            {filteredTracks.length === 0 ? (<div style={themedStyles.noResults}>No tracks found</div>) : (
              filteredTracks.map((track) => (
                <div key={track.id} onClick={() => handleTrackSelect(track)} onMouseEnter={() => setHoveredTrack(track.id)} onMouseLeave={() => setHoveredTrack(null)} className="track-item" style={{...themedStyles.trackItem, ...(selectedTrack?.id === track.id ? styles.trackItemSelected : {}), ...(hoveredTrack === track.id && selectedTrack?.id !== track.id ? styles.trackItemHover : {})}}>
                  <div style={themedStyles.trackInfo}>
                    <span style={themedStyles.trackName}>{track.name}</span>
                    <span style={themedStyles.trackMeta}>{track.artist || 'Unknown Artist'} {track.album ? `• ${track.album}` : ''}</span>
                    <span style={themedStyles.trackMeta2}>{track.bpm ? track.bpm.toFixed(1) + ' BPM' : ''} {track.tonality ? `• ${track.tonality}` : ''} • {track.cuePoints.length} cue{track.cuePoints.length !== 1 ? 's' : ''}</span>
                  </div>
                  <span style={themedStyles.trackDurationDisplay}>{Math.floor(track.totalTime / 60)}:{String(track.totalTime % 60).padStart(2, '0')}</span>
                </div>
              ))
            )}
          </div>
          <div style={themedStyles.trackListFooter}>Showing {filteredTracks.length} of {tracks.length} tracks</div>
        </div>
      </div>
    ) : (<div style={themedStyles.emptyState}>Import tracks from Rekordbox, Serato, Engine DJ, or ShowKontrol to browse</div>)
  );

  // Render Configure Section Content
  const renderConfigureContent = () => (
    selectedTrack ? (
      <>
        <div style={themedStyles.selectedTrackInfo}>
          <strong>{envelopeMode ? projectName : selectedTrack.name}</strong>
          {!envelopeMode && (<>{' '}by {selectedTrack.artist || 'Unknown'}{selectedTrack.album && <span> • {selectedTrack.album}</span>}</>)}
          {envelopeMode && <span style={themedStyles.envelopeModeBadge}>Manual Envelope</span>}
        </div>
        <div style={themedStyles.durationSection}>
          <div style={themedStyles.durationInfo}>
            <label style={themedStyles.label}>{envelopeMode ? 'Envelope Length' : 'Track Duration'}</label>
            <div style={themedStyles.durationInputGroup}>
              <div style={themedStyles.durationFieldGroup}><input type="number" value={getWholeSeconds(trackDuration)} onChange={(e) => { saveToHistory(); const newSec = parseInt(e.target.value) || 0; updateDurationWithScaling(newSec + getMilliseconds(trackDuration) / 1000); }} onFocus={saveToHistory} min="0" style={themedStyles.durationInput} className="duration-input" /><span style={themedStyles.durationLabel}>sec</span></div>
              <div style={themedStyles.durationFieldGroup}><input type="number" value={getMilliseconds(trackDuration)} onChange={(e) => { saveToHistory(); const ms = Math.min(999, Math.max(0, parseInt(e.target.value) || 0)); updateDurationWithScaling(getWholeSeconds(trackDuration) + ms / 1000); }} onFocus={saveToHistory} min="0" max="999" style={themedStyles.msInput} className="duration-input" /><span style={themedStyles.durationLabel}>ms</span></div>
              <span style={themedStyles.durationFormatted}>= {formatTime(trackDuration)}</span>
            </div>
          </div>
          <div style={themedStyles.addCueSection}>
            <div style={themedStyles.cuePositionGroup}>
              <label style={themedStyles.label}>Cue Position</label>
              <div style={themedStyles.durationInputGroup}>
                <div style={themedStyles.durationFieldGroup}><input type="number" value={newCueSec} onChange={(e) => setNewCueSec(Math.max(0, parseInt(e.target.value) || 0))} min="0" style={themedStyles.durationInput} className="duration-input" /><span style={themedStyles.durationLabel}>sec</span></div>
                <div style={themedStyles.durationFieldGroup}><input type="number" value={newCueMs} onChange={(e) => setNewCueMs(Math.min(999, Math.max(0, parseInt(e.target.value) || 0)))} min="0" max="999" style={themedStyles.msInput} className="duration-input" /><span style={themedStyles.durationLabel}>ms</span></div>
              </div>
            </div>
            <button onClick={addCuePoint} style={{...themedStyles.addCueButton, opacity: cueExistsAtPosition(newCueSec + newCueMs / 1000) ? 0.5 : 1, cursor: cueExistsAtPosition(newCueSec + newCueMs / 1000) ? 'not-allowed' : 'pointer'}} className="add-cue-btn" disabled={cueExistsAtPosition(newCueSec + newCueMs / 1000)}>+ Add Cue Point</button>
          </div>
          {!envelopeMode && (
            <div style={themedStyles.audioUploadSection}>
              <button onClick={() => audioInputRef.current?.click()} style={getAudioButtonStyle()} className="audio-btn" disabled={audioStatus === 'loading'} title="Supported formats: WAV, AIFF, MP3, FLAC, M4A">{getAudioButtonText()}</button>
              <input ref={audioInputRef} type="file" accept="audio/*" onChange={handleAudioUpload} style={themedStyles.hiddenInput} />
              {audioError && <span style={themedStyles.audioHint}>{audioError}</span>}
            </div>
          )}
        </div>
        {(cuePoints.length > 0 || envelopeMode) && trackDuration > 0 && (
          <div style={themedStyles.envelopeEditor}>
            <div style={themedStyles.envelopeHeader}>
              <span style={themedStyles.envelopeTitle}>Envelope Preview</span>
              <div style={themedStyles.envelopeControls}>
                <div style={themedStyles.undoRedoGroup}>
                  <button onClick={undo} style={{...themedStyles.undoRedoButton, opacity: stateHistory.length === 0 ? 0.4 : 1}} className="undo-btn" disabled={stateHistory.length === 0} title="Undo (Ctrl+Z)"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M3 7v6h6"/><path d="M3 13a9 9 0 1 0 3-7.5L3 7"/></svg></button>
                  <button onClick={redo} style={{...themedStyles.undoRedoButton, opacity: stateFuture.length === 0 ? 0.4 : 1}} className="redo-btn" disabled={stateFuture.length === 0} title="Redo (Ctrl+Y)"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 7v6h-6"/><path d="M21 13a9 9 0 1 1-3-7.5L21 7"/></svg></button>
                </div>
                <div style={themedStyles.lockToggles}>
                  <label style={themedStyles.lockToggle}><input type="checkbox" checked={lockXAxis} onChange={(e) => setLockXAxis(e.target.checked)} style={themedStyles.lockCheckbox} /><span style={themedStyles.lockLabel}>🔒 Lock X</span></label>
                  <label style={themedStyles.lockToggle}><input type="checkbox" checked={lockYAxis} onChange={(e) => setLockYAxis(e.target.checked)} style={themedStyles.lockCheckbox} /><span style={themedStyles.lockLabel}>🔒 Lock Y</span></label>
                </div>
              </div>
            </div>
            <svg ref={svgRef} width="100%" height="100%" viewBox="-25 0 850 240" style={themedStyles.envelopeSvg} preserveAspectRatio="xMidYMid meet">
              <defs><pattern id="grid" width="80" height="40" patternUnits="userSpaceOnUse"><path d="M 80 0 L 0 0 0 40" fill="none" stroke={theme === 'light' ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.05)'} strokeWidth="1"/></pattern></defs>
              <rect x="20" y="40" width="760" height="160" fill="url(#grid)" />
              <text x="-2" y="45" fill={theme === 'light' ? '#1d1d1f' : '#666'} fontSize="9" textAnchor="end">100</text>
              <text x="-2" y="125" fill={theme === 'light' ? '#1d1d1f' : '#666'} fontSize="9" textAnchor="end">50</text>
              <text x="-2" y="200" fill={theme === 'light' ? '#1d1d1f' : '#666'} fontSize="9" textAnchor="end">0</text>
              <text x="20" y="232" fill={theme === 'light' ? '#1d1d1f' : '#666'} fontSize="9" textAnchor="start">0.0</text>
              <text x="400" y="232" fill={theme === 'light' ? '#1d1d1f' : '#666'} fontSize="9" textAnchor="middle">0.5</text>
              <text x="780" y="232" fill={theme === 'light' ? '#1d1d1f' : '#666'} fontSize="9" textAnchor="end">1.0</text>
              {curvePath && <path d={`${curvePath} L 780 200 L 20 200 Z`} fill="rgba(30, 215, 96, 0.1)" />}
              {curvePath && <path d={curvePath} fill="none" stroke="#1ed760" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />}
              {envPoints.map((point, index) => {
                const px = 20 + point.x * 760, py = 200 - point.y * 160;
                const isSelected = selectedPointIndex === index, isAuto = point.isAuto;
                return (<g key={`point-${index}`}>{isSelected && !isAuto && <line x1={px} y1={40} x2={px} y2={200} stroke="rgba(30, 215, 96, 0.3)" strokeWidth="1" strokeDasharray="4,4"/>}<circle cx={px} cy={py} r={isSelected ? 7 : 5} fill={isAuto ? (theme === 'light' ? '#bbb' : '#444') : (point.color || '#1ed760')} stroke={isSelected ? (theme === 'light' ? '#000' : '#fff') : (theme === 'light' ? 'rgba(0,0,0,0.3)' : 'rgba(255,255,255,0.5)')} strokeWidth={isSelected ? 2 : 1} style={{ cursor: isAuto ? 'default' : (lockXAxis && lockYAxis ? 'not-allowed' : lockXAxis ? 'ns-resize' : lockYAxis ? 'ew-resize' : 'move'), transition: 'r 0.1s' }} onMouseDown={(e) => !isAuto && !(lockXAxis && lockYAxis) && handlePointMouseDown(index, e)} />{!isAuto && <><rect x={px - 20} y={py - 22} width="40" height="14" rx="2" fill={theme === 'light' ? 'rgba(0,0,0,0.85)' : 'rgba(0,0,0,0.75)'} /><text x={px} y={py - 12} fill="#fff" fontSize="10" fontWeight="600" textAnchor="middle" style={{ pointerEvents: 'none' }}>{(point.y * 100).toFixed(2)}</text></>}{!isAuto && point.curve !== 1 && <text x={px} y={py + 16} fill={theme === 'light' ? '#1d1d1f' : '#888'} fontSize="8" textAnchor="middle" style={{ pointerEvents: 'none' }}>{getCurveName(point.curve)}</text>}</g>);
              })}
            </svg>
            <div style={themedStyles.envelopeHint}>Drag points to adjust Y • Uncheck cues below to exclude from envelope • <span style={themedStyles.enabledCounterInline}>{enabledCount}/{cuePoints.length} enabled</span></div>
          </div>
        )}
        {cuePoints.length > 0 ? (
          <div style={themedStyles.cueTable}>
            <div style={themedStyles.cueTableHeader}><span style={themedStyles.cueColEnable}>On</span><span style={themedStyles.cueColColor}></span><span style={themedStyles.cueColName}>Name</span><span style={themedStyles.cueColTime}>Position (s)</span><span style={themedStyles.cueColX}>X (0-100)</span><span style={themedStyles.cueColY}>Y (0-100)</span><span style={themedStyles.cueColCurve}>Interpolation</span></div>
            {cuePoints.map((cue, index) => {
              const xValue = trackDuration > 0 ? (cue.start / trackDuration) : 0;
              const envIndex = cue.enabled ? envPoints.findIndex(p => !p.isAuto && Math.abs(p.x - xValue) < 0.001) : -1;
              const isSelected = selectedPointIndex === envIndex && envIndex !== -1;
              const isStartOrEnd = index === 0 || index === cuePoints.length - 1;
              return (<div key={cue.id || index} style={{ ...themedStyles.cueRow, ...(isSelected ? styles.cueRowSelected : {}), ...(!cue.enabled ? styles.cueRowDisabled : {}) }} onClick={() => { if (cue.enabled && envIndex !== -1) setSelectedPointIndex(envIndex); }}><span style={themedStyles.cueColEnable}><input type="checkbox" checked={cue.enabled} onChange={(e) => { e.stopPropagation(); toggleCuePointEnabled(index); }} className="enable-checkbox" title={cue.enabled ? 'Click to exclude' : 'Click to include'} /></span><span style={themedStyles.cueColColor}><span style={{ ...themedStyles.cueColorDot, backgroundColor: cue.color, opacity: cue.enabled ? 1 : 0.3 }} /></span><span style={{ ...themedStyles.cueColName, opacity: cue.enabled ? 1 : 0.4, textDecoration: cue.enabled ? 'none' : 'line-through' }}>{cue.name || `Cue ${index + 1}`}</span><span style={themedStyles.cueColTime}><input type="number" value={cue.start.toFixed(3)} onChange={(e) => updateCuePointPosition(index, e.target.value)} onFocus={saveToHistory} onClick={(e) => e.stopPropagation()} min="0" max={trackDuration} step="0.001" style={{ ...themedStyles.positionInput, opacity: (cue.enabled && !lockXAxis && !isStartOrEnd) ? 1 : 0.4 }} className="position-input" disabled={!cue.enabled || lockXAxis || isStartOrEnd} title={isStartOrEnd ? 'Start/End position is fixed' : ''} /></span><span style={{ ...themedStyles.cueColX, opacity: cue.enabled ? 1 : 0.4 }}>{(xValue * 100).toFixed(2)}</span><span style={themedStyles.cueColY}><input type="number" value={cue.yValue.toFixed(2)} onChange={(e) => updateCuePointY(index, e.target.value)} onFocus={saveToHistory} min="0" max="100" step="0.01" style={{ ...themedStyles.yInput, opacity: (cue.enabled && !lockYAxis) ? 1 : 0.4 }} className="y-input" disabled={!cue.enabled || lockYAxis} /></span><span style={themedStyles.cueColCurve}><CurveDropdown value={cue.curve} onChange={(curveId) => updateCuePointCurve(index, curveId)} disabled={!cue.enabled} theme={theme} /></span></div>);
            })}
          </div>
        ) : (<div style={themedStyles.noCues}>{envelopeMode ? 'Add cue points using the fields above' : 'No cue points found in this track'}</div>)}
      </>
    ) : (<div style={themedStyles.emptyState}>Select a track or create an envelope to configure cue points</div>)
  );

  // Render Generate Section Content
  const renderGenerateContent = () => (
    selectedTrack ? (
      <>
        <div style={themedStyles.outputConfig}>
          <div style={themedStyles.presetNameGroup}><label style={themedStyles.label}>Preset Name</label><input type="text" value={presetName} onChange={(e) => setPresetName(e.target.value)} onFocus={saveToHistory} style={themedStyles.presetInput} className="preset-input" /></div>
          <button onClick={generateResolumeXml} style={themedStyles.generateButton} className="generate-btn"><svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg><span>Save XML</span></button>
          <button onClick={downloadShowKontrolCue} style={themedStyles.generateSkButton} className="generate-sk-btn"><svg width="14" height="14" viewBox="0 0 455 454"><g transform="matrix(3.68042,0,0,3.68042,-1796.433953,-4.224491)"><path d="M500.966,57.564C500.669,65.882 499.426,79.329 513.65,96.382C515.54,98.649 519.265,100.289 516.294,102.21C508.043,107.545 507.326,107.856 505.756,106.238C466.73,66.004 496.747,-1.395 553.51,1.222C565.585,1.778 583.389,8.96 581.366,11.375C580.863,11.976 553.171,29.301 550.708,30.842C546.624,33.397 546.371,31.901 546.348,31.549C545.962,25.622 547.15,14.314 544.557,14.02C543.238,13.871 528.793,16.724 519.845,23.914C502.675,37.71 501.553,54.992 500.966,57.564Z" fill="currentColor"/></g><g transform="matrix(3.68042,0,0,3.68042,-1796.433953,-4.224491)"><path d="M609.981,76.6C598.342,122.795 551.469,133.735 520.211,116.982C515.477,114.445 521.051,113.685 547.805,95.925C548.436,95.506 553.444,91.835 553.51,94.498C553.895,110.067 552.529,112.005 555.5,111.703C595.949,107.59 613.181,57.176 585.232,28.756C582.842,26.327 580.836,25.638 583.711,23.815C590.01,19.82 591.221,16.175 596.071,21.907C617.274,46.969 611.159,72.075 609.981,76.6Z" fill="currentColor"/></g></svg><span>Save ShowKontrol Cue</span></button>
        </div>
        {typeof window !== 'undefined' && window.electronAPI && (
          <div style={themedStyles.defaultFoldersSection}>
            <div style={themedStyles.defaultFolderRow}>
              <span style={themedStyles.defaultFolderLabel}>Envelope Folder:</span>
              <span style={themedStyles.defaultFolderPath}>{defaultXmlPath || 'Documents'}</span>
              <button onClick={async () => { const path = await window.electronAPI.chooseXmlDirectory(); if (path) setDefaultXmlPath(path); }} style={themedStyles.chooseFolderBtn}>Choose</button>
              {defaultXmlPath && <button onClick={() => window.electronAPI.openFolder(defaultXmlPath)} style={themedStyles.openFolderBtn} title="Open folder">📂</button>}
            </div>
            <div style={{...themedStyles.defaultFolderRow, marginBottom: 0}}>
              <span style={themedStyles.defaultFolderLabel}>SK Cue Folder:</span>
              <span style={themedStyles.defaultFolderPath}>{defaultSkCuePath || 'Documents'}</span>
              <button onClick={async () => { const path = await window.electronAPI.chooseSkCueDirectory(); if (path) setDefaultSkCuePath(path); }} style={themedStyles.chooseFolderBtn}>Choose</button>
              {defaultSkCuePath && <button onClick={() => window.electronAPI.openFolder(defaultSkCuePath)} style={themedStyles.openFolderBtn} title="Open folder">📂</button>}
            </div>
          </div>
        )}
        {generatedXml && (
          <div style={themedStyles.outputSection}>
            <div style={themedStyles.outputHeader}><span style={themedStyles.outputTitle}>Resolume Envelope XML</span><div style={themedStyles.outputActions}><button onClick={copyXml} style={themedStyles.copyButton} className="copy-btn">{copySuccess ? '✓ Copied!' : '📋 Copy'}</button><button onClick={downloadXml} style={themedStyles.downloadButton} className="download-btn">⬇ Download</button><button onClick={downloadShowKontrolCue} style={themedStyles.showKontrolButton} className="showkontrol-btn">🎬 ShowKontrol</button></div></div>
            <pre style={themedStyles.xmlPreview}>{generatedXml}</pre>
          </div>
        )}
      </>
    ) : (<div style={themedStyles.emptyState}>Select a track or create an envelope to generate output</div>)
  );

  // Render a draggable section wrapper
  const renderSection = (sectionId, column, isSpanning = false) => {
    const config = sectionConfigs[sectionId];
    const isCollapsed = collapsedSections[sectionId];
    const isDragging = draggedSection === sectionId;
    const currentColumn = sectionColumns[sectionId] || 'left';
    const contentRenderers = { project: renderProjectContent, browse: renderBrowseContent, configure: renderConfigureContent, generate: renderGenerateContent };
    return (
      <div key={sectionId} style={{...themedStyles.section, ...(isDragging ? styles.sectionDragging : {}), ...(isSpanning ? { width: '100%' } : {})}} onDragOver={(e) => handleDragOver(e, sectionId, column)}>
        <div style={{...themedStyles.sectionHeader, marginBottom: isCollapsed ? 0 : '14px'}} onClick={() => toggleSection(sectionId)} draggable={true} onDragStart={(e) => handleDragStart(e, sectionId)} onDragEnd={handleDragEnd}>
          <span style={themedStyles.dragHandle} className="drag-handle" title="Drag to reorder">⋮⋮</span>
          <span style={themedStyles.stepNumber}>
            {getArrowForSection(sectionId)}
            <span style={themedStyles.stepNumberLabel}>{logicalOrder.indexOf(sectionId) + 1}</span>
          </span>
          <span>{config.title}</span>
          {sectionId === 'configure' && (
            <div style={themedStyles.layoutToggleGroup}>
              <button 
                onClick={(e) => { e.stopPropagation(); setSideBySideMode(!sideBySideMode); if (sideBySideMode) setConfigureSpanColumns(false); }} 
                style={{...themedStyles.layoutToggleBtn, ...(sideBySideMode ? themedStyles.layoutToggleBtnActive : themedStyles.layoutToggleBtnInactive), ...(hoveredLayoutBtn === 'sidebyside' && !sideBySideMode ? themedStyles.layoutToggleBtnHover : {})}}
                title="Side-by-Side Layout"
                onMouseEnter={() => setHoveredLayoutBtn('sidebyside')}
                onMouseLeave={() => setHoveredLayoutBtn(null)}
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <rect x="3" y="3" width="7" height="18" rx="1" />
                  <rect x="14" y="3" width="7" height="18" rx="1" />
                </svg>
              </button>
              {sideBySideMode && (
                <button 
                  onClick={(e) => { e.stopPropagation(); setConfigureSpanColumns(!configureSpanColumns); }} 
                  style={{...themedStyles.layoutToggleBtn, ...(configureSpanColumns ? themedStyles.layoutToggleBtnActive : themedStyles.layoutToggleBtnInactive), ...(hoveredLayoutBtn === 'span' && !configureSpanColumns ? themedStyles.layoutToggleBtnHover : {})}}
                  title="Span both columns"
                  onMouseEnter={() => setHoveredLayoutBtn('span')}
                  onMouseLeave={() => setHoveredLayoutBtn(null)}
                >
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <rect x="3" y="8" width="18" height="8" rx="1" />
                  </svg>
                </button>
              )}
            </div>
          )}
          {sideBySideMode && (
            <span style={themedStyles.columnMoveButtons} onClick={(e) => e.stopPropagation()}>
              <button onClick={() => moveToColumn(sectionId, 'left')} style={{...themedStyles.columnMoveBtn, ...(currentColumn === 'left' ? styles.columnMoveBtnActive : {})}} title="Move to left column">◀</button>
              <button onClick={() => moveToColumn(sectionId, 'right')} style={{...themedStyles.columnMoveBtn, ...(currentColumn === 'right' ? styles.columnMoveBtnActive : {})}} title="Move to right column">▶</button>
            </span>
          )}
          <span style={themedStyles.collapseIcon}>{isCollapsed ? '▶' : '▼'}</span>
        </div>
        {!isCollapsed && contentRenderers[sectionId]()}
      </div>
    );
  };

  return (
    <div style={themedStyles.container}>
      <style>{`
        .drag-handle:hover { color: #1ed760 !important; }
        .drag-handle:active { cursor: grabbing !important; }
        .import-btn:hover { background-color: rgba(0, 0, 0, 0.8) !important; border-color: #fff !important; color: #fff !important; }
        .import-btn:hover svg { transform: scale(1.3); fill: #fff !important; }
        .engine-btn:hover svg { transform: scale(1.3); }
        .create-envelope-btn:hover { background-color: #ffd700 !important; color: #000 !important; }
        .create-envelope-btn:hover svg { stroke: #000 !important; transform: scale(1.3); }
        .create-envelope-btn svg { transition: all 0.2s ease; }
        .serato-btn:hover { background-color: rgb(0, 104, 169) !important; color: #fff !important; }
        .serato-btn:hover svg { transform: scale(1.3); }
        .engine-btn:hover { background-color: rgb(91, 210, 159) !important; color: #000 !important; }
        .showkontrol-import-btn:hover { background-color: rgb(239, 40, 138) !important; color: #fff !important; }
        .showkontrol-import-btn:hover svg path { fill: #fff !important; }
        .showkontrol-import-btn:hover svg { transform: rotate(360deg); }
        .showkontrol-import-btn svg { transition: transform 0.5s ease; }
        .showkontrol-btn:hover { background-color: rgb(255, 80, 160) !important; }
        .clear-btn:hover { background-color: rgba(255, 80, 80, 0.3) !important; border-color: #ff5050 !important; }
        .add-cue-btn:hover:not(:disabled) { background-color: #1ed760 !important; color: #000 !important; }
        .undo-btn:hover:not(:disabled), .redo-btn:hover:not(:disabled) { background-color: rgba(255, 255, 255, 0.15) !important; border-color: rgba(255, 255, 255, 0.3) !important; }
        .undo-btn svg, .redo-btn svg { transition: transform 0.2s ease; }
        .undo-btn:hover:not(:disabled) svg, .redo-btn:hover:not(:disabled) svg { transform: scale(1.2); }
        .track-item:hover { background-color: rgba(30, 215, 96, 0.1) !important; border-color: rgba(30, 215, 96, 0.5) !important; }
        .audio-btn:hover { background-color: rgba(255, 255, 255, 0.15) !important; border-color: rgba(255, 255, 255, 0.4) !important; }
        .audio-btn svg { transition: transform 0.2s ease; }
        .audio-btn:hover svg { transform: scale(1.3); }
        .generate-btn:hover { background-color: #1ed760 !important; color: #000 !important; }
        .settings-btn:hover { background-color: #1ed760 !important; color: #000 !important; border-color: #1ed760 !important; }
        .generate-sk-btn:hover { background-color: rgb(239, 40, 138) !important; color: #fff !important; }
        .generate-sk-btn:hover svg path { fill: #fff !important; }
        .generate-sk-btn svg { transition: transform 0.5s ease; }
        .generate-sk-btn:hover svg { transform: rotate(360deg); }
        .copy-btn:hover { background-color: rgba(255, 255, 255, 0.1) !important; }
        .download-btn:hover { background-color: #1db954 !important; }
        .y-input:focus, .duration-input:focus, .preset-input:focus, .search-input:focus, .position-input:focus { border-color: #1ed760 !important; outline: none; }
        input[type="number"]::-webkit-inner-spin-button { opacity: 1; }
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: rgba(0,0,0,0.2); border-radius: 4px; }
        ::-webkit-scrollbar-thumb { background: rgba(30, 215, 96, 0.3); border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: rgba(30, 215, 96, 0.5); }
        .enable-checkbox { width: 16px; height: 16px; cursor: pointer; accent-color: #1ed760; }
        .import-btn svg, .serato-btn svg, .engine-btn svg, .showkontrol-import-btn svg, .resolume-import-btn svg { flex-shrink: 0; transition: transform 0.2s ease; }
        .resolume-import-btn:hover { background-color: #5de4c7 !important; color: #1a3a35 !important; }
        .resolume-import-btn:hover svg { transform: scale(1.3); }
        .resolume-import-btn:hover svg > rect { fill: #5de4c7 !important; }
        .resolume-import-btn:hover svg g rect { fill: #000 !important; }
        .resolume-import-btn:hover svg g line { stroke: #5de4c7 !important; }
        .save-btn:hover { background-color: rgba(255, 255, 255, 0.15) !important; }
        .save-btn:hover svg { transform: scale(1.3); }
        .save-btn svg { transition: all 0.2s ease; }
        .open-btn:hover { background-color: rgba(255, 255, 255, 0.15) !important; }
        .open-btn:hover svg { transform: scale(1.3); }
        .open-btn svg { transition: all 0.2s ease; }
        .clear-btn:hover { background-color: rgba(255, 255, 255, 0.15) !important; }
        .clear-btn:hover svg { transform: scale(1.3); }
        .clear-btn svg { transition: all 0.2s ease; }
        .playlist-item:hover { background-color: rgba(30, 215, 96, 0.1) !important; }
        .modal-cancel-btn:hover { background-color: rgba(255, 255, 255, 0.1) !important; color: #fff !important; }
        .modal-confirm-btn:hover { background-color: rgb(255, 80, 160) !important; }
      `}</style>
      
      <div style={themedStyles.gridOverlay} />
      
      {/* ShowKontrol Duration Modal */}
      {showDurationModal && (
        <div style={themedStyles.modalOverlay}>
          <div style={themedStyles.modal}>
            <h3 style={themedStyles.modalTitle}>Set Track Duration</h3>
            <p style={themedStyles.modalText}>
              Importing {pendingShowKontrolData?.cuePoints?.length || 0} cue point(s) from {pendingShowKontrolData?.fileName || 'file'}
            </p>
            <p style={themedStyles.modalText}>Enter the total duration for the track:</p>
            <div style={themedStyles.modalInputGroup}>
              <div style={themedStyles.modalFieldGroup}>
                <input 
                  type="number" 
                  value={durationMinutes} 
                  onChange={(e) => setDurationMinutes(Math.max(0, parseInt(e.target.value) || 0))} 
                  min="0" 
                  style={themedStyles.modalInput} 
                  className="duration-input"
                />
              </div>
              <span style={themedStyles.modalSeparator}>:</span>
              <div style={themedStyles.modalFieldGroup}>
                <input 
                  type="number" 
                  value={durationSeconds} 
                  onChange={(e) => setDurationSeconds(Math.min(59, Math.max(0, parseInt(e.target.value) || 0)))} 
                  min="0" 
                  max="59" 
                  style={themedStyles.modalInput} 
                  className="duration-input"
                />
              </div>
              <span style={themedStyles.modalSeparator}>:</span>
              <div style={themedStyles.modalFieldGroup}>
                <input 
                  type="number" 
                  value={durationMs} 
                  onChange={(e) => setDurationMs(Math.min(999, Math.max(0, parseInt(e.target.value) || 0)))} 
                  min="0" 
                  max="999" 
                  style={{...themedStyles.modalInput, width: '75px'}} 
                  className="duration-input"
                />
              </div>
            </div>
            <div style={themedStyles.modalLabelRow}>
              <span style={themedStyles.modalLabelCenter}>min</span>
              <span style={themedStyles.modalLabelCenter}>sec</span>
              <span style={{...themedStyles.modalLabelCenter, width: '75px'}}>ms</span>
            </div>
            <div style={themedStyles.modalButtons}>
              <button onClick={cancelShowKontrolImport} style={themedStyles.modalCancelButton} className="modal-cancel-btn">Cancel</button>
              <button onClick={confirmShowKontrolImport} style={themedStyles.modalConfirmButton} className="modal-confirm-btn">Import</button>
            </div>
          </div>
        </div>
      )}
      
      {showResolumeModal && (
        <div style={themedStyles.modalOverlay}>
          <div style={themedStyles.modal}>
            <h3 style={themedStyles.modalTitle}>Import Resolume Envelope</h3>
            <p style={themedStyles.modalText}>
              Importing {pendingResolumeData?.points?.length || 0} point(s) from "{pendingResolumeData?.envelopeName || 'envelope'}"
            </p>
            <p style={themedStyles.modalText}>Enter the duration to map the envelope to:</p>
            <div style={themedStyles.modalInputGroup}>
              <div style={themedStyles.modalFieldGroup}>
                <input 
                  type="number" 
                  value={durationMinutes} 
                  onChange={(e) => setDurationMinutes(Math.max(0, parseInt(e.target.value) || 0))} 
                  min="0" 
                  style={themedStyles.modalInput} 
                  className="duration-input"
                />
              </div>
              <span style={themedStyles.modalSeparator}>:</span>
              <div style={themedStyles.modalFieldGroup}>
                <input 
                  type="number" 
                  value={durationSeconds} 
                  onChange={(e) => setDurationSeconds(Math.min(59, Math.max(0, parseInt(e.target.value) || 0)))} 
                  min="0" 
                  max="59" 
                  style={themedStyles.modalInput} 
                  className="duration-input"
                />
              </div>
            </div>
            <div style={themedStyles.modalLabelRow}>
              <span style={themedStyles.modalLabelCenter}>min</span>
              <span style={themedStyles.modalLabelCenter}>sec</span>
            </div>
            <div style={themedStyles.modalButtons}>
              <button onClick={cancelResolumeImport} style={themedStyles.modalCancelButton} className="modal-cancel-btn">Cancel</button>
              <button onClick={confirmResolumeImport} style={{...themedStyles.modalConfirmButton, backgroundColor: '#ffd700', color: '#000'}} className="modal-confirm-btn">Import</button>
            </div>
          </div>
        </div>
      )}
      
      <header style={themedStyles.header}>
        <div style={themedStyles.logoSection}>
          <div style={themedStyles.logo}>
            <span style={themedStyles.logoIcon}>◈</span>
            <span style={themedStyles.logoText}>CUE</span>
            <span style={themedStyles.logoAccent}>SYNC</span>
          </div>
          <span style={themedStyles.tagline}>Rekordbox • Serato • Engine DJ • ShowKontrol → Resolume</span>
        </div>
        <div style={themedStyles.headerRight}>
          <span style={themedStyles.projectNameDisplay}>
            {projectName}{hasUnsavedChanges ? ' •' : ''}
          </span>
          <div style={themedStyles.versionBadge}>v1.0</div>
        </div>
      </header>

      <main style={{...themedStyles.main, gridTemplateColumns: sideBySideMode ? '1fr 1fr' : '1fr'}}>
        {sideBySideMode ? (
          <>
            {/* Left Column */}
            <div style={themedStyles.layoutColumn} onDragOver={(e) => e.preventDefault()} onDrop={(e) => handleColumnDrop(e, 'left')}>
              {leftColumnSections.map(sectionId => renderSection(sectionId, 'left'))}
              {leftColumnSections.length === 0 && (
                <div style={themedStyles.emptyColumnDropZone}><span style={themedStyles.dropZoneText}>Drag sections here</span></div>
              )}
            </div>

            {/* Right Column */}
            <div style={themedStyles.layoutColumn} onDragOver={(e) => e.preventDefault()} onDrop={(e) => handleColumnDrop(e, 'right')}>
              {rightColumnSections.map(sectionId => renderSection(sectionId, 'right'))}
              {rightColumnSections.length === 0 && (
                <div style={themedStyles.emptyColumnDropZone}><span style={themedStyles.dropZoneText}>Drag sections here</span></div>
              )}
            </div>

            {/* Spanning Configure Section */}
            {configureSpanColumns && (
              <div style={themedStyles.spanningSection}>
                {renderSection('configure', null, true)}
              </div>
            )}
          </>
        ) : (
          /* Single Column Mode */
          <div style={themedStyles.layoutColumn}>
            {sectionOrder.map(sectionId => renderSection(sectionId, 'left', sectionId === 'configure'))}
          </div>
        )}
      </main>

      <footer style={themedStyles.footer}>
        <span>Built for VJs</span>
        <span style={themedStyles.footerDot}>•</span>
        <span>Rekordbox • Serato • Engine DJ • ShowKontrol → Resolume</span>
      </footer>
    </div>
  );
}

const styles = {
  container: { display: 'flex', flexDirection: 'column', height: '100%', backgroundColor: '#0a0a0f', color: '#e0e0e8', fontFamily: "'JetBrains Mono', 'Fira Code', monospace", position: 'relative', overflow: 'auto', width: '100%' },
  gridOverlay: { position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, backgroundImage: 'linear-gradient(rgba(30, 215, 96, 0.03) 1px, transparent 1px), linear-gradient(90deg, rgba(30, 215, 96, 0.03) 1px, transparent 1px)', backgroundSize: '50px 50px', pointerEvents: 'none', zIndex: 0 },
  modalOverlay: { position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, backgroundColor: 'rgba(0, 0, 0, 0.8)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000 },
  modal: { backgroundColor: '#1a1a2e', borderRadius: '12px', padding: '24px 32px', border: '1px solid rgba(239, 40, 138, 0.3)', boxShadow: '0 20px 60px rgba(0, 0, 0, 0.5)', minWidth: '320px' },
  modalTitle: { margin: '0 0 12px 0', fontSize: '18px', fontWeight: '600', color: '#fff' },
  modalText: { margin: '0 0 20px 0', fontSize: '13px', color: '#888' },
  modalInputGroup: { display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '8px', marginBottom: '8px' },
  modalLabelRow: { display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '28px', marginBottom: '24px' },
  modalLabelCenter: { color: '#888', fontSize: '12px', textAlign: 'center', width: '70px' },
  modalFieldGroup: { display: 'flex', alignItems: 'center', gap: '6px' },
  modalInput: { width: '70px', padding: '10px 12px 10px 8px', backgroundColor: 'rgba(0, 0, 0, 0.4)', border: '1px solid rgba(255, 255, 255, 0.15)', borderRadius: '6px', color: '#fff', fontSize: '16px', fontFamily: 'inherit', textAlign: 'center' },
  modalLabel: { color: '#888', fontSize: '13px' },
  modalSeparator: { color: '#fff', fontSize: '20px', fontWeight: '600' },
  modalButtons: { display: 'flex', gap: '12px', justifyContent: 'flex-end' },
  modalCancelButton: { padding: '10px 20px', backgroundColor: 'transparent', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '6px', color: '#888', fontSize: '13px', fontWeight: '500', cursor: 'pointer', transition: 'all 0.2s' },
  modalConfirmButton: { padding: '10px 20px', backgroundColor: 'rgb(239, 40, 138)', border: 'none', borderRadius: '6px', color: '#fff', fontSize: '13px', fontWeight: '600', cursor: 'pointer', transition: 'all 0.2s' },
  header: { position: 'relative', zIndex: 1, display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '16px 24px', borderBottom: '1px solid rgba(30, 215, 96, 0.2)', background: 'linear-gradient(180deg, rgba(30, 215, 96, 0.08) 0%, transparent 100%)', flexShrink: 0 },
  logoSection: { display: 'flex', alignItems: 'baseline', gap: '16px', flexWrap: 'wrap' },
  logo: { display: 'flex', alignItems: 'center', gap: '6px', fontSize: '20px', fontWeight: '700' },
  logoIcon: { color: '#1ed760', fontSize: '24px' },
  logoText: { color: '#fff' },
  logoAccent: { color: '#1ed760' },
  tagline: { fontSize: '10px', color: '#666' },
  headerRight: { display: 'flex', alignItems: 'center', gap: '12px' },
  projectNameDisplay: { fontSize: '11px', color: '#888', maxWidth: '200px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
  versionBadge: { padding: '4px 10px', backgroundColor: 'rgba(30, 215, 96, 0.15)', color: '#1ed760', borderRadius: '4px', fontSize: '10px', fontWeight: '600', border: '1px solid rgba(30, 215, 96, 0.3)' },
  main: { position: 'relative', zIndex: 1, flex: 1, display: 'grid', gap: '20px', width: '100%', margin: '0', padding: '20px', overflow: 'auto', boxSizing: 'border-box', alignContent: 'start' },
  layoutColumn: { display: 'flex', flexDirection: 'column', gap: '16px', minWidth: 0 },
  sectionDragging: { opacity: 0.5, border: '1px dashed #1ed760' },
  sectionHeader: { display: 'flex', alignItems: 'center', gap: '12px', fontSize: '12px', fontWeight: '600', color: '#fff', textTransform: 'uppercase', letterSpacing: '1px', cursor: 'pointer', userSelect: 'none' },
  dragHandle: { color: '#666', cursor: 'grab', fontSize: '14px', marginRight: '-4px', padding: '4px', transition: 'color 0.15s' },
  collapseIcon: { marginLeft: 'auto', color: '#666', fontSize: '10px', transition: 'transform 0.2s' },
  columnMoveButtons: { display: 'inline-flex', gap: '2px', marginLeft: 'auto', marginRight: '8px' },
  columnMoveBtn: { padding: '2px 6px', backgroundColor: 'transparent', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '3px', color: '#666', fontSize: '8px', cursor: 'pointer', transition: 'all 0.15s', outline: 'none' },
  columnMoveBtnActive: { backgroundColor: 'rgba(30, 215, 96, 0.2)', borderColor: '#1ed760', color: '#1ed760' },
  emptyColumnDropZone: { flex: 1, minHeight: '200px', border: '2px dashed rgba(30, 215, 96, 0.3)', borderRadius: '10px', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(30, 215, 96, 0.05)' },
  dropZoneText: { color: 'rgba(30, 215, 96, 0.5)', fontSize: '12px', textTransform: 'uppercase', letterSpacing: '1px' },
  spanningSection: { gridColumn: '1 / -1', width: '100%' },
  layoutToggleGroup: { display: 'flex', gap: '4px', marginLeft: '8px' },
  layoutToggleBtn: { width: '32px', height: '32px', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(255, 255, 255, 0.08)', border: '2px solid rgba(255, 255, 255, 0.15)', borderRadius: '5px', color: '#ccc', cursor: 'pointer', transition: 'all 0.15s', outline: 'none' },
  layoutToggleBtnActive: { backgroundColor: 'rgba(30, 215, 96, 0.2)', borderColor: '#1ed760', color: '#1ed760' },
  layoutToggleBtnInactive: { backgroundColor: 'rgba(255, 255, 255, 0.08)', borderColor: 'rgba(255, 255, 255, 0.15)', color: '#fff' },
  layoutToggleBtnHover: { backgroundColor: 'rgba(30, 215, 96, 0.15)', borderColor: '#1ed760', color: '#1ed760' },
  section: { background: 'linear-gradient(135deg, rgba(20, 20, 30, 0.8) 0%, rgba(15, 15, 22, 0.9) 100%)', border: '1px solid rgba(255, 255, 255, 0.08)', borderRadius: '10px', padding: '16px 20px', transition: 'all 0.2s', overflow: 'hidden' },
  sectionTitle: { display: 'flex', alignItems: 'center', gap: '12px', fontSize: '12px', fontWeight: '600', marginBottom: '14px', color: '#fff', textTransform: 'uppercase', letterSpacing: '1px' },
  stepNumber: { position: 'relative', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: '26px', height: '26px', backgroundColor: '#1ed760', color: '#000', borderRadius: '6px', fontSize: '14px', fontWeight: '700', flexShrink: 0 },
  stepNumberLabel: { position: 'absolute', bottom: '1px', right: '3px', fontSize: '8px', fontWeight: '700', color: '#000', lineHeight: 1 },
  enabledCounter: { fontSize: '11px', color: '#888', fontWeight: '400', textTransform: 'none', letterSpacing: '0', marginLeft: 'auto' },
  projectControls: { display: 'flex', flexWrap: 'wrap', gap: '12px', alignItems: 'flex-end' },
  projectNameInput: { display: 'flex', flexDirection: 'column', gap: '4px', width: '155px' },
  projectButtons: { display: 'flex', gap: '8px', flexWrap: 'wrap' },
  hiddenInput: { position: 'absolute', width: '1px', height: '1px', padding: 0, margin: '-1px', overflow: 'hidden', clip: 'rect(0,0,0,0)', border: 0 },
  createEnvelopeButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(255, 215, 0, 0.15)', color: '#fff', border: '1px solid #ffd700', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  importButtonLabel: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(255, 255, 255, 0.08)', color: '#e0e0e8', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '500', transition: 'all 0.2s' },
  seratoButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(0, 104, 169, 0.15)', color: '#fff', border: '1px solid rgb(0, 104, 169)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  engineButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(91, 210, 159, 0.15)', color: '#fff', border: '1px solid rgb(91, 210, 159)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  showKontrolImportButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(239, 40, 138, 0.15)', color: '#fff', border: '1px solid rgb(239, 40, 138)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  resolumeImportButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(93, 228, 199, 0.15)', color: '#fff', border: '1px solid #5de4c7', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  openButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', backgroundColor: 'rgba(255, 255, 255, 0.08)', color: '#e0e0e8', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '500', transition: 'all 0.2s' },
  saveButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', backgroundColor: 'rgba(255, 255, 255, 0.08)', color: '#e0e0e8', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '500', transition: 'all 0.2s' },
  clearButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', backgroundColor: 'rgba(255, 255, 255, 0.08)', color: '#e0e0e8', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '500', transition: 'all 0.2s' },
  envelopeModeBadge: { marginLeft: '10px', padding: '3px 8px', backgroundColor: 'rgba(255, 215, 0, 0.2)', color: '#ffd700', borderRadius: '4px', fontSize: '10px', fontWeight: '600' },
  addCueSection: { display: 'flex', alignItems: 'flex-end', gap: '12px' },
  cuePositionGroup: { display: 'flex', flexDirection: 'column', gap: '6px' },
  addCueButton: { padding: '10px 16px', backgroundColor: 'rgba(30, 215, 96, 0.2)', color: '#1ed760', border: '1px solid #1ed760', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s', whiteSpace: 'nowrap' },
  trackCount: { color: '#1ed760', fontSize: '11px', fontWeight: '500' },
  settingsRow: { display: 'flex', gap: '24px', marginTop: '16px', flexWrap: 'wrap' },
  settingsGroup: { display: 'flex', flexDirection: 'column', gap: '6px' },
  settingsLabel: { fontSize: '10px', fontWeight: '600', color: '#666', textTransform: 'uppercase', letterSpacing: '0.5px' },
  settingsButtons: { display: 'flex', gap: '4px' },
  settingsBtn: { padding: '10px 16px', backgroundColor: 'rgba(30, 215, 96, 0.2)', border: '1px solid #1ed760', borderRadius: '5px', color: '#1ed760', fontSize: '11px', fontWeight: '600', cursor: 'pointer', transition: 'all 0.2s', outline: 'none' },
  settingsBtnActive: { backgroundColor: '#1ed760', borderColor: '#1ed760', color: '#000' },
  buttonGroupWithLabel: { display: 'flex', flexDirection: 'column', gap: '6px' },
  buttonGroupLabel: { fontSize: '10px', fontWeight: '600', color: '#666', textTransform: 'uppercase', letterSpacing: '0.5px' },
  buttonGroupRow: { display: 'flex', gap: '4px', flexWrap: 'wrap' },
  projectNameRow: { display: 'flex', gap: '12px', alignItems: 'flex-end', flexWrap: 'wrap' },
  projectMainRow: { display: 'flex', gap: '24px', alignItems: 'flex-end', flexWrap: 'wrap' },
  projectNameInputRow: { display: 'flex', gap: '4px', alignItems: 'center' },
  presetInputInline: { padding: '8px 12px', backgroundColor: 'rgba(0, 0, 0, 0.4)', border: '1px solid rgba(255, 255, 255, 0.15)', borderRadius: '5px', color: '#fff', fontSize: '11px', fontFamily: 'inherit', width: '130px', boxSizing: 'border-box' },
  browserContainer: { display: 'flex', gap: '16px', minHeight: '350px' },
  sidebar: { width: '220px', flexShrink: 0, backgroundColor: 'rgba(0, 0, 0, 0.3)', borderRadius: '6px', border: '1px solid rgba(255, 255, 255, 0.08)', overflow: 'hidden', display: 'flex', flexDirection: 'column' },
  sidebarHeader: { padding: '10px 12px', fontSize: '10px', fontWeight: '700', color: '#888', textTransform: 'uppercase', letterSpacing: '1px', borderBottom: '1px solid rgba(255, 255, 255, 0.08)', backgroundColor: 'rgba(255, 255, 255, 0.03)' },
  playlistItem: { display: 'flex', alignItems: 'center', gap: '8px', padding: '8px 12px', cursor: 'pointer', transition: 'all 0.1s', fontSize: '11px' },
  playlistIcon: { fontSize: '12px' },
  playlistName: { flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: '#ccc' },
  playlistCount: { fontSize: '10px', color: '#666', backgroundColor: 'rgba(255, 255, 255, 0.1)', padding: '2px 6px', borderRadius: '10px' },
  trackBrowser: { flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 },
  searchBar: { display: 'flex', gap: '10px', marginBottom: '12px' },
  searchInput: { flex: 1, padding: '10px 14px', backgroundColor: 'rgba(0, 0, 0, 0.4)', border: '1px solid rgba(255, 255, 255, 0.15)', borderRadius: '5px', color: '#fff', fontSize: '12px', fontFamily: 'inherit' },
  sortSelect: { padding: '10px 14px', backgroundColor: 'rgba(0, 0, 0, 0.4)', border: '1px solid rgba(255, 255, 255, 0.15)', borderRadius: '5px', color: '#fff', fontSize: '11px', fontFamily: 'inherit', cursor: 'pointer', minWidth: '130px' },
  trackList: { flex: 1, display: 'flex', flexDirection: 'column', gap: '4px', maxHeight: '280px', overflowY: 'auto', paddingRight: '4px' },
  noResults: { padding: '40px', textAlign: 'center', color: '#666', fontSize: '12px' },
  trackItem: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 14px', backgroundColor: 'rgba(255, 255, 255, 0.03)', border: '1px solid rgba(255, 255, 255, 0.06)', borderRadius: '5px', cursor: 'pointer', transition: 'all 0.15s' },
  trackItemSelected: { backgroundColor: 'rgba(30, 215, 96, 0.2)', borderColor: '#1ed760' },
  trackItemHover: { backgroundColor: 'rgba(30, 215, 96, 0.1)', borderColor: 'rgba(30, 215, 96, 0.5)' },
  trackInfo: { display: 'flex', flexDirection: 'column', gap: '2px', flex: 1, minWidth: 0 },
  trackName: { fontSize: '12px', fontWeight: '600', color: '#fff', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' },
  trackMeta: { fontSize: '10px', color: '#888', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' },
  trackMeta2: { fontSize: '9px', color: '#666' },
  trackDurationDisplay: { fontSize: '11px', color: '#888', marginLeft: '12px', flexShrink: 0 },
  trackListFooter: { padding: '8px 0', fontSize: '10px', color: '#555', textAlign: 'center', borderTop: '1px solid rgba(255, 255, 255, 0.05)', marginTop: '8px' },
  selectedTrackInfo: { fontSize: '12px', color: '#ccc', marginBottom: '16px', padding: '10px 14px', backgroundColor: 'rgba(30, 215, 96, 0.1)', borderRadius: '5px', borderLeft: '3px solid #1ed760' },
  durationSection: { display: 'flex', gap: '20px', marginBottom: '16px', alignItems: 'flex-end', flexWrap: 'wrap' },
  durationInfo: { display: 'flex', flexDirection: 'column', gap: '4px' },
  label: { fontSize: '9px', color: '#888', textTransform: 'uppercase', letterSpacing: '1px' },
  durationInputGroup: { display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' },
  durationFieldGroup: { display: 'flex', alignItems: 'center', gap: '4px' },
  durationInput: { width: '65px', padding: '8px 12px 8px 8px', backgroundColor: 'rgba(0, 0, 0, 0.4)', border: '1px solid rgba(255, 255, 255, 0.15)', borderRadius: '4px', color: '#fff', fontSize: '12px', fontFamily: 'inherit', textAlign: 'center' },
  msInput: { width: '65px', padding: '8px 12px 8px 8px', backgroundColor: 'rgba(0, 0, 0, 0.4)', border: '1px solid rgba(255, 255, 255, 0.15)', borderRadius: '4px', color: '#fff', fontSize: '12px', fontFamily: 'inherit', textAlign: 'center' },
  durationLabel: { fontSize: '10px', color: '#666' },
  durationFormatted: { fontSize: '11px', color: '#1ed760', marginLeft: '4px' },
  audioUploadSection: { display: 'flex', flexDirection: 'column', gap: '4px', justifyContent: 'flex-end' },
  audioAndCueSection: { display: 'flex', flexDirection: 'row', gap: '16px', alignItems: 'flex-end' },
  audioButton: { display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: '6px', padding: '10px 16px', backgroundColor: 'rgba(255, 255, 255, 0.08)', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '5px', color: '#e0e0e8', fontSize: '11px', fontWeight: '500', cursor: 'pointer', transition: 'all 0.15s', minWidth: '160px' },
  audioButtonLoading: { backgroundColor: 'rgba(255, 200, 0, 0.15)', borderColor: '#ffc800', color: '#ffc800', cursor: 'wait' },
  audioButtonLoaded: { backgroundColor: 'rgba(30, 215, 96, 0.15)', borderColor: '#1ed760', color: '#1ed760' },
  audioButtonError: { backgroundColor: 'rgba(255, 80, 80, 0.15)', borderColor: '#ff6b6b', color: '#ff6b6b' },
  audioHint: { fontSize: '9px', color: '#555', maxWidth: '180px' },
  envelopeEditor: { marginBottom: '16px', backgroundColor: 'rgba(0, 0, 0, 0.3)', borderRadius: '6px', padding: '12px', border: '1px solid rgba(255, 255, 255, 0.1)' },
  envelopeHeader: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '8px', flexWrap: 'wrap', gap: '8px' },
  envelopeControls: { display: 'flex', gap: '16px', alignItems: 'center' },
  undoRedoGroup: { display: 'flex', gap: '4px', alignItems: 'center' },
  undoRedoButton: { display: 'flex', alignItems: 'center', justifyContent: 'center', width: '28px', height: '28px', backgroundColor: 'rgba(255, 255, 255, 0.08)', border: '1px solid rgba(255, 255, 255, 0.15)', borderRadius: '4px', color: '#e0e0e8', cursor: 'pointer', transition: 'all 0.2s' },
  lockToggles: { display: 'flex', gap: '12px', alignItems: 'center' },
  envelopeTitle: { fontSize: '10px', fontWeight: '600', color: '#1ed760', textTransform: 'uppercase', letterSpacing: '1px' },
  lockToggle: { display: 'flex', alignItems: 'center', gap: '6px', cursor: 'pointer' },
  lockCheckbox: { width: '14px', height: '14px', cursor: 'pointer', accentColor: '#1ed760' },
  lockLabel: { fontSize: '10px', color: '#888', fontWeight: '700' },
  envelopeSvg: { backgroundColor: 'rgba(0, 0, 0, 0.4)', borderRadius: '4px', display: 'block', width: '100%', aspectRatio: '825 / 220' },
  envelopeHint: { fontSize: '9px', color: '#555', marginTop: '6px', textAlign: 'center' },
  enabledCounterInline: { color: '#1ed760', fontWeight: '500' },
  cueTable: { display: 'flex', flexDirection: 'column', border: '1px solid rgba(255, 255, 255, 0.1)', borderRadius: '6px', overflow: 'visible' },
  cueTableHeader: { display: 'grid', gridTemplateColumns: '36px 32px 1fr 75px 60px 84px 165px', padding: '8px 12px', backgroundColor: 'rgba(255, 255, 255, 0.05)', fontSize: '9px', fontWeight: '700', textTransform: 'uppercase', letterSpacing: '1px', color: '#888', borderBottom: '1px solid rgba(255, 255, 255, 0.1)', gap: '4px' },
  cueRow: { display: 'grid', gridTemplateColumns: '36px 32px 1fr 75px 60px 84px 165px', padding: '8px 12px', alignItems: 'center', borderBottom: '1px solid rgba(255, 255, 255, 0.05)', gap: '4px', cursor: 'pointer', transition: 'background-color 0.1s' },
  cueRowSelected: { backgroundColor: 'rgba(30, 215, 96, 0.15)' },
  cueRowDisabled: { backgroundColor: 'rgba(0, 0, 0, 0.2)' },
  cueColEnable: { display: 'flex', alignItems: 'center', justifyContent: 'center' },
  cueColColor: { display: 'flex', alignItems: 'center', justifyContent: 'center' },
  cueColorDot: { width: '10px', height: '10px', borderRadius: '50%', boxShadow: '0 0 6px currentColor', transition: 'opacity 0.15s' },
  cueColName: { fontSize: '11px', color: '#fff', fontWeight: '500', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', transition: 'opacity 0.15s' },
  cueColTime: { display: 'flex', alignItems: 'center' },
  positionInput: { width: '70px', padding: '5px 6px', backgroundColor: 'rgba(0, 0, 0, 0.5)', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '4px', color: '#fff', fontSize: '10px', fontFamily: 'inherit', textAlign: 'center', transition: 'opacity 0.15s' },
  cueColX: { fontSize: '9px', color: '#1ed760', transition: 'opacity 0.15s' },
  cueColY: { display: 'flex', alignItems: 'center' },
  cueColCurve: { display: 'flex', alignItems: 'center' },
  yInput: { width: '74px', padding: '5px 6px', backgroundColor: 'rgba(0, 0, 0, 0.5)', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '4px', color: '#fff', fontSize: '10px', fontFamily: 'inherit', textAlign: 'center', transition: 'opacity 0.15s' },
  noCues: { padding: '30px', textAlign: 'center', color: '#666', fontSize: '12px', backgroundColor: 'rgba(0, 0, 0, 0.2)', borderRadius: '6px' },
  emptyState: { padding: '40px 20px', textAlign: 'center', color: '#888', fontSize: '13px', backgroundColor: 'rgba(0, 0, 0, 0.15)', borderRadius: '8px', border: '1px dashed rgba(255, 255, 255, 0.1)' },
  outputConfig: { display: 'flex', gap: '16px', alignItems: 'flex-end', marginBottom: '16px', flexWrap: 'wrap' },
  presetNameGroup: { display: 'flex', flexDirection: 'column', gap: '4px', minWidth: '240px', maxWidth: '360px' },
  presetInput: { padding: '8px 12px', backgroundColor: 'rgba(0, 0, 0, 0.4)', border: '1px solid rgba(255, 255, 255, 0.15)', borderRadius: '5px', color: '#fff', fontSize: '11px', fontFamily: 'inherit', width: '100%' },
  generateButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '10px 16px', backgroundColor: 'rgba(30, 215, 96, 0.2)', color: '#1ed760', border: '1px solid #1ed760', borderRadius: '5px', fontSize: '11px', fontWeight: '600', cursor: 'pointer', transition: 'all 0.2s', whiteSpace: 'nowrap' },
  defaultFoldersSection: { marginTop: '16px', padding: '14px', backgroundColor: 'rgba(0, 0, 0, 0.2)', borderRadius: '6px', border: '1px solid rgba(255, 255, 255, 0.08)' },
  defaultFolderRow: { display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '10px' },
  defaultFolderLabel: { fontSize: '10px', fontWeight: '600', color: '#888', minWidth: '100px', textTransform: 'uppercase', letterSpacing: '0.5px' },
  defaultFolderPath: { flex: 1, fontSize: '10px', color: '#aaa', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', padding: '6px 10px', backgroundColor: 'rgba(0, 0, 0, 0.3)', borderRadius: '4px', border: '1px solid rgba(255, 255, 255, 0.08)' },
  chooseFolderBtn: { padding: '6px 12px', backgroundColor: 'rgba(255, 255, 255, 0.08)', color: '#e0e0e8', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '4px', fontSize: '10px', cursor: 'pointer', transition: 'all 0.15s', whiteSpace: 'nowrap' },
  openFolderBtn: { padding: '6px 10px', backgroundColor: 'rgba(255, 255, 255, 0.08)', color: '#e0e0e8', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '4px', fontSize: '10px', cursor: 'pointer', transition: 'all 0.15s' },
  outputSection: { border: '1px solid rgba(30, 215, 96, 0.3)', borderRadius: '6px', overflow: 'hidden' },
  outputHeader: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 14px', backgroundColor: 'rgba(30, 215, 96, 0.1)', borderBottom: '1px solid rgba(30, 215, 96, 0.2)', flexWrap: 'wrap', gap: '8px' },
  outputTitle: { fontSize: '10px', fontWeight: '600', color: '#1ed760', textTransform: 'uppercase', letterSpacing: '1px' },
  outputActions: { display: 'flex', gap: '6px' },
  copyButton: { padding: '6px 12px', backgroundColor: 'transparent', border: '1px solid rgba(255, 255, 255, 0.2)', borderRadius: '4px', color: '#e0e0e8', fontSize: '10px', cursor: 'pointer', transition: 'all 0.15s', minWidth: '70px' },
  downloadButton: { padding: '6px 12px', backgroundColor: '#1ed760', border: 'none', borderRadius: '4px', color: '#000', fontSize: '10px', fontWeight: '600', cursor: 'pointer', transition: 'all 0.15s' },
  showKontrolButton: { padding: '6px 12px', backgroundColor: 'rgb(239, 40, 138)', border: 'none', borderRadius: '4px', color: '#fff', fontSize: '10px', fontWeight: '600', cursor: 'pointer', transition: 'all 0.15s' },
  generateSkButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '10px 16px', backgroundColor: 'rgba(239, 40, 138, 0.15)', color: '#fff', border: '1px solid rgb(239, 40, 138)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s', whiteSpace: 'nowrap' },
  xmlPreview: { margin: 0, padding: '14px', backgroundColor: 'rgba(0, 0, 0, 0.5)', fontSize: '9px', lineHeight: '1.5', color: '#a0a0b0', overflow: 'auto', maxHeight: '200px', whiteSpace: 'pre', fontFamily: "'JetBrains Mono', monospace" },
  footer: { position: 'relative', zIndex: 1, display: 'flex', justifyContent: 'center', alignItems: 'center', gap: '10px', padding: '16px', fontSize: '10px', color: '#555', borderTop: '1px solid rgba(255, 255, 255, 0.05)', flexShrink: 0 },
  footerDot: { color: '#1ed760' },
};

const lightThemeOverrides = {
  container: { display: 'flex', flexDirection: 'column', height: '100%', backgroundColor: '#f5f5f7', color: '#1d1d1f', fontFamily: "'JetBrains Mono', 'Fira Code', monospace", position: 'relative', overflow: 'auto', width: '100%' },
  gridOverlay: { position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, backgroundImage: 'linear-gradient(rgba(30, 215, 96, 0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(30, 215, 96, 0.04) 1px, transparent 1px)', backgroundSize: '50px 50px', pointerEvents: 'none', zIndex: 0 },
  header: { position: 'relative', zIndex: 1, display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '16px 24px', borderBottom: '1px solid rgba(30, 215, 96, 0.25)', background: 'linear-gradient(180deg, rgba(30, 215, 96, 0.1) 0%, transparent 100%)', flexShrink: 0 },
  logoText: { color: '#1d1d1f' },
  tagline: { fontSize: '10px', color: '#86868b' },
  projectNameDisplay: { fontSize: '11px', color: '#86868b', maxWidth: '200px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
  versionBadge: { padding: '4px 10px', backgroundColor: 'rgba(30, 215, 96, 0.15)', color: '#15a049', borderRadius: '4px', fontSize: '10px', fontWeight: '600', border: '1px solid rgba(30, 215, 96, 0.4)' },
  section: { display: 'block', marginBottom: '0', background: 'linear-gradient(135deg, rgba(255, 255, 255, 0.95) 0%, rgba(250, 250, 252, 0.98) 100%)', border: '1px solid rgba(0, 0, 0, 0.08)', borderRadius: '10px', padding: '16px 20px', transition: 'all 0.2s', boxSizing: 'border-box', width: '100%', overflow: 'hidden', minWidth: 0, boxShadow: '0 1px 3px rgba(0, 0, 0, 0.04)' },
  sectionHeader: { display: 'flex', alignItems: 'center', gap: '12px', fontSize: '12px', fontWeight: '600', color: '#1d1d1f', textTransform: 'uppercase', letterSpacing: '1px', cursor: 'pointer', userSelect: 'none', flexWrap: 'wrap', overflow: 'hidden', maxWidth: '100%' },
  dragHandle: { color: '#aeaeb2', cursor: 'grab', fontSize: '14px', marginRight: '-4px', padding: '4px' },
  collapseIcon: { marginLeft: 'auto', color: '#86868b', fontSize: '10px', transition: 'transform 0.2s' },
  enabledCounter: { fontSize: '11px', color: '#86868b', fontWeight: '400', textTransform: 'none', letterSpacing: '0', marginLeft: 'auto' },
  enabledCounterInline: { color: '#0d7a3e', fontWeight: '600' },
  columnMoveBtn: { padding: '2px 6px', backgroundColor: 'transparent', border: '1px solid rgba(0, 0, 0, 0.15)', borderRadius: '3px', color: '#86868b', fontSize: '8px', cursor: 'pointer', transition: 'all 0.15s', outline: 'none' },
  emptyColumnDropZone: { width: '100%', minHeight: '200px', border: '2px dashed rgba(30, 215, 96, 0.4)', borderRadius: '10px', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(30, 215, 96, 0.05)' },
  dropZoneText: { color: 'rgba(30, 215, 96, 0.6)', fontSize: '12px', textTransform: 'uppercase', letterSpacing: '1px' },
  label: { fontSize: '9px', color: '#86868b', textTransform: 'uppercase', letterSpacing: '1px' },
  importButtonLabel: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(0, 0, 0, 0.04)', color: '#1d1d1f', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '500', transition: 'all 0.2s', outline: 'none' },
  openButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', backgroundColor: 'rgba(0, 0, 0, 0.04)', color: '#1d1d1f', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '500', transition: 'all 0.2s', outline: 'none' },
  saveButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', backgroundColor: 'rgba(0, 0, 0, 0.04)', color: '#1d1d1f', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '500', transition: 'all 0.2s', outline: 'none' },
  clearButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', backgroundColor: 'rgba(0, 0, 0, 0.04)', color: '#1d1d1f', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '500', transition: 'all 0.2s', outline: 'none' },
  trackCount: { color: '#15a049', fontSize: '11px', fontWeight: '500' },
  settingsLabel: { fontSize: '10px', fontWeight: '600', color: '#86868b', textTransform: 'uppercase', letterSpacing: '0.5px' },
  settingsBtn: { padding: '10px 16px', backgroundColor: 'rgba(30, 215, 96, 0.15)', border: '1px solid rgba(30, 215, 96, 0.5)', borderRadius: '5px', color: '#15a049', fontSize: '11px', fontWeight: '600', cursor: 'pointer', transition: 'all 0.2s', outline: 'none' },
  settingsBtnActive: { backgroundColor: '#1ed760', borderColor: '#1ed760', color: '#000' },
  buttonGroupLabel: { fontSize: '10px', fontWeight: '600', color: '#86868b', textTransform: 'uppercase', letterSpacing: '0.5px' },
  presetInput: { padding: '8px 12px', backgroundColor: 'rgba(255, 255, 255, 0.9)', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '5px', color: '#555', fontSize: '11px', fontFamily: 'inherit', width: '100%' },
  presetInputInline: { padding: '8px 12px', backgroundColor: 'rgba(255, 255, 255, 0.9)', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '5px', color: '#555', fontSize: '11px', fontFamily: 'inherit', width: '130px', boxSizing: 'border-box' },
  seratoButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(0, 104, 169, 0.1)', color: '#0068a9', border: '1px solid rgba(0, 104, 169, 0.4)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  engineButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(91, 210, 159, 0.15)', color: '#2a9d6a', border: '1px solid rgba(91, 210, 159, 0.5)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  showKontrolImportButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(239, 40, 138, 0.1)', color: '#d02878', border: '1px solid rgba(239, 40, 138, 0.4)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  resolumeImportButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(93, 228, 199, 0.15)', color: '#1a3a35', border: '1px solid rgba(93, 228, 199, 0.6)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  createEnvelopeButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 12px', height: '36px', boxSizing: 'border-box', backgroundColor: 'rgba(255, 215, 0, 0.15)', color: '#b8860b', border: '1px solid rgba(255, 215, 0, 0.5)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s' },
  generateSkButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '10px 16px', backgroundColor: 'rgba(239, 40, 138, 0.1)', color: '#d02878', border: '1px solid rgba(239, 40, 138, 0.4)', borderRadius: '5px', cursor: 'pointer', fontSize: '11px', fontWeight: '600', transition: 'all 0.2s', whiteSpace: 'nowrap' },
  envelopeHint: { fontSize: '9px', color: '#1d1d1f', marginTop: '6px', textAlign: 'center' },
  envelopeModeBadge: { marginLeft: '10px', padding: '3px 8px', backgroundColor: 'rgba(255, 215, 0, 0.2)', color: '#b8860b', borderRadius: '4px', fontSize: '10px', fontWeight: '600' },
  undoRedoButton: { display: 'flex', alignItems: 'center', justifyContent: 'center', width: '28px', height: '28px', backgroundColor: 'rgba(0, 0, 0, 0.06)', border: '1px solid rgba(0, 0, 0, 0.15)', borderRadius: '4px', color: '#1d1d1f', cursor: 'pointer', transition: 'all 0.2s' },
  envelopeTitle: { fontSize: '10px', fontWeight: '600', color: '#0d7a3e', textTransform: 'uppercase', letterSpacing: '1px' },
  cueColName: { fontSize: '11px', color: '#1d1d1f', fontWeight: '500', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', transition: 'opacity 0.15s' },
  sidebar: { width: '200px', borderRight: '1px solid rgba(0, 0, 0, 0.08)', padding: '12px 0', display: 'flex', flexDirection: 'column', gap: '2px', flexShrink: 0, overflowY: 'auto', overflowX: 'hidden' },
  sidebarHeader: { padding: '8px 16px', fontSize: '10px', fontWeight: '600', color: '#86868b', textTransform: 'uppercase', letterSpacing: '1px' },
  playlistItem: { display: 'flex', alignItems: 'center', gap: '8px', padding: '8px 16px', cursor: 'pointer', transition: 'all 0.15s', fontSize: '12px', color: '#1d1d1f', borderLeft: '2px solid transparent' },
  playlistName: { flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: '#1d1d1f' },
  playlistCount: { fontSize: '10px', color: '#86868b', marginLeft: 'auto' },
  trackBrowser: { flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' },
  searchInput: { flex: 1, padding: '10px 12px', backgroundColor: 'rgba(255, 255, 255, 0.9)', border: '1px solid rgba(0, 0, 0, 0.1)', borderRadius: '5px', color: '#1d1d1f', fontSize: '12px', fontFamily: 'inherit' },
  sortSelect: { padding: '10px 12px', backgroundColor: 'rgba(255, 255, 255, 0.9)', border: '1px solid rgba(0, 0, 0, 0.1)', borderRadius: '5px', color: '#1d1d1f', fontSize: '11px', fontFamily: 'inherit', cursor: 'pointer' },
  trackListHeader: { display: 'grid', gridTemplateColumns: '40px 2fr 1fr 1fr 80px', padding: '8px 12px', backgroundColor: 'rgba(0, 0, 0, 0.03)', fontSize: '9px', fontWeight: '700', textTransform: 'uppercase', letterSpacing: '1px', color: '#86868b', borderBottom: '1px solid rgba(0, 0, 0, 0.06)' },
  trackItem: { display: 'grid', gridTemplateColumns: '40px 2fr 1fr 1fr 80px', padding: '10px 12px', alignItems: 'center', borderBottom: '1px solid rgba(0, 0, 0, 0.04)', cursor: 'pointer', transition: 'background-color 0.15s', fontSize: '11px', color: '#1d1d1f' },
  trackName: { fontWeight: '500', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: '#1d1d1f' },
  trackArtist: { color: '#86868b', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
  trackAlbum: { color: '#aeaeb2', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
  trackDuration: { color: '#86868b', textAlign: 'right' },
  cueTableHeader: { display: 'grid', gridTemplateColumns: '36px 32px 1fr 75px 60px 84px 165px', padding: '8px 12px', backgroundColor: 'rgba(0, 0, 0, 0.03)', fontSize: '9px', fontWeight: '700', textTransform: 'uppercase', letterSpacing: '1px', color: '#86868b', borderBottom: '1px solid rgba(0, 0, 0, 0.06)', gap: '4px' },
  cueRow: { display: 'grid', gridTemplateColumns: '36px 32px 1fr 75px 60px 84px 165px', padding: '8px 12px', alignItems: 'center', borderBottom: '1px solid rgba(0, 0, 0, 0.04)', gap: '4px', cursor: 'pointer', transition: 'background-color 0.1s' },
  cueIndex: { width: '24px', height: '24px', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0, 0, 0, 0.06)', borderRadius: '4px', fontSize: '10px', fontWeight: '700', color: '#86868b' },
  cueName: { fontWeight: '500', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', cursor: 'text', color: '#1d1d1f' },
  positionInput: { width: '70px', padding: '5px 6px', backgroundColor: 'rgba(255, 255, 255, 0.9)', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '4px', color: '#1d1d1f', fontSize: '10px', fontFamily: 'inherit', textAlign: 'center', transition: 'opacity 0.15s' },
  cueColX: { fontSize: '9px', color: '#15a049', transition: 'opacity 0.15s' },
  yInput: { width: '74px', padding: '5px 6px', backgroundColor: 'rgba(255, 255, 255, 0.9)', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '4px', color: '#1d1d1f', fontSize: '10px', fontFamily: 'inherit', textAlign: 'center', transition: 'opacity 0.15s' },
  noCues: { padding: '30px', textAlign: 'center', color: '#86868b', fontSize: '12px', backgroundColor: 'rgba(0, 0, 0, 0.03)', borderRadius: '6px' },
  emptyState: { padding: '40px 20px', textAlign: 'center', color: '#86868b', fontSize: '13px', backgroundColor: 'rgba(0, 0, 0, 0.02)', borderRadius: '8px', border: '1px dashed rgba(0, 0, 0, 0.1)' },
  generateButton: { display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '10px 16px', backgroundColor: 'rgba(30, 215, 96, 0.15)', color: '#15a049', border: '1px solid rgba(30, 215, 96, 0.5)', borderRadius: '5px', fontSize: '11px', fontWeight: '600', cursor: 'pointer', transition: 'all 0.2s', whiteSpace: 'nowrap' },
  defaultFoldersSection: { marginTop: '16px', padding: '14px', backgroundColor: 'rgba(0, 0, 0, 0.03)', borderRadius: '6px', border: '1px solid rgba(0, 0, 0, 0.06)' },
  defaultFolderRow: { display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '10px' },
  defaultFolderLabel: { fontSize: '10px', fontWeight: '600', color: '#86868b', minWidth: '100px', textTransform: 'uppercase', letterSpacing: '0.5px' },
  defaultFolderPath: { flex: 1, fontSize: '10px', color: '#1d1d1f', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', padding: '6px 10px', backgroundColor: 'rgba(255, 255, 255, 0.9)', borderRadius: '4px', border: '1px solid rgba(0, 0, 0, 0.1)' },
  chooseFolderBtn: { padding: '6px 12px', backgroundColor: 'rgba(0, 0, 0, 0.04)', color: '#1d1d1f', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '4px', fontSize: '10px', cursor: 'pointer', transition: 'all 0.15s', whiteSpace: 'nowrap' },
  openFolderBtn: { padding: '6px 10px', backgroundColor: 'rgba(0, 0, 0, 0.04)', color: '#1d1d1f', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '4px', fontSize: '10px', cursor: 'pointer', transition: 'all 0.15s' },
  outputSection: { border: '1px solid rgba(30, 215, 96, 0.3)', borderRadius: '6px', overflow: 'hidden' },
  outputHeader: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 14px', backgroundColor: 'rgba(30, 215, 96, 0.08)', borderBottom: '1px solid rgba(30, 215, 96, 0.2)', flexWrap: 'wrap', gap: '8px' },
  copyButton: { padding: '6px 12px', backgroundColor: 'transparent', border: '1px solid rgba(0, 0, 0, 0.15)', borderRadius: '4px', color: '#1d1d1f', fontSize: '10px', cursor: 'pointer', transition: 'all 0.15s', minWidth: '70px' },
  xmlPreview: { margin: 0, padding: '14px', backgroundColor: 'rgba(0, 0, 0, 0.03)', fontSize: '9px', lineHeight: '1.5', color: '#1d1d1f', overflow: 'auto', maxHeight: '200px', whiteSpace: 'pre', fontFamily: "'JetBrains Mono', monospace" },
  footer: { position: 'relative', zIndex: 1, display: 'flex', justifyContent: 'center', alignItems: 'center', gap: '10px', padding: '16px', fontSize: '10px', color: '#86868b', borderTop: '1px solid rgba(0, 0, 0, 0.06)', flexShrink: 0 },
  layoutToggleBtnInactive: { backgroundColor: 'rgba(0, 0, 0, 0.04)', borderColor: 'rgba(0, 0, 0, 0.1)', color: '#1d1d1f' },
  layoutToggleBtnActive: { backgroundColor: 'rgba(30, 215, 96, 0.15)', borderColor: '#1ed760', color: '#15a049' },
  layoutToggleBtnHover: { backgroundColor: 'rgba(30, 215, 96, 0.1)', borderColor: '#1ed760', color: '#15a049' },
  modalOverlay: { position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, backgroundColor: 'rgba(0, 0, 0, 0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000 },
  modal: { backgroundColor: '#fff', borderRadius: '12px', padding: '24px 32px', border: '1px solid rgba(30, 215, 96, 0.3)', boxShadow: '0 20px 60px rgba(0, 0, 0, 0.2)', minWidth: '320px' },
  modalTitle: { margin: '0 0 12px 0', fontSize: '18px', fontWeight: '600', color: '#1d1d1f' },
  modalText: { margin: '0 0 20px 0', fontSize: '13px', color: '#86868b' },
  modalInput: { width: '70px', padding: '10px 12px 10px 8px', backgroundColor: 'rgba(0, 0, 0, 0.04)', border: '1px solid rgba(0, 0, 0, 0.15)', borderRadius: '6px', color: '#1d1d1f', fontSize: '16px', fontFamily: 'inherit', textAlign: 'center' },
  modalLabel: { color: '#86868b', fontSize: '13px' },
  modalLabelCenter: { color: '#86868b', fontSize: '12px', textAlign: 'center', width: '70px' },
  modalSeparator: { color: '#1d1d1f', fontSize: '20px', fontWeight: '600' },
  modalCancelButton: { padding: '10px 20px', backgroundColor: 'transparent', border: '1px solid rgba(0, 0, 0, 0.15)', borderRadius: '6px', color: '#86868b', fontSize: '13px', fontWeight: '500', cursor: 'pointer', transition: 'all 0.2s' },
  modalConfirmButton: { padding: '10px 20px', backgroundColor: '#1ed760', border: 'none', borderRadius: '6px', color: '#000', fontSize: '13px', fontWeight: '600', cursor: 'pointer', transition: 'all 0.2s' },
};

function getThemedStyles(theme) {
  if (theme === 'light') {
    return { ...styles, ...lightThemeOverrides };
  }
  return styles;
}
