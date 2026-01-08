// Environment config
const PROD_ENV = 'media-display.projecttechcycle.org'; // production hostname

const LOCAL_CONFIG = {
    WEBSOCKET_URL: 'http://localhost',
    WEBSOCKET_PORT: 5001,
    WEBSOCKET_SSL_CERT_VERIFY: false, // For local testing with self-signed certs
    WEBSOCKET_SUB_PATH: '/notis/media-display/socket.io',
    DEF_ALBUM_ART_PATH: 'assets/images/cat.jpg',
};

const PROD_CONFIG = {
    WEBSOCKET_URL: null, // Will be determined dynamically if not set
    WEBSOCKET_PORT: null,
    WEBSOCKET_SSL_CERT_VERIFY: true, // MUST set to true in production
    WEBSOCKET_SUB_PATH: '/notis/media-display/socket.io',
    DEF_ALBUM_ART_PATH: 'assets/images/cat.jpg',
}

// Auto-detect environment based on hostname
const hostname = window.location.hostname;

// Select configuration based on environment
const selectedConfig = hostname === PROD_ENV ? PROD_CONFIG : LOCAL_CONFIG;

// Determine WebSocket URL
let WEBSOCKET_URL;
if (selectedConfig.WEBSOCKET_URL) {
    WEBSOCKET_URL = selectedConfig.WEBSOCKET_URL;
} else {
    // If not set, determine from browser root URL
    const hostname = window.location.hostname || 'localhost';
    const protocol = window.location.protocol === 'https:' ? 'https' : 'http';
    WEBSOCKET_URL = `${protocol}://${hostname}`;
}

// Handle WEBSOCKET_PORT - append port if set in config or available from browser
if (selectedConfig.WEBSOCKET_PORT) {
    WEBSOCKET_URL = `${WEBSOCKET_URL}:${selectedConfig.WEBSOCKET_PORT}`;
} else if (window.location.port) {
    WEBSOCKET_URL = `${WEBSOCKET_URL}:${window.location.port}`;
}

// Note: WEBSOCKET_SUB_PATH is now handled in Socket.IO path option, not in URL
// This allows proper Socket.IO routing through nginx subpaths

// Set DEF_ALBUM_ART_PATH with default fallback
const DEF_ALBUM_ART_PATH = selectedConfig.DEF_ALBUM_ART_PATH || 'assets/images/cat.jpg';

// DOM elements
const elements = {
    loading: document.getElementById('loading'),
    noPlayback: document.getElementById('no-playback'),
    nowPlaying: document.getElementById('now-playing'),
    albumArt: document.getElementById('album-art'),
    trackName: document.getElementById('track-name'),
    artistName: document.getElementById('artist-name'),
    albumName: document.getElementById('album-name'),
    deviceName: document.getElementById('device-name'),
    playbackStatus: document.getElementById('playback-status'),
    connectionStatus: document.getElementById('app-settings'),
    screensaverImage: document.getElementById('screensaver-image'),
    equalizer: document.getElementById('equalizer'),
    equalizerIcon: document.getElementById('equalizer-icon'),
    progressComet: null // Will be created dynamically
};

// Screensaver images - loaded dynamically from folder
let screensaverImages = [];
let screensaverImagesLoaded = false;
let currentScreensaverIndex = 0;
let screensaverInterval = null;

// Function to load screensaver images from directory
async function loadScreensaverImages() {
    if (screensaverImagesLoaded) {
        return screensaverImages;
    }
    
    try {
        console.log('Loading screensaver images...');
        const response = await fetch('assets/images/screensavers/', {
            cache: 'default' // Use HTTP cache according to Cache-Control headers
        });
        
        if (!response.ok) {
            throw new Error(`Failed to fetch directory listing: ${response.status}`);
        }
        
        const html = await response.text();
        
        // Parse HTML to extract image filenames
        const parser = new DOMParser();
        const doc = parser.parseFromString(html, 'text/html');
        const links = doc.querySelectorAll('a');
        
        const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg'];
        const images = [];
        
        links.forEach(link => {
            const href = link.getAttribute('href');
            if (href && href !== '../' && href !== '..') {
                const lowerHref = href.toLowerCase();
                if (imageExtensions.some(ext => lowerHref.endsWith(ext))) {
                    images.push(`assets/images/screensavers/${href}`);
                }
            }
        });
        
        if (images.length === 0) {
            console.warn('No screensaver images found in directory');
            // Fallback to a default image if available
            images.push(DEF_ALBUM_ART_PATH);
        }
        
        screensaverImages = images;
        screensaverImagesLoaded = true;
        
        console.log(`Loaded ${images.length} screensaver image paths (will load on-demand)`);
        
        return screensaverImages;
    } catch (error) {
        console.error('Error loading screensaver images:', error);
        // Fallback to default image
        screensaverImages = ['assets/cat.jpg'];
        screensaverImagesLoaded = true;
        return screensaverImages;
    }
}

// Load image on-demand - browser will use cache if available
// No preloading - images are fetched one at a time as needed

// Show error message in screensaver image box (using SVG to maintain square box)
function showScreensaverError(message, subMessage = '') {
    if (elements.screensaverImage) {
        // Create an SVG with spinning loader and text
        const svg = `
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600" width="100%" height="100%">
                <defs>
                    <style>
                        @keyframes spin {
                            to { transform: rotate(360deg); }
                        }
                        .spinner-circle {
                            animation: spin 1s linear infinite;
                            transform-origin: 300px 220px;
                        }
                    </style>
                </defs>
                <rect width="600" height="600" fill="#1a1a1a"/>
                
                <!-- Spinning loader circle -->
                <g class="spinner-circle">
                    <circle cx="300" cy="220" r="35" fill="none" stroke="rgba(255, 255, 255, 0.1)" stroke-width="4"/>
                    <path d="M 300 185 A 35 35 0 0 1 335 220" fill="none" stroke="#1DB954" stroke-width="4" stroke-linecap="round"/>
                </g>
                
                <text x="300" y="310" font-size="32" font-weight="normal" text-anchor="middle" fill="#ffffff" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif" opacity="0.8">${message}</text>
                <text x="300" y="350" font-size="28" font-weight="normal" text-anchor="middle" fill="#cccccc" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif" opacity="0.5">${subMessage}</text>
            </svg>
        `;
        
        // Convert SVG to data URL
        const svgBlob = new Blob([svg], { type: 'image/svg+xml' });
        const url = URL.createObjectURL(svgBlob);
        
        // Set as image source to maintain square aspect ratio and glow effect
        elements.screensaverImage.src = url;
        elements.screensaverImage.style.opacity = '1';
        
        // Clean up old blob URLs
        setTimeout(() => URL.revokeObjectURL(url), 100);
    }
}

// Hide error message by restoring image loading
function hideScreensaverError() {
    // This will be called when ready to retry images
}

// Glow effect state management
let glowState = 'off'; // 'off', 'all-colors', 'white', 'white-fast', 'all-colors-fast', 'album-colors', 'album-colors-fast'
const GLOW_STATES = ['off', 'all-colors', 'white', 'white-fast', 'all-colors-fast', 'album-colors', 'album-colors-fast'];

// Equalizer state management
let equalizerState = 'off'; // 'off', 'normal', 'colors', 'white'
const EQUALIZER_STATES = ['off', 'normal', 'border-white', 'white', 'navy', 'blue-spectrum', 'colors', 'spectrum',  'bass-white-glow', 'bass-color-glow'];
let isPlaying = false; // Track current playback state
let equalizerAutoEnabled = false; // Track if equalizer was auto-enabled by progress effect

// Progress effect state management
let progressEffectState = 'off'; // 'off', 'comet', 'album-comet', 'across-comet', 'equalizer-fill'
const PROGRESS_EFFECT_STATES = ['off', 'comet', 'album-comet', 'across-comet', 'equalizer-fill'];

// Effect name mappings for UI labels
const GLOW_EFFECT_NAMES = {
    'off': 'Off',
    'all-colors': 'Colors',
    'white': 'White',
    'white-fast': 'Fast White',
    'all-colors-fast': 'Fast Colors',
    'album-colors': 'Album Colors',
    'album-colors-fast': 'Fast Album Colors'
};

const EQUALIZER_EFFECT_NAMES = {
    'off': 'Off',
    'normal': 'Normal',
    'border-white': 'White Border',
    'white': 'White',
    'navy': 'Navy',
    'blue-spectrum': 'Blue Spectrum',
    'colors': 'Colors',
    'spectrum': 'Color Spectrum',
    'bass-white-glow': 'Fast White Album Glow',
    'bass-color-glow': 'Fast Color Album Glow'
};

const PROGRESS_EFFECT_NAMES = {
    'off': 'Off',
    'comet': 'Edge Comet',
    'album-comet': 'Album Comet',
    'across-comet': 'Across Comet',
    'equalizer-fill': 'Equalizer Fill'
};

// WebSocket connection
let socket = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 10;
let currentDeviceList = []; // Store full device list
let currentAlbumName = ''; // Store current album name
let currentAlbumColors = []; // Store colors extracted from album art
let rotationState = 0; // 0, 90, 180, 270 degrees

// Cursor auto-hide in fullscreen
let cursorHideTimeout = null;
const CURSOR_HIDE_DELAY = 3000; // Hide cursor after 3 seconds of inactivity

// Progress tracking for comet animation
let progressState = {
    progressMs: 0,
    durationMs: 0,
    lastUpdateTime: null,
    isPlaying: false,
    animationFrameId: null
};

// Initialize WebSocket connection
function connectWebSocket() {
    // Note: In browsers, SSL certificate verification cannot be disabled programmatically.
    // For self-signed certificates, you must manually trust the certificate in your browser:
    // 1. Visit https://localhost:5001 in your browser
    // 2. Accept the security warning to trust the self-signed certificate
    // 3. Then reload this page
    
    socket = io(WEBSOCKET_URL, {
        path: selectedConfig.WEBSOCKET_SUB_PATH ? `${selectedConfig.WEBSOCKET_SUB_PATH}` : '/socket.io',
        transports: ['websocket', 'polling'],
        reconnection: true,
        reconnectionDelay: 1000,
        reconnectionDelayMax: 5000,
        reconnectionAttempts: MAX_RECONNECT_ATTEMPTS
    });
    
    // Connection events
    socket.on('connect', () => {
        console.log('Connected to server');
        reconnectAttempts = 0;
        updateConnectionStatus('connected');
        
        // Request current track
        socket.emit('request_current_track');
        
        // Notify server of current progress effect state
        if (progressEffectState !== 'off') {
            socket.emit('enable_progress');
            console.log('📊 Re-enabled progress updates after reconnect');
        } else {
            socket.emit('disable_progress');
            console.log('⏸️  Progress disabled (state: off)');
        }
    });
    
    socket.on('disconnect', () => {
        console.log('Disconnected from server');
        updateConnectionStatus('disconnected');
        showLoading('Reconnecting...');
    });
    
    socket.on('connect_error', (error) => {
        console.error('Connection error:', error);
        reconnectAttempts++;
        updateConnectionStatus('connecting');
        
        // Hide app settings during connection error
        if (elements.connectionStatus) {
            elements.connectionStatus.style.display = 'none';
        }
        if (elements.equalizer) {
            elements.equalizer.classList.add('hidden');
        }
        
        if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
            showLoading('Connection failed. Refresh to retry.');
        }
    });
    
    // Track update event
    socket.on('track_update', (data) => {
        updateDisplay(data);
    });
    
    // Service status event
    socket.on('service_status', (data) => {
        updateServiceIcons(data);
    });
}

// Update connection status indicator
function updateConnectionStatus(status) {
    // Remove all status classes from body
    document.body.classList.remove('connected', 'connecting', 'disconnected');
    
    // Add current status class to body for border glow effect
    document.body.classList.add(status);
    
    // Keep the app-settings class unchanged
    elements.connectionStatus.className = 'app-settings';
}

// Update service icons based on active services
function updateServiceIcons(serviceStatus) {
    const sonosIcon = document.getElementById('service-sonos');
    const spotifyIcon = document.getElementById('service-spotify');
    
    if (serviceStatus.sonos) {
        sonosIcon.classList.remove('hidden');
        console.log('✓ Sonos service active');
    } else {
        sonosIcon.classList.add('hidden');
    }
    
    if (serviceStatus.spotify) {
        spotifyIcon.classList.remove('hidden');
        console.log('✓ Spotify service active');
    } else {
        spotifyIcon.classList.add('hidden');
    }
}

// Show loading state
function showLoading(message = 'Connecting...') {
    elements.loading.classList.remove('hidden');
    elements.noPlayback.classList.add('hidden');
    elements.nowPlaying.classList.add('hidden');
    elements.loading.querySelector('p').textContent = message;
    document.body.classList.remove('no-playback-active');
    
    // Hide equalizer and app settings during loading/reconnecting
    if (elements.equalizer) {
        elements.equalizer.classList.add('hidden');
    }
    if (elements.connectionStatus) {
        elements.connectionStatus.style.display = 'none';
    }
    
    // Hide progress comet during loading
    hideProgressComet();
    
    stopScreensaverCycle();
}

// Show no playback state
function showNoPlayback() {
    elements.loading.classList.add('hidden');
    elements.noPlayback.classList.remove('hidden');
    elements.nowPlaying.classList.add('hidden');
    document.body.classList.add('no-playback-active');
    isPlaying = false;
    
    // Show app settings in no-playback state (unless expanded)
    if (elements.connectionStatus) {
        elements.connectionStatus.style.display = '';
    }
    
    // Hide progress comet in no playback/screensaver mode
    hideProgressComet();
    
    updateEqualizerVisibility();
    startScreensaverCycle();
}

// Retry state management
let retryState = {
    startTime: null,
    lastRetryTime: null,
    retryPhase: 'active', // 'active' or 'paused'
    retryTimeoutId: null,
    currentImageLoaded: false
};

// Start screensaver image cycling
async function startScreensaverCycle() {
    // Load images on first activation
    await loadScreensaverImages();
    
    // Initialize retry state
    retryState.startTime = Date.now();
    retryState.lastRetryTime = Date.now();
    retryState.retryPhase = 'active';
    retryState.currentImageLoaded = false;
    
    // Set initial random image
    if (elements.screensaverImage && screensaverImages.length > 0) {
        currentScreensaverIndex = Math.floor(Math.random() * screensaverImages.length);
        
        // Function to load image with error handling and retry logic
        const loadImage = (index, isRetrying = false) => {
            const now = Date.now();
            const elapsedTotal = now - retryState.startTime;
            const elapsedSinceRetry = now - retryState.lastRetryTime;
            
            // Only show timeout error if we're in retry mode AND 30 minutes have elapsed
            // Don't show error if images are loading successfully
            if (isRetrying && elapsedTotal > 30 * 60 * 1000) {
                console.log('Retry timeout (30 minutes) reached while attempting to load failed images');
                showScreensaverError('Image Load Failed', 'Unable to load images after 30 minutes');
                return;
            }
            
            // Check retry phase timing (only relevant when isRetrying is true)
            if (isRetrying) {
                if (retryState.retryPhase === 'active') {
                    // Check if 1 minute of retrying has passed
                    if (elapsedSinceRetry > 60 * 1000) {
                        console.log('Retry phase complete. Pausing for 5 minutes...');
                        retryState.retryPhase = 'paused';
                        retryState.lastRetryTime = now;
                        showScreensaverError('Image Load Failed', 'Retrying in 5 minutes...');
                        
                        // Schedule resume after 5 minutes
                        retryState.retryTimeoutId = setTimeout(() => {
                            console.log('Resuming retry attempts...');
                            retryState.retryPhase = 'active';
                            retryState.lastRetryTime = Date.now();
                            loadImage(index, true);
                        }, 5 * 60 * 1000);
                        return;
                    }
                } else if (retryState.retryPhase === 'paused') {
                    // Still in pause phase, don't retry yet
                    return;
                }
            }
            
            const imageSrc = screensaverImages[index];
            
            // Set up error/load handlers before setting src to avoid duplicate requests
            const handleLoad = () => {
                elements.screensaverImage.style.opacity = '1';
                retryState.currentImageLoaded = true;
                console.log(`✓ Successfully loaded: ${imageSrc}`);
                // Remove handlers after use
                elements.screensaverImage.removeEventListener('load', handleLoad);
                elements.screensaverImage.removeEventListener('error', handleError);
            };
            
            const handleError = () => {
                // Image failed to load
                console.error(`✗ Failed to load screensaver image: ${imageSrc}`);
                const filename = imageSrc.split('/').pop();
                showScreensaverError('Image Load Error', `Failed: ${filename}`);
                retryState.currentImageLoaded = false;
                
                // Try next image if available
                if (screensaverImages.length > 1) {
                    const nextIndex = (index + 1) % screensaverImages.length;
                    if (nextIndex !== index) {
                        console.log('Trying next image...');
                        setTimeout(() => loadImage(nextIndex, true), 2000);
                    } else {
                        // Tried all images, wait and retry
                        console.log('All images failed. Retrying...');
                        setTimeout(() => loadImage(index, true), 3000);
                    }
                } else {
                    // Only one image, retry it
                    setTimeout(() => loadImage(index, true), 3000);
                }
                // Remove handlers after use
                elements.screensaverImage.removeEventListener('load', handleLoad);
                elements.screensaverImage.removeEventListener('error', handleError);
            };
            
            // Attach handlers before setting src
            elements.screensaverImage.addEventListener('load', handleLoad);
            elements.screensaverImage.addEventListener('error', handleError);
            
            // Set src directly on the actual element (no intermediate test image)
            elements.screensaverImage.src = imageSrc;
        };
        
        // Load initial image
        loadImage(currentScreensaverIndex, false);
        
        // Clear any existing interval
        if (screensaverInterval) {
            clearInterval(screensaverInterval);
        }
        
        // Start cycling through images randomly (only if images load successfully)
        screensaverInterval = setInterval(() => {
            // Only cycle if current image loaded successfully
            if (retryState.currentImageLoaded) {
                // Fade out current image
                elements.screensaverImage.style.opacity = '0';
                
                setTimeout(() => {
                    // Select random image different from current
                    let newIndex;
                    do {
                        newIndex = Math.floor(Math.random() * screensaverImages.length);
                    } while (newIndex === currentScreensaverIndex && screensaverImages.length > 1);
                    
                    currentScreensaverIndex = newIndex;
                    
                    // Reset retry state for new image
                    retryState.currentImageLoaded = false;
                    
                    // Load new image with error handling
                    loadImage(currentScreensaverIndex, false);
                }, 500);
            }
        }, 30000); // Change image every 30 seconds
    } else if (elements.screensaverImage) {
        // No images available
        showScreensaverError('No Images Available', 'Add images to screensavers folder');
    }
}

// Stop screensaver cycling
function stopScreensaverCycle() {
    if (screensaverInterval) {
        clearInterval(screensaverInterval);
        screensaverInterval = null;
    }
    
    // Clear any pending retry timeouts
    if (retryState.retryTimeoutId) {
        clearTimeout(retryState.retryTimeoutId);
        retryState.retryTimeoutId = null;
    }
    
    // Reset retry state
    retryState = {
        startTime: null,
        lastRetryTime: null,
        retryPhase: 'active',
        retryTimeoutId: null,
        currentImageLoaded: false
    };
}

// Show now playing
function showNowPlaying() {
    elements.loading.classList.add('hidden');
    elements.noPlayback.classList.add('hidden');
    elements.nowPlaying.classList.remove('hidden');
    document.body.classList.remove('no-playback-active');
    
    // Show app settings in now-playing state
    if (elements.connectionStatus) {
        elements.connectionStatus.style.display = '';
    }
    
    stopScreensaverCycle();
}

// Calculate relative luminance (WCAG formula)
function getLuminance(r, g, b) {
    // Normalize RGB values
    const [rs, gs, bs] = [r, g, b].map(val => {
        val = val / 255;
        return val <= 0.03928 ? val / 12.92 : Math.pow((val + 0.055) / 1.055, 2.4);
    });
    
    // Calculate luminance
    return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
}

// Extract dominant colors from image
function extractColors(imageElement, callback) {
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d');
    
    // Use small canvas for better performance
    canvas.width = 150;
    canvas.height = 150;
    
    try {
        // Draw the already-loaded image directly to canvas (no additional request)
        ctx.drawImage(imageElement, 0, 0, canvas.width, canvas.height);
        
        const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
        const pixels = imageData.data;
        const colorMap = {};
        
        // Sample pixels and count colors
        for (let i = 0; i < pixels.length; i += 4 * 5) { // Sample every 5th pixel for better coverage
            const r = pixels[i];
            const g = pixels[i + 1];
            const b = pixels[i + 2];
            const a = pixels[i + 3];
            
            // Skip transparent pixels and extreme dark/light pixels
            if (a < 128 || (r < 10 && g < 10 && b < 10) || (r > 245 && g > 245 && b > 245)) {
                continue;
            }
            
            // Group similar colors with finer precision
            const key = `${Math.floor(r/15)*15},${Math.floor(g/15)*15},${Math.floor(b/15)*15}`;
            colorMap[key] = (colorMap[key] || 0) + 1;
        }
        
        // Get top colors
        const sortedColors = Object.entries(colorMap)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 3)
            .map(([color]) => {
                const [r, g, b] = color.split(',').map(Number);
                return { r, g, b };
            });
        
        if (sortedColors.length >= 2) {
            callback(sortedColors);
        }
    } catch (e) {
        console.warn('Could not extract colors from image:', e);
    }
}

// Apply glow colors to an image element
function applyGlowColors(imageElement, colors) {
    if (!colors || colors.length === 0) return;
    
    // Store colors globally for album-colors glow state
    currentAlbumColors = colors;
    
    const glowIcon = document.getElementById('glow-icon');
    const screensaverImage = document.getElementById('screensaver-image');
    
    // Set CSS variables for all extracted colors (for album-colors animation)
    colors.forEach((color, index) => {
        let r = color.r;
        let g = color.g;
        let b = color.b;
        
        // Brighten dark colors for better visibility in glow effect
        const brightness = (r + g + b) / 3;
        if (brightness < 80) {
            const brightenFactor = Math.max(2.5, 150 / brightness);
            r = Math.min(255, Math.round(r * brightenFactor));
            g = Math.min(255, Math.round(g * brightenFactor));
            b = Math.min(255, Math.round(b * brightenFactor));
        }
        
        // Set on all elements that need it
        imageElement.style.setProperty(`--album-color-${index + 1}-r`, r);
        imageElement.style.setProperty(`--album-color-${index + 1}-g`, g);
        imageElement.style.setProperty(`--album-color-${index + 1}-b`, b);
        
        if (glowIcon) {
            glowIcon.style.setProperty(`--album-color-${index + 1}-r`, r);
            glowIcon.style.setProperty(`--album-color-${index + 1}-g`, g);
            glowIcon.style.setProperty(`--album-color-${index + 1}-b`, b);
        }
        
        if (screensaverImage) {
            screensaverImage.style.setProperty(`--album-color-${index + 1}-r`, r);
            screensaverImage.style.setProperty(`--album-color-${index + 1}-g`, g);
            screensaverImage.style.setProperty(`--album-color-${index + 1}-b`, b);
        }
    });
    
    // Use the first dominant color for single-color glow effect
    const color = colors[0];
    let r = color.r;
    let g = color.g;
    let b = color.b;
    
    // Brighten dark colors for better visibility in glow effect
    const brightness = (r + g + b) / 3;
    if (brightness < 80) {
        // If color is too dark, brighten it significantly
        const brightenFactor = Math.max(2.5, 150 / brightness);
        r = Math.min(255, Math.round(r * brightenFactor));
        g = Math.min(255, Math.round(g * brightenFactor));
        b = Math.min(255, Math.round(b * brightenFactor));
    }
    
    // Set CSS variables for the glow colors
    imageElement.style.setProperty('--glow-color-1', `rgba(${r}, ${g}, ${b}, 0.6)`);
    imageElement.style.setProperty('--glow-color-2', `rgba(${r}, ${g}, ${b}, 0.4)`);
    imageElement.style.setProperty('--glow-color-3', `rgba(${r}, ${g}, ${b}, 0.2)`);
}

// Apply gradient background and appropriate text color
function applyGradientBackground(colors) {
    // Darken colors for background
    const bgColors = colors.map(color => {
        const darkenFactor = 0.65;
        const saturationBoost = 1.1;
        
        // Calculate luminance for adaptive darkening
        const luminance = getLuminance(color.r, color.g, color.b);
        const adjustedDarken = luminance > 0.7 ? 0.5 : darkenFactor;
        
        // Apply darkening with saturation preservation
        const nr = Math.floor(color.r * adjustedDarken * saturationBoost);
        const ng = Math.floor(color.g * adjustedDarken * saturationBoost);
        const nb = Math.floor(color.b * adjustedDarken * saturationBoost);
        
        return `rgb(${Math.min(255, nr)}, ${Math.min(255, ng)}, ${Math.min(255, nb)})`;
    });
    
    // Create gradient
    const gradient = `linear-gradient(135deg, ${bgColors[0]}, ${bgColors[1] || bgColors[0]}, ${bgColors[2] || bgColors[1] || bgColors[0]})`;
    document.body.style.transition = 'background 1s ease';
    document.body.style.background = gradient;
    
    // Calculate average luminance of background colors
    const avgLuminance = colors.reduce((sum, color) => {
        return sum + getLuminance(color.r, color.g, color.b);
    }, 0) / colors.length;
    
    // Adjust for darkening factor
    const backgroundLuminance = avgLuminance * 0.65;
    
    // Determine text color based on background luminance
    const trackInfo = document.querySelector('.track-info');
    const deviceInfo = document.querySelector('.device-info');
    
    if (trackInfo) {
        if (backgroundLuminance < 0.4) {
            // Dark background - use white text with shadow
            trackInfo.style.setProperty('--text-color', '#ffffff');
            trackInfo.style.setProperty('--text-shadow', '0 2px 8px rgba(0, 0, 0, 0.8)');
            if (deviceInfo) {
                deviceInfo.style.color = 'rgba(255, 255, 255, 0.7)';
                deviceInfo.style.textShadow = '0 1px 4px rgba(0, 0, 0, 0.6)';
            }
        } else {
            // Light background - use dark text with light shadow
            trackInfo.style.setProperty('--text-color', '#1a1a1a');
            trackInfo.style.setProperty('--text-shadow', '0 2px 8px rgba(255, 255, 255, 0.6)');
            if (deviceInfo) {
                deviceInfo.style.color = 'rgba(26, 26, 26, 0.7)';
                deviceInfo.style.textShadow = '0 1px 4px rgba(255, 255, 255, 0.6)';
            }
        }
    }
}

// Create progress comet element
function createProgressComet() {
    if (elements.progressComet) return; // Already exists
    
    const comet = document.createElement('div');
    comet.id = 'progress-comet';
    comet.className = 'progress-comet hidden';
    
    // Set default colors (white) in case album colors aren't loaded yet
    comet.style.setProperty('--comet-color-1', 'rgba(255, 255, 255, 1)');
    comet.style.setProperty('--comet-color-2', 'rgba(255, 255, 255, 0.8)');
    comet.style.setProperty('--comet-color-3', 'rgba(255, 255, 255, 0.6)');
    
    // Add trail elements for comet effect
    for (let i = 0; i < 5; i++) {
        const trail = document.createElement('div');
        trail.className = 'comet-trail';
        trail.style.opacity = (5 - i) / 5 * 0.8;
        comet.appendChild(trail);
    }
    
    document.body.appendChild(comet);
    elements.progressComet = comet;
    
    console.log('Progress comet created');
}

// Update progress comet position and colors
function updateProgressComet() {
    if (!elements.progressComet || !progressState.durationMs) return;
    
    const { progressMs, durationMs } = progressState;
    
    let width, height, perimeter, offsetX = 0, offsetY = 0;
    let x, y, rotation, adjustedX, adjustedY, adjustedRotation;
    
    // Get effective screen dimensions based on rotation
    // At 90° and 270°, width and height are swapped
    const effectiveWidth = (rotationState === 90 || rotationState === 270) ? window.innerHeight : window.innerWidth;
    const effectiveHeight = (rotationState === 90 || rotationState === 270) ? window.innerWidth : window.innerHeight;
    
    // Determine if comet should follow screen, album art, or horizontal bottom path
    if (progressEffectState === 'across-comet') {
        // Across comet: move from left to right at bottom of screen
        width = effectiveWidth;
        height = effectiveHeight;
        
        const completionTarget = 0.98;
        const percentage = Math.min(Math.max(progressMs / durationMs, 0), 1) / completionTarget;
        
        // Position at bottom of screen, moving from left to right
        x = Math.min(percentage, 1) * width;
        y = height;
        rotation = 0; // Always pointing right
        
        // Use the adjusted coordinates directly
        adjustedX = x;
        adjustedY = y;
        adjustedRotation = rotation;
        
        // Apply coordinate transformation for rotation state
        if (rotationState === 90) {
            adjustedX = y;
            adjustedY = width - x;
            adjustedRotation = rotation + 90 + 180;
        } else if (rotationState === 180) {
            adjustedX = width - x;
            adjustedY = height - y;
            adjustedRotation = rotation + 180;
        } else if (rotationState === 270) {
            adjustedX = height - y;
            adjustedY = x;
            adjustedRotation = rotation + 270 + 180;
        }
        
        // Set position and rotation
        elements.progressComet.style.left = adjustedX + 'px';
        elements.progressComet.style.top = adjustedY + 'px';
        elements.progressComet.style.setProperty('--comet-rotation', adjustedRotation + 'deg');
        return;
    } else if (progressEffectState === 'album-comet') {
        // Get album art container dimensions and position
        const albumArtContainer = document.querySelector('#now-playing .album-art-container');
        if (!albumArtContainer) {
            // If album art not available, hide comet temporarily but don't stop animation
            if (elements.progressComet) {
                elements.progressComet.style.opacity = '0';
            }
            return;
        }
        
        // Album art is available, ensure comet is visible
        if (elements.progressComet) {
            elements.progressComet.style.opacity = '';
        }
        
        const rect = albumArtContainer.getBoundingClientRect();
        width = rect.width;
        height = rect.height;
        offsetX = rect.left;
        offsetY = rect.top;
        perimeter = 2 * (width + height);
    } else {
        // Calculate position around screen perimeter using effective dimensions
        width = effectiveWidth;
        height = effectiveHeight;
        perimeter = 2 * (width + height);
    }
    
    // Speed up comet to complete lap at 99% of song duration
    // This ensures it finishes the full circuit before song ends/transitions
    // Formula: Make the comet travel the full perimeter when song reaches 99%
    const completionTarget = 0.98; // Complete lap at 98% of song
    const percentage = Math.min(Math.max(progressMs / durationMs, 0), 1) / completionTarget;
    
    // Calculate distance traveled around perimeter (0 to perimeter)
    // At 0% song progress: distance = 0 (bottom-left start)
    // At 99% song progress: distance = perimeter (back to bottom-left, full lap complete)
    // At 99-100%: comet stays at start position waiting for next track
    const distance = Math.min(percentage, 1) * perimeter;
    
    const cornerTransition = 50; // Distance over which rotation occurs at corner
    
    // Segment 1: Left edge - going UP from bottom-left (0,height) to top-left (0,0)
    if (distance <= height) {
        x = 0;
        y = height - distance;
        rotation = 270; // Moving up
        
        // Approaching top-left corner - start rotating towards right (0°)
        if (distance > height - cornerTransition) {
            const progress = (distance - (height - cornerTransition)) / cornerTransition;
            rotation = 270 + (progress * 90); // 270° -> 360° (0°)
        }
    }
    // Segment 2: Top edge - going RIGHT from top-left (0,0) to top-right (width,0)
    else if (distance <= height + width) {
        const segmentDist = distance - height;
        x = segmentDist;
        y = 0;
        rotation = 0; // Moving right
        
        // Approaching top-right corner - start rotating towards down (90°)
        if (segmentDist > width - cornerTransition) {
            const progress = (segmentDist - (width - cornerTransition)) / cornerTransition;
            rotation = 0 + (progress * 90); // 0° -> 90°
        }
    }
    // Segment 3: Right edge - going DOWN from top-right (width,0) to bottom-right (width,height)
    else if (distance <= 2 * height + width) {
        const segmentDist = distance - (height + width);
        x = width;
        y = segmentDist;
        rotation = 90; // Moving down
        
        // Approaching bottom-right corner - start rotating towards left (180°)
        if (segmentDist > height - cornerTransition) {
            const progress = (segmentDist - (height - cornerTransition)) / cornerTransition;
            rotation = 90 + (progress * 90); // 90° -> 180°
        }
    }
    // Segment 4: Bottom edge - going LEFT from bottom-right (width,height) to bottom-left (0,height)
    else {
        const segmentDist = distance - (2 * height + width);
        x = width - segmentDist;
        y = height;
        rotation = 180; // Moving left
        
        // Approaching bottom-left corner - start rotating towards up (270°)
        if (segmentDist > width - cornerTransition) {
            const progress = (segmentDist - (width - cornerTransition)) / cornerTransition;
            rotation = 180 + (progress * 90); // 180° -> 270°
        }
    }
    
    // Adjust position and rotation based on canvas rotation state
    // Transform coordinates from logical space to screen space
    adjustedX = x;
    adjustedY = y;
    adjustedRotation = rotation;
    
    // Apply coordinate transformation for both screen-edge and album-comet modes
    // For album-comet, path is calculated in logical space relative to rect dimensions
    if (rotationState === 90) {
        // Canvas rotated -90deg (clockwise): 
        // Left→Bottom, Top→Left, Right→Top, Bottom→Right
        // Logical (x,y) -> Screen (y, width-x)
        adjustedX = y;
        adjustedY = width - x;
        adjustedRotation = rotation + 90 + 180; // Add 180 to flip orientation
    } else if (rotationState === 180) {
        // Canvas rotated -180deg: transform coordinates
        // Logical (x,y) -> Screen (width-x, height-y)
        adjustedX = width - x;
        adjustedY = height - y;
        adjustedRotation = rotation + 180;
    } else if (rotationState === 270) {
        // Canvas rotated -270deg (counter-clockwise from 180):
        // Left→Top, Top→Right, Right→Bottom, Bottom→Left
        // Logical (x,y) -> Screen (height-y, x)
        adjustedX = height - y;
        adjustedY = x;
        adjustedRotation = rotation + 270 + 180; // Add 180 to flip orientation
    }
    
    // Apply offset for album art mode (after rotation transformation)
    if (progressEffectState === 'album-comet') {
        adjustedX += offsetX;
        adjustedY += offsetY;
    }
    
    // Apply position
    elements.progressComet.style.left = `${adjustedX}px`;
    elements.progressComet.style.top = `${adjustedY}px`;
    elements.progressComet.style.setProperty('--comet-rotation', `${adjustedRotation}deg`);
    
    // Apply colors from album art if available
    if (currentAlbumColors.length > 0) {
        // For comet effect, select the most vibrant colors (not just most frequent)
        // Sort by vibrancy: combination of saturation and brightness
        const colorsByVibrancy = [...currentAlbumColors].sort((a, b) => {
            const calcVibrancy = (color) => {
                const brightness = (color.r + color.g + color.b) / 3;
                const max = Math.max(color.r, color.g, color.b);
                const min = Math.min(color.r, color.g, color.b);
                const saturation = max > 0 ? (max - min) / max : 0;
                // Prioritize colors that are both bright and saturated
                return brightness * 0.6 + saturation * 255 * 0.4;
            };
            return calcVibrancy(b) - calcVibrancy(a);
        });
        
        const color1 = colorsByVibrancy[0] || currentAlbumColors[0];
        const color2 = colorsByVibrancy[1] || currentAlbumColors[1] || color1;
        const color3 = colorsByVibrancy[2] || currentAlbumColors[2] || color2;
        
        // Brighten colors moderately for comet visibility
        const brightenColor = (color, factor = 2.5) => {
            const brightness = (color.r + color.g + color.b) / 3;
            let adjustFactor = factor;
            
            // Extra brightening for very dark colors
            if (brightness < 60) {
                adjustFactor = Math.max(3.5, 200 / brightness);
            } else if (brightness < 100) {
                adjustFactor = Math.max(2.8, 150 / brightness);
            }
            
            return {
                r: Math.min(255, Math.round(color.r * adjustFactor)),
                g: Math.min(255, Math.round(color.g * adjustFactor)),
                b: Math.min(255, Math.round(color.b * adjustFactor))
            };
        };
        
        const bright1 = brightenColor(color1, 2.5);
        const bright2 = brightenColor(color2, 2.2);
        const bright3 = brightenColor(color3, 2.0);
        
        elements.progressComet.style.setProperty('--comet-color-1', `rgba(${bright1.r}, ${bright1.g}, ${bright1.b}, 1)`);
        elements.progressComet.style.setProperty('--comet-color-2', `rgba(${bright2.r}, ${bright2.g}, ${bright2.b}, 0.95)`);
        elements.progressComet.style.setProperty('--comet-color-3', `rgba(${bright3.r}, ${bright3.g}, ${bright3.b}, 0.85)`);
    }
}

// Animate progress comet with client-side interpolation
function animateProgressComet() {
    if (!progressState.isPlaying || !progressState.lastUpdateTime) {
        return;
    }
    
    const now = Date.now();
    const elapsed = now - progressState.lastUpdateTime;
    
    // Update progress with elapsed time
    progressState.progressMs = Math.min(progressState.progressMs + elapsed, progressState.durationMs);
    progressState.lastUpdateTime = now;
    
    // Update visual position
    updateProgressComet();
    
    // Continue animation loop if still playing
    if (progressState.isPlaying && progressState.progressMs < progressState.durationMs) {
        progressState.animationFrameId = requestAnimationFrame(animateProgressComet);
    }
}

// Show progress comet
function showProgressComet() {
    if (!elements.progressComet) {
        createProgressComet();
    }
    
    if (elements.progressComet) {
        // Update position BEFORE making visible to avoid visual jump
        updateProgressComet();
        
        elements.progressComet.classList.remove('hidden');
        
        // Start animation loop if playing
        if (progressState.isPlaying) {
            if (progressState.animationFrameId) {
                cancelAnimationFrame(progressState.animationFrameId);
            }
            progressState.lastUpdateTime = Date.now();
            progressState.animationFrameId = requestAnimationFrame(animateProgressComet);
        }
    }
}

// Hide progress comet
function hideProgressComet() {
    if (elements.progressComet) {
        elements.progressComet.classList.add('hidden');
    }
    
    // Stop animation loop
    if (progressState.animationFrameId) {
        cancelAnimationFrame(progressState.animationFrameId);
        progressState.animationFrameId = null;
    }
}

// Pause progress comet (keep visible but stop moving)
function pauseProgressComet() {
    if (progressState.animationFrameId) {
        cancelAnimationFrame(progressState.animationFrameId);
        progressState.animationFrameId = null;
    }
}

// Resume progress comet animation
function resumeProgressComet() {
    if (progressState.isPlaying && elements.progressComet && !elements.progressComet.classList.contains('hidden')) {
        progressState.lastUpdateTime = Date.now();
        if (progressState.animationFrameId) {
            cancelAnimationFrame(progressState.animationFrameId);
        }
        progressState.animationFrameId = requestAnimationFrame(animateProgressComet);
    }
}

// ===== Equalizer Fill Progress Functions =====

// Enable equalizer fill mode (shows equalizer with border-white style)
function enableEqualizerFillMode() {
    const equalizer = elements.equalizer;
    if (!equalizer) return;
    
    // If current equalizer is bass-glow mode, switch to 'normal' mode
    if (equalizerState === 'bass-white-glow' || equalizerState === 'bass-color-glow') {
        equalizerState = 'normal';
        localStorage.setItem('equalizerState', equalizerState);
        
        // Apply equalizer state but update visibility separately
        // Don't use applyEqualizerState() here to avoid triggering the
        // logic that turns off equalizer-fill when equalizer is 'off'
        const equalizerIcon = elements.equalizerIcon;
        const albumArt = document.getElementById('album-art');
        
        if (equalizerIcon) {
            equalizer.classList.remove('equalizer-colors', 'equalizer-white', 'equalizer-spectrum', 'equalizer-blue-spectrum', 'equalizer-navy', 'equalizer-border-white');
            equalizerIcon.classList.remove('equalizer-colors', 'equalizer-white', 'equalizer-spectrum', 'equalizer-blue-spectrum', 'equalizer-navy', 'equalizer-border-white', 'equalizer-bass-white-glow', 'equalizer-bass-color-glow');
        }
        
        if (albumArt) {
            albumArt.classList.remove('bass-white-glow', 'bass-color-glow');
        }
        
        updateEqualizerVisibility();
    }
    
    // If no equalizer effect is active, enable 'normal' mode
    if (equalizerState === 'off') {
        equalizerState = 'normal';
        localStorage.setItem('equalizerState', equalizerState);
        equalizerAutoEnabled = true; // Mark that equalizer was auto-enabled
        
        // Update the icon to show normal mode is active
        const equalizerIcon = elements.equalizerIcon;
        if (equalizerIcon) {
            // Normal mode has no special class, icon just won't be dimmed
            equalizerIcon.classList.remove('equalizer-colors', 'equalizer-white', 'equalizer-spectrum', 'equalizer-blue-spectrum', 'equalizer-navy', 'equalizer-border-white', 'equalizer-bass-white-glow', 'equalizer-bass-color-glow');
        }
        
        updateEqualizerVisibility();
    }
    
    // Update fill based on current progress
    updateEqualizerFill();
}

// Update equalizer fill based on song progress - only glow the active bar
function updateEqualizerFill() {
    const equalizer = elements.equalizer;
    if (!equalizer || !progressState.durationMs) return;
    
    const { progressMs, durationMs } = progressState;
    const progress = Math.min(Math.max(progressMs / durationMs, 0), 1);
    
    // Get all equalizer bars
    const bars = equalizer.querySelectorAll('.equalizer-bar');
    const totalBars = bars.length;
    
    // Calculate which bar should be active (from left to right)
    const activeBarIndex = Math.floor(progress * totalBars);
    
    // Remove filled class from all bars and add only to the active one
    bars.forEach((bar, index) => {
        if (index === activeBarIndex) {
            bar.classList.add('filled');
        } else {
            bar.classList.remove('filled');
        }
    });
}

// Clear equalizer fill (remove filled classes and optionally hide equalizer)
function clearEqualizerFill() {
    const equalizer = elements.equalizer;
    if (!equalizer) return;
    
    // Remove filled class from all bars
    const bars = equalizer.querySelectorAll('.equalizer-bar');
    bars.forEach(bar => {
        bar.classList.remove('filled');
    });
    
    // If equalizer was auto-enabled by progress effect, turn it off
    if (equalizerAutoEnabled) {
        equalizerState = 'off';
        localStorage.setItem('equalizerState', equalizerState);
        equalizerAutoEnabled = false;
        applyEqualizerState();
    }
}

// Update display with track data
function updateDisplay(trackData) {
    if (!trackData) {
        showNoPlayback();
        hideProgressComet();
        return;
    }
    
    // Update playback state
    isPlaying = trackData.is_playing;
    
    // Update progress state for comet animation
    if (trackData.progress_ms !== undefined && trackData.duration_ms !== undefined) {
        const wasPlaying = progressState.isPlaying;
        progressState.progressMs = trackData.progress_ms;
        progressState.durationMs = trackData.duration_ms;
        progressState.isPlaying = trackData.is_playing;
        progressState.lastUpdateTime = Date.now();
        
        // Update comet position
        updateProgressComet();
        
        // Handle play/pause state changes
        if (trackData.is_playing && !wasPlaying) {
            // Resumed playing
            resumeProgressComet();
        } else if (!trackData.is_playing && wasPlaying) {
            // Paused
            pauseProgressComet();
        } else if (trackData.is_playing) {
            // Still playing, ensure animation is running
            resumeProgressComet();
        }
        
        // Update equalizer fill if that effect is active
        if (progressEffectState === 'equalizer-fill') {
            updateEqualizerFill();
        }
        
        // Show comet if we have valid duration and effect is enabled
        if (trackData.duration_ms > 0 && (progressEffectState === 'comet' || progressEffectState === 'album-comet' || progressEffectState === 'across-comet')) {
            showProgressComet();
        } else {
            hideProgressComet();
        }
    } else {
        // No progress data available
        hideProgressComet();
        // Clear equalizer fill
        clearEqualizerFill();
    }
    
    // Update equalizer visibility based on playback state
    updateEqualizerVisibility();
    
    // Update track information
    if (elements.trackName) {
        elements.trackName.textContent = trackData.track_name || 'Unknown Track';
    }
    if (elements.artistName) {
        elements.artistName.textContent = trackData.artist || 'Unknown Artist';
    }
    
    // Store album name even if element is hidden
    currentAlbumName = trackData.album || 'Unknown Album';
    if (elements.albumName) {
        elements.albumName.textContent = currentAlbumName;
    }
    
    // Update album art with fade effect
    if (trackData.album_art) {
        const currentSrc = elements.albumArt.src;
        if (currentSrc !== trackData.album_art) {
            elements.albumArt.style.opacity = '0';
            
            // Set up handlers before changing src to avoid multiple requests
            let loadTimeout;
            let hasLoaded = false;
            
            const handleLoad = () => {
                hasLoaded = true;
                clearTimeout(loadTimeout);
                elements.albumArt.style.transition = 'opacity 0.3s ease';
                elements.albumArt.style.opacity = '1';
                
                // Extract colors from the already-loaded image (no additional request)
                extractColors(elements.albumArt, (colors) => {
                    applyGradientBackground(colors);
                    applyGlowColors(elements.albumArt, colors);
                    // Update comet position and colors after colors are extracted
                    updateProgressComet();
                });
                
                // Remove handler after use
                elements.albumArt.removeEventListener('load', handleLoad);
                elements.albumArt.removeEventListener('error', handleError);
            };
            
            const handleError = () => {
                hasLoaded = true;
                clearTimeout(loadTimeout);
                console.warn('Failed to load album art, using default image');
                
                // Load default image
                elements.albumArt.src = DEF_ALBUM_ART_PATH;
                elements.albumArt.style.transition = 'opacity 0.3s ease';
                elements.albumArt.style.opacity = '1';
                
                // Extract colors from default image when it loads
                const defaultHandler = () => {
                    extractColors(elements.albumArt, (colors) => {
                        applyGradientBackground(colors);
                        applyGlowColors(elements.albumArt, colors);
                        // Update comet position and colors after colors are extracted
                        updateProgressComet();
                    });
                    elements.albumArt.removeEventListener('load', defaultHandler);
                };
                elements.albumArt.addEventListener('load', defaultHandler);
                
                // Remove handlers after use
                elements.albumArt.removeEventListener('load', handleLoad);
                elements.albumArt.removeEventListener('error', handleError);
            };
            
            // Set up timeout (5 seconds)
            loadTimeout = setTimeout(() => {
                if (!hasLoaded) {
                    console.warn('Album art loading timed out, using default image');
                    handleError();
                }
            }, 5000);
            
            // Attach handlers before setting src
            elements.albumArt.addEventListener('load', handleLoad);
            elements.albumArt.addEventListener('error', handleError);
            
            // Set src once - browser will use cache if available
            setTimeout(() => {
                elements.albumArt.src = trackData.album_art;
            }, 150);
        }
    }
    
    // Update playback status
    if (trackData.is_playing) {
        elements.playbackStatus.textContent = '▶';
        elements.playbackStatus.classList.add('playing');
    } else {
        elements.playbackStatus.textContent = '⏸';
        elements.playbackStatus.classList.remove('playing');
    }
    
    // Update device info
    if (trackData.device) {
        // Format device names for display
        let deviceDisplay;
        if (trackData.device.names && Array.isArray(trackData.device.names)) {
            // Sonos devices - format the list
            currentDeviceList = trackData.device.names; // Store full list
            const deviceCount = trackData.device.names.length;
            if (deviceCount === 1) {
                deviceDisplay = trackData.device.names[0];
            } else {
                // Show first device and count remaining
                const remaining = deviceCount - 1;
                deviceDisplay = `${trackData.device.names[0]} +${remaining} more`;
            }
        } else if (trackData.device.name) {
            // Spotify devices - use name directly
            currentDeviceList = [trackData.device.name]; // Store as array
            deviceDisplay = trackData.device.name;
        } else {
            currentDeviceList = [];
            deviceDisplay = 'Unknown Device';
        }
        
        elements.deviceName.textContent = `Playing on ${deviceDisplay}`;
    }
    
    // Show the display
    showNowPlaying();
}

// Show service label
let labelTimeout = null;
function showServiceLabel(text, targetElement = null, useNewlines = false) {
    const label = document.getElementById('service-label');
    label.textContent = text;
    
    // Set white-space style based on content type
    if (useNewlines) {
        label.style.whiteSpace = 'pre-line';
    } else {
        label.style.whiteSpace = 'nowrap';
    }
    
    // Get rotation state - use negative degrees to match container counter-clockwise rotation
    const rotationTransform = rotationState === 90 ? 'rotate(-90deg)' :
                             rotationState === 180 ? 'rotate(-180deg)' :
                             rotationState === 270 ? 'rotate(-270deg)' : '';
    
    // Position label above the target element
    if (targetElement) {
        const rect = targetElement.getBoundingClientRect();
        const appSettings = document.getElementById('app-settings');
        const isAppSettingsChild = appSettings.contains(targetElement);
        
        if (isAppSettingsChild) {
            // For app-settings icons, position above the specific icon
            if (rotationState === 0) {
                // Icons at bottom center - position above each icon
                label.style.bottom = `${window.innerHeight - rect.top + 15}px`;
                label.style.left = `${rect.left + rect.width / 2}px`;
                label.style.top = 'auto';
                label.style.right = 'auto';
                label.style.transform = 'translateX(-50%)';
            } else if (rotationState === 90) {
                // Icons at right center - position to the left of each icon
                label.style.top = `${rect.top + rect.height / 2}px`;
                label.style.right = `${window.innerWidth - rect.left + 5}px`;
                label.style.bottom = 'auto';
                label.style.left = 'auto';
                label.style.transform = 'translateY(-50%) rotate(-90deg)';
            } else if (rotationState === 180) {
                // Icons at top center - position below each icon (which is "up" in rotated space)
                label.style.top = `${rect.bottom + 15}px`;
                label.style.left = `${rect.left + rect.width / 2}px`;
                label.style.bottom = 'auto';
                label.style.right = 'auto';
                label.style.transform = 'translateX(-50%) rotate(-180deg)';
            } else if (rotationState === 270) {
                // Icons at left center - position to the right of each icon
                label.style.top = `${rect.top + rect.height / 2}px`;
                label.style.left = `${rect.right + 5}px`;
                label.style.bottom = 'auto';
                label.style.right = 'auto';
                label.style.transform = 'translateY(-50%) rotate(-270deg)';
            }
        } else {
            // For device-name and album art in center, calculate position with rotation
            if (rotationState === 0) {
                label.style.bottom = `${window.innerHeight - rect.top + 10}px`;
                label.style.left = `${rect.left + rect.width / 2}px`;
                label.style.right = 'auto';
                label.style.top = 'auto';
                label.style.transform = 'translateX(-50%)';
            } else if (rotationState === 90) {
                label.style.top = `${rect.top + rect.height / 2}px`;
                label.style.left = `${rect.left - 50}px`;
                label.style.right = 'auto';
                label.style.bottom = 'auto';
                label.style.transform = 'translateY(-50%) rotate(-90deg)';
            } else if (rotationState === 180) {
                label.style.top = `${rect.bottom + 50}px`;
                label.style.left = `${rect.left + rect.width / 2}px`;
                label.style.right = 'auto';
                label.style.bottom = 'auto';
                label.style.transform = 'translateX(-50%) rotate(-180deg)';
            } else if (rotationState === 270) {
                label.style.top = `${rect.top + rect.height / 2}px`;
                label.style.left = `${rect.right + 50}px`;
                label.style.right = 'auto';
                label.style.bottom = 'auto';
                label.style.transform = 'translateY(-50%) rotate(-270deg)';
            }
        }
    } else {
        // Default position based on rotation - at icon location, offset "up" in rotated space
        if (rotationState === 0) {
            label.style.bottom = '1rem';
            label.style.left = '50%';
            label.style.top = 'auto';
            label.style.right = 'auto';
            label.style.transform = 'translateX(-50%) translateY(-3rem)';
        } else if (rotationState === 90) {
            label.style.top = '50%';
            label.style.right = '4rem';
            label.style.bottom = 'auto';
            label.style.left = 'auto';
            label.style.transform = 'translateY(-50%) rotate(-90deg)';
        } else if (rotationState === 180) {
            label.style.top = '4rem';
            label.style.left = '50%';
            label.style.bottom = 'auto';
            label.style.right = 'auto';
            label.style.transform = 'translateX(-50%) rotate(-180deg)';
        } else if (rotationState === 270) {
            label.style.top = '50%';
            label.style.left = '4rem';
            label.style.bottom = 'auto';
            label.style.right = 'auto';
            label.style.transform = 'translateY(-50%) rotate(-270deg)';
        }
    }
    
    label.classList.add('show');
    
    // Clear existing timeout
    if (labelTimeout) {
        clearTimeout(labelTimeout);
    }
    
    // Hide after 5 seconds
    labelTimeout = setTimeout(() => {
        label.classList.remove('show');
    }, 5000);
}

// Hide service label
function hideServiceLabel() {
    const label = document.getElementById('service-label');
    label.classList.remove('show');
    
    // Clear timeout if exists
    if (labelTimeout) {
        clearTimeout(labelTimeout);
        labelTimeout = null;
    }
}

// Setup service icon click handlers
function setupServiceIconHandlers() {
    const sonosIcon = document.getElementById('service-sonos');
    const spotifyIcon = document.getElementById('service-spotify');
    const playbackStatus = document.getElementById('playback-status');
    const appSettings = document.getElementById('app-settings');
    const label = document.getElementById('service-label');
    let autoCollapseTimer = null;
    
    // Function to stop auto-collapse timer
    function stopAutoCollapseTimer() {
        if (autoCollapseTimer) {
            clearTimeout(autoCollapseTimer);
            autoCollapseTimer = null;
        }
    }
    
    // Function to collapse dock
    function collapseSettings() {
        appSettings.classList.remove('expanded');
        stopAutoCollapseTimer();
    }
    
    // Function to expand dock
    function expandSettings() {
        appSettings.classList.add('expanded');
        startAutoCollapseTimer();
    }
    
    // Function to start auto-collapse timer
    function startAutoCollapseTimer() {
        // Clear any existing timer
        if (autoCollapseTimer) {
            clearTimeout(autoCollapseTimer);
        }
        
        // Set new timer for 10 seconds
        autoCollapseTimer = setTimeout(() => {
            if (appSettings.classList.contains('expanded')) {
                collapseSettings();
            }
        }, 10000);
    }
    
    // Flag to prevent double-firing on touch devices
    let touchHandled = false;
    
    // Canvas-wide touch handler (fires first on touch devices)
    document.body.addEventListener('touchend', (e) => {
        touchHandled = true;
        
        // If touching inside the dock, reset the timer but don't toggle
        if (e.target.closest('#app-settings')) {
            if (appSettings.classList.contains('expanded')) {
                startAutoCollapseTimer();
            }
            // Reset flag after delay
            setTimeout(() => { touchHandled = false; }, 500);
            return;
        }
        
        // If touching service label, don't toggle
        if (e.target === label || e.target.closest('.service-label')) {
            // Reset flag after delay
            setTimeout(() => { touchHandled = false; }, 500);
            return;
        }
        
        // Toggle dock visibility
        if (appSettings.classList.contains('expanded')) {
            collapseSettings();
        } else {
            expandSettings();
        }
        
        // Reset flag after a short delay
        setTimeout(() => { touchHandled = false; }, 500);
    });
    
    // Canvas-wide click handler (for mouse or as fallback)
    document.body.addEventListener('click', (e) => {
        // Skip if this was a touch event
        if (touchHandled) {
            return;
        }
        
        // If clicking inside the dock, reset the timer but don't toggle
        if (e.target.closest('#app-settings')) {
            if (appSettings.classList.contains('expanded')) {
                startAutoCollapseTimer();
            }
            return;
        }
        
        // If clicking on service label, don't toggle
        if (e.target === label || e.target.closest('.service-label')) {
            return;
        }
        
        // Toggle dock visibility
        if (appSettings.classList.contains('expanded')) {
            collapseSettings();
        } else {
            expandSettings();
        }
    });
    
    // Prevent label clicks from closing itself
    label.addEventListener('click', (e) => {
        e.stopPropagation();
    });
    
    // Close label when clicking anywhere on the page
    document.addEventListener('click', (e) => {
        // Check if label is visible and click is not on service status icons or device name
        if (label.classList.contains('show') && 
            !e.target.closest('#app-settings') &&
            !e.target.closest('.device-info') &&
            e.target !== label) {
            hideServiceLabel();
        }
    });
    
    // Show all devices when clicking or hovering device name
    elements.deviceName.addEventListener('click', (e) => {
        e.stopPropagation();
        if (currentDeviceList.length > 0) {
            const allDevices = currentDeviceList.join('\n');
            showServiceLabel(`Playing on:\n${allDevices}`, elements.deviceName, true);
        }
    });
    
    elements.deviceName.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        if (currentDeviceList.length > 0) {
            const allDevices = currentDeviceList.join('\n');
            showServiceLabel(`Playing on:\n${allDevices}`, elements.deviceName, true);
        }
    });
    
    elements.deviceName.addEventListener('mouseenter', () => {
        if (currentDeviceList.length > 0) {
            const allDevices = currentDeviceList.join('\n');
            showServiceLabel(`Playing on:\n${allDevices}`, elements.deviceName, true);
        }
    });
    
    elements.deviceName.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    // Service icon handlers
    sonosIcon.addEventListener('click', (e) => {
        e.stopPropagation();
        showServiceLabel('Sonos Enabled', sonosIcon);
        // Reset timer when icon is clicked
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    sonosIcon.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        showServiceLabel('Sonos Enabled', sonosIcon);
        // Reset timer when icon is touched
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    sonosIcon.addEventListener('mouseenter', () => {
        showServiceLabel('Sonos Enabled', sonosIcon);
    });
    
    sonosIcon.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    spotifyIcon.addEventListener('click', (e) => {
        e.stopPropagation();
        showServiceLabel('Spotify Enabled', spotifyIcon);
        // Reset timer when icon is clicked
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    spotifyIcon.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        showServiceLabel('Spotify Enabled', spotifyIcon);
        // Reset timer when icon is touched
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    spotifyIcon.addEventListener('mouseenter', () => {
        showServiceLabel('Spotify Enabled', spotifyIcon);
    });
    
    spotifyIcon.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    playbackStatus.addEventListener('click', (e) => {
        e.stopPropagation();
        const status = playbackStatus.classList.contains('paused') ? 'Paused' : 'Playing';
        showServiceLabel(status, playbackStatus);
        // Reset timer when icon is clicked
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    playbackStatus.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const status = playbackStatus.classList.contains('paused') ? 'Paused' : 'Playing';
        showServiceLabel(status, playbackStatus);
        // Reset timer when icon is touched
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    playbackStatus.addEventListener('mouseenter', () => {
        const status = playbackStatus.classList.contains('paused') ? 'Paused' : 'Playing';
        showServiceLabel(status, playbackStatus);
    });
    
    playbackStatus.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    // Show album name when hovering or clicking album art (now-playing state only)
    const albumArtContainer = document.querySelector('#now-playing .album-art-container');
    
    if (albumArtContainer) {
        albumArtContainer.addEventListener('click', (e) => {
            e.stopPropagation();
            if (currentAlbumName) {
                showServiceLabel(currentAlbumName, albumArtContainer);
            }
        });
        
        albumArtContainer.addEventListener('touchend', (e) => {
            e.preventDefault();
            e.stopPropagation();
            if (currentAlbumName) {
                showServiceLabel(currentAlbumName, albumArtContainer);
            }
        });
        
        albumArtContainer.addEventListener('mouseenter', () => {
            if (currentAlbumName) {
                showServiceLabel(currentAlbumName, albumArtContainer);
            }
        });
        
        albumArtContainer.addEventListener('mouseleave', () => {
            hideServiceLabel();
        });
    }
    
    // Rotation icon click handler
    const rotationIcon = document.getElementById('rotation-icon');
    
    rotationIcon.addEventListener('click', (e) => {
        e.stopPropagation();
        rotateDisplay();
        const degrees = rotationState === 0 ? '0°' : `${rotationState}°`;
        showServiceLabel(`Rotation: ${degrees}`, rotationIcon);
        // Reset timer when icon is clicked
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    rotationIcon.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        rotateDisplay();
        const degrees = rotationState === 0 ? '0°' : `${rotationState}°`;
        showServiceLabel(`Rotation: ${degrees}`, rotationIcon);
        // Reset timer when icon is touched
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    rotationIcon.addEventListener('mouseenter', () => {
        const degrees = rotationState === 0 ? '0°' : `${rotationState}°`;
        showServiceLabel(`Rotation: ${degrees}`, rotationIcon);
    });
    
    rotationIcon.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    // Glow icon click handler
    const glowIcon = document.getElementById('glow-icon');
    
    glowIcon.addEventListener('click', (e) => {
        e.stopPropagation();
        cycleGlowState();
        // Reset timer when icon is clicked
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    glowIcon.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        cycleGlowState();
        // Reset timer when icon is touched
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    glowIcon.addEventListener('mouseenter', () => {
        showServiceLabel(GLOW_EFFECT_NAMES[glowState], glowIcon);
    });
    
    glowIcon.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    // Equalizer icon click handler
    const equalizerIcon = document.getElementById('equalizer-icon');
    
    equalizerIcon.addEventListener('click', (e) => {
        e.stopPropagation();
        cycleEqualizerState();
        // Reset timer when icon is clicked
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    equalizerIcon.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        cycleEqualizerState();
        // Reset timer when icon is touched
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    equalizerIcon.addEventListener('mouseenter', () => {
        showServiceLabel(EQUALIZER_EFFECT_NAMES[equalizerState], equalizerIcon);
    });
    
    equalizerIcon.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    // Progress effect icon click handler
    const progressEffectIcon = document.getElementById('progress-effect-icon');
    
    progressEffectIcon.addEventListener('click', (e) => {
        e.stopPropagation();
        cycleProgressEffectState();
        // Reset timer when icon is clicked
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    progressEffectIcon.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        cycleProgressEffectState();
        // Reset timer when icon is touched
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    progressEffectIcon.addEventListener('mouseenter', () => {
        showServiceLabel(PROGRESS_EFFECT_NAMES[progressEffectState], progressEffectIcon);
    });
    
    progressEffectIcon.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    // Reset icon click handler - restore all effects to default
    const resetIcon = document.getElementById('reset-icon');
    
    resetIcon.addEventListener('click', (e) => {
        e.stopPropagation();
        resetAllEffects();
        showServiceLabel('Reset All Effects', resetIcon);
        // Reset timer when icon is clicked
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    resetIcon.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        resetAllEffects();
        showServiceLabel('Reset All Effects', resetIcon);
        // Reset timer when icon is touched
        if (appSettings.classList.contains('expanded')) {
            startAutoCollapseTimer();
        }
    });
    
    resetIcon.addEventListener('mouseenter', () => {
        showServiceLabel('Reset All Effects', resetIcon);
    });
    
    resetIcon.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    // Fullscreen icon click handler
    const fullscreenIcon = document.getElementById('fullscreen-icon');
    
    fullscreenIcon.addEventListener('click', (e) => {
        e.stopPropagation();
        toggleFullscreen();
    });
    
    fullscreenIcon.addEventListener('touchend', (e) => {
        e.preventDefault();
        e.stopPropagation();
        toggleFullscreen();
    });
    
    fullscreenIcon.addEventListener('mouseenter', () => {
        const isFullscreen = document.fullscreenElement || document.webkitFullscreenElement;
        showServiceLabel(isFullscreen ? 'Exit Fullscreen' : 'Enter Fullscreen', fullscreenIcon);
    });
    
    fullscreenIcon.addEventListener('mouseleave', () => {
        hideServiceLabel();
    });
    
    // Update fullscreen icon state on initial load
    updateFullscreenIconState();
}

// Rotate display counter-clockwise by 90 degrees
function rotateDisplay() {
    // Increment rotation by 90 degrees (counter-clockwise)
    rotationState = (rotationState + 90) % 360;
    
    // Remove all rotation classes
    document.body.classList.remove('rotate-90', 'rotate-180', 'rotate-270');
    
    // Add appropriate rotation class
    if (rotationState === 90) {
        document.body.classList.add('rotate-90');
    } else if (rotationState === 180) {
        document.body.classList.add('rotate-180');
    } else if (rotationState === 270) {
        document.body.classList.add('rotate-270');
    }
    
    // Save rotation state to localStorage
    localStorage.setItem('displayRotation', rotationState);
    
    console.log('Display rotated to:', rotationState, 'degrees');
}

// Restore rotation state from localStorage
function restoreRotation() {
    const savedRotation = localStorage.getItem('displayRotation');
    if (savedRotation) {
        rotationState = parseInt(savedRotation);
        
        // Apply saved rotation
        if (rotationState === 90) {
            document.body.classList.add('rotate-90');
        } else if (rotationState === 180) {
            document.body.classList.add('rotate-180');
        } else if (rotationState === 270) {
            document.body.classList.add('rotate-270');
        }
    }
}

// Cycle through glow states: off -> all-colors -> white -> off
function cycleGlowState() {
    const currentIndex = GLOW_STATES.indexOf(glowState);
    const nextIndex = (currentIndex + 1) % GLOW_STATES.length;
    glowState = GLOW_STATES[nextIndex];
    
    // If enabling glow (not 'off'), disable bass glow equalizer modes
    if (glowState !== 'off' && (equalizerState === 'bass-white-glow' || equalizerState === 'bass-color-glow')) {
        // Reset equalizer to 'off'
        equalizerState = 'off';
        localStorage.setItem('equalizerState', equalizerState);
        applyEqualizerState();
        updateEqualizerVisibility();
    }
    
    // Save to localStorage
    localStorage.setItem('glowState', glowState);
    
    // Apply the new state
    applyGlowState();
    
    // Show label with effect name
    const glowIcon = document.getElementById('glow-icon');
    showServiceLabel(GLOW_EFFECT_NAMES[glowState], glowIcon);
    
    console.log('Glow state changed to:', glowState);
}

// Apply current glow state to all elements
function applyGlowState() {
    const albumArt = document.getElementById('album-art');
    const screensaverImage = document.getElementById('screensaver-image');
    const glowIcon = document.getElementById('glow-icon');
    
    // Remove all glow classes (including bass glow modes)
    albumArt.classList.remove('glow-all-colors', 'glow-white', 'glow-white-fast', 'glow-all-colors-fast', 'glow-album-colors', 'glow-album-colors-fast', 'bass-white-glow', 'bass-color-glow');
    screensaverImage.classList.remove('glow-all-colors', 'glow-white', 'glow-white-fast', 'glow-all-colors-fast', 'glow-album-colors', 'glow-album-colors-fast');
    glowIcon.classList.remove('glow-all-colors', 'glow-white', 'glow-white-fast', 'glow-all-colors-fast', 'glow-album-colors', 'glow-album-colors-fast');
    
    // Apply current state
    if (glowState === 'all-colors') {
        albumArt.classList.add('glow-all-colors');
        screensaverImage.classList.add('glow-all-colors');
        glowIcon.classList.add('glow-all-colors');
    } else if (glowState === 'white') {
        albumArt.classList.add('glow-white');
        screensaverImage.classList.add('glow-white');
        glowIcon.classList.add('glow-white');
    } else if (glowState === 'white-fast') {
        albumArt.classList.add('glow-white-fast');
        screensaverImage.classList.add('glow-white-fast');
        glowIcon.classList.add('glow-white-fast');
    } else if (glowState === 'all-colors-fast') {
        albumArt.classList.add('glow-all-colors-fast');
        screensaverImage.classList.add('glow-all-colors-fast');
        glowIcon.classList.add('glow-all-colors-fast');
    } else if (glowState === 'album-colors') {
        albumArt.classList.add('glow-album-colors');
        screensaverImage.classList.add('glow-album-colors');
        glowIcon.classList.add('glow-album-colors');
    } else if (glowState === 'album-colors-fast') {
        albumArt.classList.add('glow-album-colors-fast');
        screensaverImage.classList.add('glow-album-colors-fast');
        glowIcon.classList.add('glow-album-colors-fast');
    }
    // If 'off', no classes are added (glow is removed)
}

// Restore glow state from localStorage
function restoreGlowState() {
    const savedGlow = localStorage.getItem('glowState');
    if (savedGlow && GLOW_STATES.includes(savedGlow)) {
        glowState = savedGlow;
    } else {
        glowState = 'off'; // Default to off
    }
    
    // Apply the restored state
    applyGlowState();
}

// Cycle through equalizer states: off -> colors -> white -> off
function cycleEqualizerState() {
    const currentIndex = EQUALIZER_STATES.indexOf(equalizerState);
    const nextIndex = (currentIndex + 1) % EQUALIZER_STATES.length;
    equalizerState = EQUALIZER_STATES[nextIndex];
    
    // Clear auto-enabled flag when user manually changes equalizer
    equalizerAutoEnabled = false;
    
    // If enabling bass-white-glow or bass-color-glow, disable normal glow effect
    if ((equalizerState === 'bass-white-glow' || equalizerState === 'bass-color-glow') && glowState !== 'off') {
        glowState = 'off';
        localStorage.setItem('glowState', glowState);
        applyGlowState();
    }
    
    // Save to localStorage
    localStorage.setItem('equalizerState', equalizerState);
    
    // Apply the new state
    applyEqualizerState();
    
    // Show label with effect name
    const equalizerIcon = document.getElementById('equalizer-icon');
    showServiceLabel(EQUALIZER_EFFECT_NAMES[equalizerState], equalizerIcon);
}

// Apply current equalizer state
function applyEqualizerState() {
    const equalizer = elements.equalizer;
    const equalizerIcon = elements.equalizerIcon;
    
    if (!equalizer || !equalizerIcon) return;
    
    // Remove all equalizer classes
    equalizer.classList.remove('equalizer-colors', 'equalizer-white', 'equalizer-spectrum', 'equalizer-blue-spectrum', 'equalizer-navy', 'equalizer-border-white');
    equalizerIcon.classList.remove('equalizer-colors', 'equalizer-white', 'equalizer-spectrum', 'equalizer-blue-spectrum', 'equalizer-navy', 'equalizer-border-white', 'equalizer-bass-white-glow', 'equalizer-bass-color-glow');
    
    // Remove bass glow modes from album art
    const albumArt = document.getElementById('album-art');
    if (albumArt) {
        albumArt.classList.remove('bass-white-glow', 'bass-color-glow');
    }
    
    // Apply current state
    if (equalizerState === 'normal') {
        // Normal mode: no classes added, just show the equalizer with default styling
        // Icon gets no special class either
    } else if (equalizerState === 'colors') {
        equalizer.classList.add('equalizer-colors');
        equalizerIcon.classList.add('equalizer-colors');
    } else if (equalizerState === 'white') {
        equalizer.classList.add('equalizer-white');
        equalizerIcon.classList.add('equalizer-white');
    } else if (equalizerState === 'spectrum') {
        equalizer.classList.add('equalizer-spectrum');
        equalizerIcon.classList.add('equalizer-spectrum');
    } else if (equalizerState === 'blue-spectrum') {
        equalizer.classList.add('equalizer-blue-spectrum');
        equalizerIcon.classList.add('equalizer-blue-spectrum');
    } else if (equalizerState === 'navy') {
        equalizer.classList.add('equalizer-navy');
        equalizerIcon.classList.add('equalizer-navy');
    } else if (equalizerState === 'border-white') {
        equalizer.classList.add('equalizer-border-white');
        equalizerIcon.classList.add('equalizer-border-white');
    } else if (equalizerState === 'bass-white-glow') {
        equalizerIcon.classList.add('equalizer-bass-white-glow');
        if (albumArt) {
            albumArt.classList.add('bass-white-glow');
        }
    } else if (equalizerState === 'bass-color-glow') {
        equalizerIcon.classList.add('equalizer-bass-color-glow');
        if (albumArt) {
            albumArt.classList.add('bass-color-glow');
        }
    }
    // If 'off', no classes are added (icon is dimmed)
    
    // If equalizer is turned off, also turn off equalizer-fill progress effect
    if (equalizerState === 'off' && progressEffectState === 'equalizer-fill') {
        // Cycle back to 'off' for progress effect
        progressEffectState = 'off';
        localStorage.setItem('progressEffectState', progressEffectState);
        applyProgressEffectState();
    }
    
    // Update visibility based on both state and playback
    updateEqualizerVisibility();
}

// Update equalizer visibility based on state and playback
function updateEqualizerVisibility() {
    const equalizer = elements.equalizer;
    const albumArt = document.getElementById('album-art');
    
    if (!equalizer) {
        return;
    }
    
    // Show equalizer if:
    // 1. Equalizer state is not 'off' (and not a bass glow mode), OR
    // 2. Progress effect is 'equalizer-fill'
    if ((equalizerState !== 'off' && equalizerState !== 'bass-white-glow' && equalizerState !== 'bass-color-glow') 
        || progressEffectState === 'equalizer-fill') {
        equalizer.classList.remove('hidden');
    } else {
        equalizer.classList.add('hidden');
    }
    
    // Handle bass glow effects - show regardless of playback state, CSS will pause animation
    if (albumArt) {
        if (equalizerState === 'bass-white-glow') {
            albumArt.classList.add('bass-white-glow');
        } else {
            albumArt.classList.remove('bass-white-glow');
        }
        
        if (equalizerState === 'bass-color-glow') {
            albumArt.classList.add('bass-color-glow');
        } else {
            albumArt.classList.remove('bass-color-glow');
        }
    }
}

// Restore equalizer state from localStorage
function restoreEqualizerState() {
    const savedEqualizer = localStorage.getItem('equalizerState');
    if (savedEqualizer && EQUALIZER_STATES.includes(savedEqualizer)) {
        equalizerState = savedEqualizer;
    } else {
        equalizerState = 'off'; // Default to off
    }
    
    // Apply the restored state
    applyEqualizerState();
}

// Cycle through progress effect states
function cycleProgressEffectState() {
    const currentIndex = PROGRESS_EFFECT_STATES.indexOf(progressEffectState);
    const nextIndex = (currentIndex + 1) % PROGRESS_EFFECT_STATES.length;
    progressEffectState = PROGRESS_EFFECT_STATES[nextIndex];
    
    // Save to localStorage
    localStorage.setItem('progressEffectState', progressEffectState);
    
    // Apply the new state
    applyProgressEffectState();
    
    // Show label with effect name
    const progressEffectIcon = document.getElementById('progress-effect-icon');
    showServiceLabel(PROGRESS_EFFECT_NAMES[progressEffectState], progressEffectIcon);
    
    console.log('Progress effect state changed to:', progressEffectState);
}

// Apply current progress effect state
function applyProgressEffectState() {
    const progressEffectIcon = document.getElementById('progress-effect-icon');
    
    if (!progressEffectIcon) return;
    
    // Remove all effect classes
    progressEffectIcon.classList.remove('effect-comet', 'effect-album-comet', 'effect-across-comet', 'effect-equalizer-fill');
    
    // Notify server about progress needs
    if (socket && socket.connected) {
        if (progressEffectState !== 'off') {
            // Client needs progress updates
            socket.emit('enable_progress');
            console.log('📊 Requested progress updates from server');
        } else {
            // Client doesn't need progress updates
            socket.emit('disable_progress');
            console.log('⏸️  Disabled progress updates from server');
        }
    }
    
    // Apply current state
    if (progressEffectState === 'comet') {
        progressEffectIcon.classList.add('effect-comet');
        // Show comet if there's valid progress data
        if (progressState.durationMs > 0 && isPlaying) {
            showProgressComet();
        }
        // Turn off equalizer fill
        clearEqualizerFill();
    } else if (progressEffectState === 'album-comet') {
        progressEffectIcon.classList.add('effect-album-comet');
        // Show comet if there's valid progress data
        if (progressState.durationMs > 0 && isPlaying) {
            showProgressComet();
        }
        // Turn off equalizer fill
        clearEqualizerFill();
    } else if (progressEffectState === 'across-comet') {
        progressEffectIcon.classList.add('effect-across-comet');
        // Show comet if there's valid progress data
        if (progressState.durationMs > 0 && isPlaying) {
            showProgressComet();
        }
        // Turn off equalizer fill
        clearEqualizerFill();
    } else if (progressEffectState === 'equalizer-fill') {
        progressEffectIcon.classList.add('effect-equalizer-fill');
        // Hide comet
        hideProgressComet();
        // Enable border-white equalizer and show it
        enableEqualizerFillMode();
    } else {
        // Hide comet when effect is off
        hideProgressComet();
        // Turn off equalizer fill
        clearEqualizerFill();
    }
}

// Restore progress effect state from localStorage
function restoreProgressEffectState() {
    const savedEffect = localStorage.getItem('progressEffectState');
    if (savedEffect && PROGRESS_EFFECT_STATES.includes(savedEffect)) {
        progressEffectState = savedEffect;
    } else {
        progressEffectState = 'off'; // Default to off
    }
    
    // Apply the restored state
    applyProgressEffectState();
}

// Reset all effects to default state
function resetAllEffects() {
    // Reset glow state
    glowState = 'off';
    localStorage.setItem('glowState', glowState);
    applyGlowState();
    
    // Reset equalizer state
    equalizerState = 'off';
    localStorage.setItem('equalizerState', equalizerState);
    applyEqualizerState();
    updateEqualizerVisibility();
    
    // Reset progress effect state
    progressEffectState = 'off';
    localStorage.setItem('progressEffectState', progressEffectState);
    applyProgressEffectState();
    
    console.log('All effects reset to default state');
}

// Update fullscreen icon state based on fullscreen status
function updateFullscreenIconState() {
    const fullscreenIcon = document.getElementById('fullscreen-icon');
    if (!fullscreenIcon) return;
    
    const isFullscreen = document.fullscreenElement || document.webkitFullscreenElement;
    
    if (isFullscreen) {
        fullscreenIcon.classList.add('fullscreen-active');
    } else {
        fullscreenIcon.classList.remove('fullscreen-active');
    }
}

// Toggle fullscreen
function toggleFullscreen() {
    const isFullscreen = document.fullscreenElement || document.webkitFullscreenElement;
    
    if (isFullscreen) {
        exitFullscreen();
    } else {
        requestFullscreen();
    }
}

// Show cursor in fullscreen mode
function showCursor() {
    document.body.classList.remove('fullscreen-hide-cursor');
    document.body.classList.add('fullscreen-show-cursor');
    
    // Clear existing timeout
    if (cursorHideTimeout) {
        clearTimeout(cursorHideTimeout);
    }
    
    // Only auto-hide if in fullscreen mode
    const isFullscreen = document.fullscreenElement || document.webkitFullscreenElement;
    if (isFullscreen) {
        // Set timeout to hide cursor after inactivity
        cursorHideTimeout = setTimeout(() => {
            document.body.classList.remove('fullscreen-show-cursor');
            document.body.classList.add('fullscreen-hide-cursor');
        }, CURSOR_HIDE_DELAY);
    }
}

// Hide cursor immediately in fullscreen mode
function hideCursor() {
    const isFullscreen = document.fullscreenElement || document.webkitFullscreenElement;
    if (isFullscreen) {
        document.body.classList.remove('fullscreen-show-cursor');
        document.body.classList.add('fullscreen-hide-cursor');
    }
}

// Request fullscreen
function requestFullscreen() {
    const elem = document.documentElement;
    
    if (elem.requestFullscreen) {
        elem.requestFullscreen();
    } else if (elem.webkitRequestFullscreen) {
        elem.webkitRequestFullscreen();
    } else if (elem.mozRequestFullScreen) {
        elem.mozRequestFullScreen();
    } else if (elem.msRequestFullscreen) {
        elem.msRequestFullscreen();
    }
    
    document.body.classList.add('fullscreen');
    
    // Hide cursor initially when entering fullscreen
    setTimeout(() => {
        hideCursor();
    }, 100);
}

// Exit fullscreen
function exitFullscreen() {
    if (document.exitFullscreen) {
        document.exitFullscreen();
    } else if (document.webkitExitFullscreen) {
        document.webkitExitFullscreen();
    } else if (document.mozCancelFullScreen) {
        document.mozCancelFullScreen();
    } else if (document.msExitFullscreen) {
        document.msExitFullscreen();
    }
    
    document.body.classList.remove('fullscreen');
    
    // Show cursor when exiting fullscreen
    document.body.classList.remove('fullscreen-hide-cursor');
    document.body.classList.remove('fullscreen-show-cursor');
    if (cursorHideTimeout) {
        clearTimeout(cursorHideTimeout);
        cursorHideTimeout = null;
    }
}

// Toggle fullscreen on triple click
let clickCount = 0;
let clickTimer = null;

document.addEventListener('click', (e) => {
    // Ignore clicks on interactive elements
    if (e.target.closest('#app-settings') || 
        e.target.closest('.device-info') || 
        e.target.closest('.album-art-container')) {
        return;
    }
    
    clickCount++;
    
    if (clickCount === 1) {
        clickTimer = setTimeout(() => {
            clickCount = 0;
        }, 600); // Reset after 600ms
    } else if (clickCount === 3) {
        clearTimeout(clickTimer);
        clickCount = 0;
        
        if (!document.fullscreenElement && 
            !document.webkitFullscreenElement && 
            !document.mozFullScreenElement &&
            !document.msFullscreenElement) {
            requestFullscreen();
        } else {
            exitFullscreen();
        }
    }
});

// Handle fullscreen change
document.addEventListener('fullscreenchange', () => {
    if (!document.fullscreenElement) {
        document.body.classList.remove('fullscreen');
    }
    updateFullscreenIconState();
});

document.addEventListener('webkitfullscreenchange', () => {
    updateFullscreenIconState();
});

// Mouse event listeners for cursor auto-hide in fullscreen
document.addEventListener('mousemove', showCursor);
document.addEventListener('mousedown', showCursor);
document.addEventListener('mouseup', showCursor);
document.addEventListener('click', showCursor);

// Keyboard shortcuts
document.addEventListener('keydown', (e) => {
    // F key for fullscreen
    if (e.key === 'f' || e.key === 'F') {
        if (!document.fullscreenElement) {
            requestFullscreen();
        } else {
            exitFullscreen();
        }
    }
    
    // Escape to exit fullscreen
    if (e.key === 'Escape' && document.fullscreenElement) {
        exitFullscreen();
    }
});

// Auto-request fullscreen after first user interaction
let hasInteracted = false;
function handleFirstInteraction() {
    if (!hasInteracted) {
        hasInteracted = true;
        // Optional: Auto-enter fullscreen on first click
        // requestFullscreen();
    }
}

document.addEventListener('click', handleFirstInteraction, { once: true });

// Initialize app
function init() {
    console.log('Initializing Spotify Now Playing Display');
    
    // Set crossOrigin on images to allow canvas pixel access
    elements.albumArt.crossOrigin = 'anonymous';
    
    // Create progress comet element
    createProgressComet();
    
    showLoading();
    restoreRotation();
    restoreGlowState();
    restoreEqualizerState();
    restoreProgressEffectState();
    setupServiceIconHandlers();
    connectWebSocket();
    
    // Update URL configuration hint in console
    console.log('WebSocket URL:', WEBSOCKET_URL);
}

// Start the app when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}

// Visibility change handling (pause/resume updates when tab is hidden)
document.addEventListener('visibilitychange', () => {
    if (!document.hidden && socket && socket.connected) {
        console.log('Tab visible, requesting current track');
        socket.emit('request_current_track');
    }
});

// Handle window resize - update comet position to match new screen dimensions
let resizeTimeout;
window.addEventListener('resize', () => {
    // Debounce resize events
    clearTimeout(resizeTimeout);
    resizeTimeout = setTimeout(() => {
        if (progressState.durationMs > 0 && elements.progressComet && !elements.progressComet.classList.contains('hidden')) {
            // Recalculate comet position with new screen dimensions
            updateProgressComet();
        }
    }, 100); // Wait 100ms after resize stops to avoid excessive calculations
});
