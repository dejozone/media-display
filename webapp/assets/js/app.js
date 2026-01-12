// ===== CONSTANTS =====
const CONFIG = {
    PROD_ENV: 'media-display.projecttechcycle.org',
    LOCAL: {
        WS_URL: null,
        WS_PORT: 5001,
        WS_SSL_CERT_VERIFY: false,
        WS_SUB_PATH: '/notis/media-display/socket.io',
    },
    PROD: {
        WS_URL: null,
        WS_PORT: null,
        WS_SSL_CERT_VERIFY: true,
        WS_SUB_PATH: '/notis/media-display/socket.io',
    },
    WS_MAX_RECON_ATTEMPTS: 10,
    WS_RECONN_WAIT_MINUTES: 5,
    CURSOR_HIDE_DELAY: 3000,
    SCREENSAVER_REFRESH_INTERVAL: 300000,
    SCREENSAVER_PAUSED_DELAY_MINUTES: 5,
    DEF_ALBUM_ART_PATH: 'assets/images/cat.jpg',
    LABEL_TIMEOUT: 5000,
    AUTO_COLLAPSE_TIMEOUT: 10000,
    TRIPLE_CLICK_TIMEOUT: 600
};

const EFFECT_STATES = {
    GLOW: ['off', 'all-colors', 'white', 'white-fast', 'all-colors-fast', 'album-colors', 'album-colors-fast'],
    EQUALIZER: ['off', 'normal', 'border-white', 'white', 'navy', 'blue-spectrum', 'colors', 'spectrum', 'bass-white-glow', 'bass-color-glow'],
    PROGRESS: ['off', 'comet', 'album-comet', 'across-comet', 'sunrise', 'blended-sunrise', 'equalizer-fill']
};

const EFFECT_NAMES = {
    GLOW: {
        'off': 'Off',
        'all-colors': 'Colors',
        'white': 'White',
        'white-fast': 'Fast White',
        'all-colors-fast': 'Fast Colors',
        'album-colors': 'Album Colors',
        'album-colors-fast': 'Fast Album Colors'
    },
    EQUALIZER: {
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
    },
    PROGRESS: {
        'off': 'Off',
        'comet': 'Edge Comet',
        'album-comet': 'Album Comet',
        'across-comet': 'Across Comet',
        'sunrise': 'Sunrise & Sunset',
        'blended-sunrise': 'Blended Sunrise & Sunset',
        'equalizer-fill': 'Equalizer Fill'
    }
};

// ===== CONFIGURATION SETUP =====
const hostname = window.location.hostname;
const selectedEnvConfig = hostname === CONFIG.PROD_ENV ? CONFIG.PROD : CONFIG.LOCAL;

// Determine WebSocket URL
let WS_URL;
if (selectedEnvConfig.WS_URL) {
    WS_URL = selectedEnvConfig.WS_URL;
} else {
    // If not set, determine from browser root URL
    const hostname = window.location.hostname || 'localhost';
    const protocol = window.location.protocol === 'https:' ? 'https' : 'http';
    WS_URL = `${protocol}://${hostname}`;
}

// Handle WS_PORT - append port if set in config or available from browser
if (selectedEnvConfig.WS_PORT) {
    WS_URL = `${WS_URL}:${selectedEnvConfig.WS_PORT}`;
} else if (window.location.port) {
    WS_URL = `${WS_URL}:${window.location.port}`;
}

// Note: WS_SUB_PATH is now handled in Socket.IO path option, not in URL
// This allows proper Socket.IO routing through nginx subpaths

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
    progressComet: null, // Will be created dynamically
    sunriseContainer: null // Will be created dynamically
};

// Screensaver images - loaded dynamically from folder
let screensaverImages = [];
let screensaverImagesLoaded = false;
let currentScreensaverIndex = 0;
let screensaverInterval = null;
let screensaverRefreshInterval = null;

// Function to load screensaver images from directory
async function loadScreensaverImages(forceRefresh = false) {
    if (screensaverImagesLoaded && !forceRefresh) {
        return screensaverImages;
    }
    
    try {
        // console.log('Loading screensaver images...');
        const response = await fetch('assets/images/screensavers/', {
            cache: forceRefresh ? 'reload' : 'default' // Force reload or use HTTP cache
        });
        
        if (!response.ok) {
            throw new Error(`Failed to fetch directory listing: ${response.status}`);
        }
        
        // Parse HTML directory listing (nginx-style format)
        const html = await response.text();
        
        // Extract image filenames from anchor tags
        // Match: <a href="filename">filename</a>
        const regex = /<a href="([^"]+)">[^<]+<\/a>/g;
        const filenames = [];
        let match;
        
        while ((match = regex.exec(html)) !== null) {
            const filename = match[1];
            // Skip parent directory link
            if (filename === '../') continue;
            
            // Only include image files
            if (filename.toLowerCase().match(/\.(jpg|jpeg|png|gif|webp|svg)$/)) {
                filenames.push(filename);
            }
        }
        
        if (filenames.length === 0) {
            console.warn('No screensaver images found in directory');
            // Fallback to a default image if available
            screensaverImages = [CONFIG.DEF_ALBUM_ART_PATH];
            screensaverImagesLoaded = true;
            return screensaverImages;
        }
        
        // Build full paths for each image
        const images = filenames.map(filename => `assets/images/screensavers/${filename}`);
        
        const previousCount = screensaverImages.length;
        screensaverImages = images;
        screensaverImagesLoaded = true;
        
        if (forceRefresh && previousCount !== images.length) {
            console.log(`Screensaver images refreshed: ${previousCount} -> ${images.length} images`);
        } else {
            console.log(`Loaded ${images.length} screensaver image paths (will load on-demand)`);
        }
        
        return screensaverImages;
    } catch (error) {
        console.error('Error loading screensaver images:', error);
        // Fallback to default image
        screensaverImages = ['assets/images/cat.jpg'];
        screensaverImagesLoaded = true;
        return screensaverImages;
    }
}

// Start background refresh of screensaver images every 5 minutes
function startScreensaverRefresh() {
    // Clear any existing refresh interval
    if (screensaverRefreshInterval) {
        clearInterval(screensaverRefreshInterval);
    }
    
    // Refresh screensaver list at configured interval
    screensaverRefreshInterval = setInterval(async () => {
        console.log('Background refresh: Updating screensaver images list...');
        await loadScreensaverImages(true); // Force refresh
    }, CONFIG.SCREENSAVER_REFRESH_INTERVAL);
    
    console.log(`Screensaver background refresh enabled (every ${CONFIG.SCREENSAVER_REFRESH_INTERVAL / 60000} minutes)`);
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

// ===== UTILITY FUNCTIONS =====
const utils = {
    color: {
        getLuminance(r, g, b) {
            const [rs, gs, bs] = [r, g, b].map(val => {
                val = val / 255;
                return val <= 0.03928 ? val / 12.92 : Math.pow((val + 0.055) / 1.055, 2.4);
            });
            return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
        },
        
        brighten(color, factor = 2.5) {
            const brightness = (color.r + color.g + color.b) / 3;
            let adjustFactor = factor;
            
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
        },
        
        toRGBA(color, alpha = 1) {
            return `rgba(${color.r}, ${color.g}, ${color.b}, ${alpha})`;
        }
    },
    
    storage: {
        get(key) {
            return localStorage.getItem(key);
        },
        
        set(key, value) {
            localStorage.setItem(key, value);
        },
        
        getInt(key, defaultValue = 0) {
            const value = localStorage.getItem(key);
            return value ? parseInt(value) : defaultValue;
        }
    }
};

// ===== STATE MANAGEMENT =====
let glowState = 'off';
let equalizerState = 'off';
let isPlaying = false;
let equalizerAutoEnabled = false;
let progressEffectState = 'off';

// WebSocket connection
let socket = null;
let reconnectAttempts = 0;
let reconnectCycle = 0;
let waitingForRetry = false;
let retryWaitTimeout = null;
let wasInNoPlaybackBeforeError = false;
let hasReceivedTrackData = false; // Track if we've ever received track data
let currentDeviceList = [];
let currentAlbumName = '';
let currentAlbumColors = [];
let rotationState = 0;

// Paused screensaver delay - use config value
let pausedScreensaverTimeout = null;
const PAUSED_SCREENSAVER_DELAY = CONFIG.SCREENSAVER_PAUSED_DELAY_MINUTES * 60 * 1000;

// Initial connection screensaver delay - wait 5 minutes before showing screensaver on first failure
let initialScreensaverTimeout = null;

// Cursor auto-hide in fullscreen
let cursorHideTimeout = null;

// Progress tracking for comet animation
let progressState = {
    progressMs: 0,
    durationMs: 0,
    lastUpdateTime: null,
    isPlaying: false,
    animationFrameId: null
};

// Separate animation state for sunrise (to avoid conflicts with comet)
let sunriseAnimationState = {
    animationFrameId: null,
    lastUpdateTime: null,
    shootingStarInterval: null,
    activeShootingStars: [] // Track which stars are currently animating
};

// Initialize WebSocket connection
function connectWebSocket() {
    // Note: In browsers, SSL certificate verification cannot be disabled programmatically.
    // For self-signed certificates, you must manually trust the certificate in your browser:
    // 1. Visit https://localhost:5001 in your browser
    // 2. Accept the security warning to trust the self-signed certificate
    // 3. Then reload this page
    
    socket = io(WS_URL, {
        path: selectedEnvConfig.WS_SUB_PATH ? `${selectedEnvConfig.WS_SUB_PATH}` : '/socket.io',
        transports: ['websocket', 'polling'],
        reconnection: true,
        reconnectionDelay: 1000,
        reconnectionDelayMax: 5000,
        reconnectionAttempts: CONFIG.WS_MAX_RECON_ATTEMPTS
    });
    
    // Connection events
    socket.on('connect', () => {
        console.log('Connected to server');
        reconnectAttempts = 0;
        reconnectCycle = 0;
        waitingForRetry = false;
        
        // Preserve screensaver state if currently showing - only clear if we're not in screensaver mode
        const wasInScreensaver = document.body.classList.contains('no-playback-active');
        if (!wasInScreensaver) {
            wasInNoPlaybackBeforeError = false;
        }
        
        // Clear any pending retry timeout
        if (retryWaitTimeout) {
            clearTimeout(retryWaitTimeout);
            retryWaitTimeout = null;
        }
        
        // Clear any pending initial screensaver timeout
        if (initialScreensaverTimeout) {
            clearTimeout(initialScreensaverTimeout);
            initialScreensaverTimeout = null;
        }
        
        // Clear waiting state and resume animations
        document.body.classList.remove('waiting-for-retry');
        
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
        
        // Remove waiting state when disconnect triggers new reconnection cycle
        document.body.classList.remove('waiting-for-retry');
        
        updateConnectionStatus('disconnected');
        
        // Determine what to show:
        // Priority: Keep screensaver active if already showing, or show it for connection errors
        // Only show loading if we're currently showing the now-playing UI (had active music)
        const wasInScreensaver = document.body.classList.contains('no-playback-active');
        const isShowingNowPlaying = !elements.nowPlaying.classList.contains('hidden');
        
        if (wasInScreensaver) {
            // Already showing screensaver - keep it active
            // (screensaver continues, retries happen in background)
        } else if (waitingForRetry && reconnectCycle > 1) {
            // In retry cycle after first attempt - show screensaver
            showNoPlayback();
            console.log('Showing screensaver - connection attempts will continue in background');
        } else if (!hasReceivedTrackData && reconnectCycle === 0) {
            // Initial connection attempt - show loading, don't show screensaver yet
            // (screensaver will show after 5-minute timer if still failing)
            showLoading('Connecting...');
        } else if (isShowingNowPlaying) {
            // Was showing now-playing UI - show loading/reconnecting message
            showLoading('Reconnecting...');
        } else if (hasReceivedTrackData) {
            // Had data before, now disconnected - show screensaver
            showNoPlayback();
            console.log('Showing screensaver - connection attempts will continue in background');
        } else {
            // Default: show loading
            showLoading('Connecting...');
        }
    });
    
    socket.on('connect_error', (error) => {
        console.error('Connection error:', error);
        reconnectAttempts++;
        
        // Ensure waiting-for-retry class is removed when actively retrying
        // (it should only be present during the wait period between retry cycles)
        if (!waitingForRetry) {
            document.body.classList.remove('waiting-for-retry');
        }
        
        updateConnectionStatus('connecting');
        
        // Track if we're in no-playback/screensaver mode
        const isInNoPlayback = document.body.classList.contains('no-playback-active');
        wasInNoPlaybackBeforeError = isInNoPlayback;
        
        // Only hide UI elements if not in screensaver mode
        if (!isInNoPlayback) {
            // Hide app settings during connection error (only when showing playback)
            if (elements.connectionStatus) {
                elements.connectionStatus.style.display = 'none';
            }
            if (elements.equalizer) {
                elements.equalizer.classList.add('hidden');
            }
        }
        
        if (reconnectAttempts >= CONFIG.WS_MAX_RECON_ATTEMPTS) {
            if (!waitingForRetry) {
                // First time hitting max attempts in this cycle
                reconnectCycle++;
                waitingForRetry = true;
                
                const waitMinutes = CONFIG.WS_RECONN_WAIT_MINUTES;
                const waitMs = waitMinutes * 60 * 1000;
                const retryTime = new Date(Date.now() + waitMs);
                
                console.log(`Connection failed after ${CONFIG.WS_MAX_RECON_ATTEMPTS} attempts (cycle ${reconnectCycle}). Will retry in ${waitMinutes} minutes at ${retryTime.toLocaleTimeString()}`);
                
                // For first retry cycle: wait 5 minutes before showing screensaver
                // For subsequent cycles: show screensaver immediately
                const currentlyInScreensaver = document.body.classList.contains('no-playback-active');
                const isShowingNowPlaying = !elements.nowPlaying.classList.contains('hidden');
                
                if (reconnectCycle === 1 && !hasReceivedTrackData) {
                    // First connection retry cycle - wait before showing screensaver
                    const screensaverDelayMinutes = CONFIG.SCREENSAVER_PAUSED_DELAY_MINUTES;
                    console.log(`Initial connection failed. Screensaver will activate in ${screensaverDelayMinutes} minutes if connection not restored.`);
                    showLoading(`Connection failed - retrying in ${screensaverDelayMinutes} minutes`);
                    
                    // Set timer to show screensaver after configured delay
                    initialScreensaverTimeout = setTimeout(() => {
                        console.log(`${screensaverDelayMinutes} minutes elapsed - activating screensaver`);
                        showNoPlayback();
                        initialScreensaverTimeout = null;
                    }, screensaverDelayMinutes * 60 * 1000);
                } else {
                    // Subsequent cycles OR had connection before - show screensaver immediately
                    if (!currentlyInScreensaver && !isShowingNowPlaying) {
                        showNoPlayback();
                    }
                    console.log('Screensaver active - retrying in background');
                }
                updateConnectionStatus('connection-failed');
                
                // Stop all animations during wait period
                document.body.classList.add('waiting-for-retry');
                
                // Wait 5 minutes then reset and try again
                retryWaitTimeout = setTimeout(() => {
                    console.log(`Retry cycle ${reconnectCycle + 1} starting after ${waitMinutes} minute wait`);
                    reconnectAttempts = 0;
                    waitingForRetry = false;
                    
                    // Resume all animations when retrying starts again
                    document.body.classList.remove('waiting-for-retry');
                    
                    // Disconnect and reconnect to trigger new connection attempts
                    if (socket) {
                        socket.disconnect();
                        // Small delay before reconnecting
                        setTimeout(() => {
                            socket.connect();
                            // Don't change display here - let disconnect/connect handlers manage it
                            // Screensaver will persist if active, which is what we want
                            updateConnectionStatus('connecting');
                        }, 1000);
                    }
                }, waitMs);
            }
        }
    });
    
    // Track update event
    socket.on('track_update', (data) => {
        if (data) {
            hasReceivedTrackData = true;
        }
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
    document.body.classList.add('music-paused');
    
    // Hide equalizer and app settings during loading/reconnecting
    if (elements.equalizer) {
        elements.equalizer.classList.add('hidden');
    }
    if (elements.connectionStatus) {
        elements.connectionStatus.style.display = 'none';
    }
    
    // Hide all progress effects during loading/error state
    hideProgressComet();
    hideSunriseElement();
    
    // Clear equalizer fill if active
    clearEqualizerFill();
    
    stopScreensaverCycle();
}

// Show no playback state
function showNoPlayback() {
    elements.loading.classList.add('hidden');
    elements.noPlayback.classList.remove('hidden');
    elements.nowPlaying.classList.add('hidden');
    document.body.classList.add('no-playback-active');
    document.body.classList.add('music-paused');
    isPlaying = false;
    
    // Show app settings in no-playback state (unless expanded)
    if (elements.connectionStatus) {
        elements.connectionStatus.style.display = '';
    }
    
    // Hide progress effects in no playback/screensaver mode
    hideProgressComet();
    hideSunriseElement();
    
    // Force hide equalizer in screensaver mode
    if (elements.equalizer) {
        elements.equalizer.classList.add('hidden');
    }
    
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
                // console.log(`✓ Successfully loaded: ${imageSrc}`);
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
    return utils.color.getLuminance(r, g, b);
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
    
    // Adjust gradient angle based on rotation state
    // Default is 135deg, subtract rotation amount to keep gradient visually consistent
    let gradientAngle = 135;
    if (rotationState === 90) {
        gradientAngle = 45;  // 135 - 90
    } else if (rotationState === 180) {
        gradientAngle = 315; // 135 - 180 = -45, or 315
    } else if (rotationState === 270) {
        gradientAngle = 225; // 135 - 270 = -135, or 225
    }
    
    // Create gradient with adjusted angle
    const gradient = `linear-gradient(${gradientAngle}deg, ${bgColors[0]}, ${bgColors[1] || bgColors[0]}, ${bgColors[2] || bgColors[1] || bgColors[0]})`;
    document.body.style.transition = 'background 1s ease';
    document.body.style.background = gradient;
    
    // Store background colors as CSS variables for mountain blending
    document.body.style.setProperty('--bg-color-1', bgColors[0]);
    document.body.style.setProperty('--bg-color-2', bgColors[1] || bgColors[0]);
    document.body.style.setProperty('--bg-color-3', bgColors[2] || bgColors[1] || bgColors[0]);
    
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
    if (!progressState.isPlaying || !progressState.lastUpdateTime) return;
    
    const now = Date.now();
    const elapsed = now - progressState.lastUpdateTime;
    
    // **OPTIMIZATION: Only update every 50ms instead of every frame**
    // Reduces from 60fps to 20fps - still smooth but 66% less CPU
    // if (elapsed < 50) {
    //     progressState.animationFrameId = requestAnimationFrame(animateProgressComet);
    //     return;
    // }
    
    progressState.progressMs = Math.min(progressState.progressMs + elapsed, progressState.durationMs);
    progressState.lastUpdateTime = now;
    
    updateProgressComet();
    
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

// ===== Sunrise Progress Functions =====

// Create sunrise element
function createSunriseElement() {
    if (elements.sunriseContainer) return; // Already exists
    
    const container = document.createElement('div');
    container.className = 'sunrise-container hidden';
    container.id = 'sunrise-container';
    
    // Create stars container (for nighttime)
    const starsContainer = document.createElement('div');
    starsContainer.className = 'sunrise-stars';
    
    // Create static twinkling stars
    for (let i = 0; i < 80; i++) {
        const star = document.createElement('div');
        star.className = 'star';
        star.style.left = `${Math.random() * 100}%`;
        star.style.top = `${Math.random() * 80}%`; // Keep in upper 80% of screen
        star.style.animationDelay = `${Math.random() * 3}s`;
        star.style.animationDuration = `${2 + Math.random() * 2}s`;
        
        // Vary star sizes - some bigger than others
        const starSize = 2 + Math.random() * 2; // 2-4px
        star.style.width = `${starSize}px`;
        star.style.height = `${starSize}px`;
        if (starSize > 3) {
            star.style.boxShadow = `0 0 ${starSize * 1.5}px rgba(255, 255, 255, 0.9)`;
        }
        
        starsContainer.appendChild(star);
    }
    
    // Create shooting stars (will be triggered randomly via JavaScript)
    const shootingStarCount = 6; // Create a pool of 6 stars (mix of short and long)
    for (let i = 0; i < shootingStarCount; i++) {
        const shootingStar = document.createElement('div');
        shootingStar.className = 'shooting-star';
        shootingStar.dataset.starIndex = i;
        // Mark some stars as long variants (40% chance)
        shootingStar.dataset.starType = Math.random() < 0.4 ? 'long' : 'short';
        
        // Stars start invisible and positioned randomly when triggered
        shootingStar.style.opacity = '0';
        shootingStar.style.animation = 'none'; // No automatic animation
        
        starsContainer.appendChild(shootingStar);
    }
    
    container.appendChild(starsContainer);
    
    // Create sky background
    const sky = document.createElement('div');
    sky.className = 'sunrise-sky';
    container.appendChild(sky);
    
    // Create sun element
    const sun = document.createElement('div');
    sun.className = 'sunrise-sun';
    container.appendChild(sun);
    
    // Create optional mountain silhouette
    const mountains = document.createElement('div');
    mountains.className = 'sunrise-mountains';
    container.appendChild(mountains);
    
    document.body.appendChild(container);
    elements.sunriseContainer = container;
    
    console.log('Sunrise & Sunset element created');
}

// Trigger a random shooting star animation
function triggerShootingStar() {
    if (!elements.sunriseContainer) return;
    
    const starsContainer = elements.sunriseContainer.querySelector('.sunrise-stars');
    if (!starsContainer) return;
    
    const shootingStars = starsContainer.querySelectorAll('.shooting-star');
    if (shootingStars.length === 0) return;
    
    // Find an available (not currently animating) shooting star
    let availableStars = [];
    shootingStars.forEach((star, index) => {
        if (!sunriseAnimationState.activeShootingStars.includes(index)) {
            availableStars.push({ star, index });
        }
    });
    
    if (availableStars.length === 0) return; // All stars are currently animating
    
    // Pick a random available star
    const { star, index } = availableStars[Math.floor(Math.random() * availableStars.length)];
    
    // Mark as active
    sunriseAnimationState.activeShootingStars.push(index);
    
    // Random starting positions (from edges)
    const edge = Math.floor(Math.random() * 4); // 0=top, 1=right, 2=bottom, 3=left
    let startX, startY, shootX, shootY, angle;
    
    if (edge === 0) { // From top
        startX = Math.random() * 100;
        startY = 0;
        shootX = (Math.random() * 60 - 30);
        shootY = Math.random() * 40 + 20;
    } else if (edge === 1) { // From right
        startX = 100;
        startY = Math.random() * 50;
        shootX = -(Math.random() * 40 + 20);
        shootY = Math.random() * 60 - 30;
    } else if (edge === 2) { // From bottom (rare)
        startX = Math.random() * 100;
        startY = 100;
        shootX = (Math.random() * 60 - 30);
        shootY = -(Math.random() * 30 + 10);
    } else { // From left
        startX = 0;
        startY = Math.random() * 50;
        shootX = Math.random() * 40 + 20;
        shootY = Math.random() * 60 - 30;
    }
    
    // Set position and trajectory
    star.style.left = `${startX}%`;
    star.style.top = `${startY}%`;
    star.style.setProperty('--shoot-x', `${shootX}vw`);
    star.style.setProperty('--shoot-y', `${shootY}vh`);
    star.style.setProperty('--shoot-angle', `${Math.atan2(shootY, shootX) * (180 / Math.PI)}deg`);
    
    // Apply long class if this is a long shooting star
    if (star.dataset.starType === 'long') {
        star.classList.add('long');
    } else {
        star.classList.remove('long');
    }
    
    // Reset and restart animation
    star.style.animation = 'none';
    // Force reflow to restart animation
    star.offsetHeight;
    star.style.animation = 'shoot 3s linear forwards';
    
    // Remove from active list after animation completes
    setTimeout(() => {
        const activeIndex = sunriseAnimationState.activeShootingStars.indexOf(index);
        if (activeIndex > -1) {
            sunriseAnimationState.activeShootingStars.splice(activeIndex, 1);
        }
    }, 3000); // Match animation duration
}

// Start random shooting star spawning
function startShootingStarSpawning() {
    if (sunriseAnimationState.shootingStarInterval) return; // Already running
    
    // Trigger one shooting star at random intervals between 2-8 seconds
    const scheduleNextStar = () => {
        const delay = Math.random() * 6000 + 2000; // 2-8 seconds
        sunriseAnimationState.shootingStarInterval = setTimeout(() => {
            triggerShootingStar(); // Spawn a single star
            scheduleNextStar(); // Schedule the next star
        }, delay);
    };
    
    // Trigger first star immediately
    triggerShootingStar();
    // Schedule subsequent stars
    scheduleNextStar();
}

// Stop shooting star spawning
function stopShootingStarSpawning() {
    if (sunriseAnimationState.shootingStarInterval) {
        clearTimeout(sunriseAnimationState.shootingStarInterval);
        sunriseAnimationState.shootingStarInterval = null;
    }
    sunriseAnimationState.activeShootingStars = [];
}

// Update sunrise position and colors based on song progress
function updateSunriseElement() {
    if (!elements.sunriseContainer || !progressState.durationMs) return;
    
    const { progressMs, durationMs } = progressState;
    
    // Speed up sunrise to complete at 98% of song duration (same as comet)
    // This ensures the sun fully sets before the song ends/transitions
    const completionTarget = 0.98;
    const percentage = Math.min(Math.max(progressMs / durationMs, 0), 1) / completionTarget;
    const clampedPercentage = Math.min(percentage, 1);
    
    // Get screen dimensions (accounting for rotation)
    const effectiveWidth = (rotationState === 90 || rotationState === 270) ? window.innerHeight : window.innerWidth;
    const effectiveHeight = (rotationState === 90 || rotationState === 270) ? window.innerWidth : window.innerHeight;
    
    // Calculate sun path: sunrise (left) to sunset (right) with lower, narrower arc
    // Horizontal movement: 2% → 98% of screen width (full screen left to right)
    const startX = 2;
    const endX = 98;
    const sunX = startX + (endX - startX) * clampedPercentage;
    
    // Vertical movement: sunrise → peak → sunset (symmetric arc)
    // Start: 97% (mostly below horizon, only upper portion peeking above mountains)
    // End: 97% (mostly below horizon at sunset, only upper portion visible)
    const startY = 97;
    const endY = 97;
    
    // Peak height varies by rotation (landscape vs portrait)
    // Landscape (0° and 180°): Higher arc to clear mountains better
    // Portrait (90° and 270°): Lower arc to stay near mountains
    let peakY;
    if (rotationState === 0 || rotationState === 180) {
        peakY = 65; // Higher arc for landscape mode
    } else {
        peakY = 75; // Lower arc for portrait mode
    }
    
    // Create symmetric arc using parabola (peaks at 50%)
    // Arc height calculation: maximum at 50%, returns to horizon at 100%
    const arcFactor = 4 * (startY - peakY) * clampedPercentage * (1 - clampedPercentage);
    const sunY = startY - arcFactor;
    
    // Sun size increases as it rises (dawn to day)
    const minSize = 60;
    const maxSize = 120;
    const sunSize = minSize + (maxSize - minSize) * clampedPercentage;
    
    // Sun opacity increases as it rises
    const minOpacity = 0.6;
    const maxOpacity = 1.0;
    const sunOpacity = minOpacity + (maxOpacity - minOpacity) * clampedPercentage;
    
    // Mountain lighting based on sun Y position (lower Y = higher sun = more light)
    // sunY ranges from ~65 (high/midday) to 97 (low/horizon)
    // Normalize: (97 - sunY) / 32 gives 0 at horizon, 1 at peak
    const lightIntensity = Math.max(0, Math.min(1, (97 - sunY) / 32));
    
    // Proximity: how close sun is to mountain (higher sunY = closer)
    // When sun is low (high sunY ~90-97), proximity is high (localized spotlight)
    // When sun is high (low sunY ~65-75), proximity is lower (broader light)
    const proximity = Math.max(0, Math.min(1, (sunY - 65) / 32));
    
    // Brightness: 1.0 (dark) to 1.8 (bright)
    const mountainBrightness = 1 + (lightIntensity * 0.8);
    
    // Sun's outer glow colors (from .sunrise-sun::after)
    // Use the actual colors the sun is emitting
    const sunGlowColor1 = { r: 255, g: 230, b: 124 }; // Bright golden
    const sunGlowColor2 = { r: 255, g: 179, b: 71 };  // Orange
    const sunGlowColor3 = { r: 255, g: 209, b: 220 }; // Peachy pink
    
    // Glow alpha based on light intensity and proximity
    // Stronger when sun is closer to mountain
    const glowAlpha1 = lightIntensity * (0.5 + proximity * 0.3);
    const glowAlpha2 = lightIntensity * (0.4 + proximity * 0.2);
    const glowAlpha3 = lightIntensity * (0.3 + proximity * 0.1);
    
    // Create RGBA strings with sun's glow colors
    const mountainGlow1 = `rgba(${sunGlowColor1.r}, ${sunGlowColor1.g}, ${sunGlowColor1.b}, ${glowAlpha1})`;
    const mountainGlow2 = `rgba(${sunGlowColor2.r}, ${sunGlowColor2.g}, ${sunGlowColor2.b}, ${glowAlpha2})`;
    const mountainGlow3 = `rgba(${sunGlowColor3.r}, ${sunGlowColor3.g}, ${sunGlowColor3.b}, ${glowAlpha3})`;
    
    // Apply CSS custom properties for sun position
    const container = elements.sunriseContainer;
    container.style.setProperty('--sun-x', `${sunX}%`);
    container.style.setProperty('--sun-y', `${sunY}%`);
    container.style.setProperty('--sun-size', `${sunSize}px`);
    container.style.setProperty('--sun-opacity', sunOpacity);
    container.style.setProperty('--mountain-brightness', mountainBrightness);
    container.style.setProperty('--mountain-glow-1', mountainGlow1);
    container.style.setProperty('--mountain-glow-2', mountainGlow2);
    container.style.setProperty('--mountain-glow-3', mountainGlow3);
    
    // Update sky gradient colors based on progress: sunrise → midday → sunset
    let skyColor1, skyColor2, skyColor3;
    
    if (clampedPercentage < 0.25) {
        // Early sunrise: warm orange and pink glow
        const t = clampedPercentage / 0.25;
        skyColor1 = `rgba(${Math.round(255)}, ${Math.round(140 + 67 * t)}, ${Math.round(60 + 40 * t)}, ${0.3 + 0.2 * t})`;
        skyColor2 = `rgba(${Math.round(255)}, ${Math.round(100 + 65 * t)}, ${Math.round(50 + 30 * t)}, ${0.2 + 0.2 * t})`;
        skyColor3 = `rgba(${Math.round(255 - 50 * t)}, ${Math.round(80 + 55 * t)}, ${Math.round(60 + 40 * t)}, ${0.15 + 0.15 * t})`;
    } else if (clampedPercentage < 0.5) {
        // Mid-morning to noon: bright golden to blue sky
        const t = (clampedPercentage - 0.25) / 0.25;
        skyColor1 = `rgba(${Math.round(255 - 120 * t)}, ${Math.round(207 + 48 * t)}, ${Math.round(100 + 135 * t)}, ${0.5 - 0.1 * t})`;
        skyColor2 = `rgba(${Math.round(255 - 110 * t)}, ${Math.round(165 + 65 * t)}, ${Math.round(80 + 120 * t)}, ${0.4 - 0.1 * t})`;
        skyColor3 = `rgba(${Math.round(205 - 70 * t)}, ${Math.round(135 + 95 * t)}, ${Math.round(100 + 100 * t)}, ${0.3 - 0.1 * t})`;
    } else if (clampedPercentage < 0.75) {
        // Afternoon to evening: blue sky to golden hour
        const t = (clampedPercentage - 0.5) / 0.25;
        skyColor1 = `rgba(${Math.round(135 + 120 * t)}, ${Math.round(255 - 55 * t)}, ${Math.round(235 - 135 * t)}, ${0.4 + 0.1 * t})`;
        skyColor2 = `rgba(${Math.round(145 + 110 * t)}, ${Math.round(230 - 80 * t)}, ${Math.round(200 - 120 * t)}, ${0.3 + 0.15 * t})`;
        skyColor3 = `rgba(${Math.round(135 + 100 * t)}, ${Math.round(230 - 110 * t)}, ${Math.round(200 - 130 * t)}, ${0.2 + 0.15 * t})`;
    } else {
        // Sunset: warm orange, red, and purple tones
        const t = (clampedPercentage - 0.75) / 0.25;
        skyColor1 = `rgba(${Math.round(255)}, ${Math.round(200 - 90 * t)}, ${Math.round(100 - 40 * t)}, ${0.5 + 0.15 * t})`;
        skyColor2 = `rgba(${Math.round(255 - 45 * t)}, ${Math.round(150 - 70 * t)}, ${Math.round(80 + 20 * t)}, ${0.45 + 0.2 * t})`;
        skyColor3 = `rgba(${Math.round(235 - 85 * t)}, ${Math.round(120 - 50 * t)}, ${Math.round(70 + 80 * t)}, ${0.35 + 0.2 * t})`;
    }
    
    // Option to use album colors for sunrise
    if (currentAlbumColors.length >= 3) {
        // Use warm colors from album art if available
        const warmColors = currentAlbumColors.filter(c => {
            // Filter for warm colors (high red, moderate green, low blue)
            return c.r > 150 && c.r > c.b && c.r > c.g * 0.8;
        });
        
        if (warmColors.length >= 3) {
            const brighten = (color, factor) => ({
                r: Math.min(255, Math.round(color.r * factor)),
                g: Math.min(255, Math.round(color.g * factor)),
                b: Math.min(255, Math.round(color.b * factor))
            });
            
            const bright1 = brighten(warmColors[0], 1.2);
            const bright2 = brighten(warmColors[1], 1.1);
            const bright3 = brighten(warmColors[2], 1.0);
            
            const intensity = 0.3 + 0.4 * clampedPercentage;
            skyColor1 = `rgba(${bright1.r}, ${bright1.g}, ${bright1.b}, ${intensity})`;
            skyColor2 = `rgba(${bright2.r}, ${bright2.g}, ${bright2.b}, ${intensity * 0.8})`;
            skyColor3 = `rgba(${bright3.r}, ${bright3.g}, ${bright3.b}, ${intensity * 0.6})`;
        }
    }
    
    container.style.setProperty('--sky-color-1', skyColor1);
    container.style.setProperty('--sky-color-2', skyColor2);
    container.style.setProperty('--sky-color-3', skyColor3);
    
    // Mountain color blending - only for 'blended-sunrise' effect
    let mountainBase1, mountainBase2;
    
    if (progressEffectState === 'blended-sunrise') {
        // Mountain blends with background colors (from album art)
        // Get background colors from CSS variables
        const bgColor1 = getComputedStyle(document.body).getPropertyValue('--bg-color-1').trim() || 'rgb(20, 20, 20)';
        const bgColor2 = getComputedStyle(document.body).getPropertyValue('--bg-color-2').trim() || 'rgb(15, 15, 15)';
        
        // Parse RGB and slightly darken for mountain silhouette
        const parseRGB = (colorStr) => {
            const match = colorStr.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
            if (match) {
                return {
                    r: parseInt(match[1]),
                    g: parseInt(match[2]),
                    b: parseInt(match[3])
                };
            }
            return { r: 20, g: 20, b: 20 };
        };
        
        const bg1 = parseRGB(bgColor1);
        const bg2 = parseRGB(bgColor2);
        
        // Use background colors with slight darkening for mountain silhouette
        // Keep fully opaque (alpha = 1) so mountain blocks sun, blend mode handles color blending
        mountainBase1 = `rgba(${Math.round(bg1.r * 0.8)}, ${Math.round(bg1.g * 0.8)}, ${Math.round(bg1.b * 0.8)}, 1)`;
        mountainBase2 = `rgba(${Math.round(bg2.r * 0.7)}, ${Math.round(bg2.g * 0.7)}, ${Math.round(bg2.b * 0.7)}, 1)`;
    } else {
        // Regular 'sunrise' effect: keep original dark mountain colors (fully opaque)
        mountainBase1 = 'rgba(20, 20, 20, 1)';
        mountainBase2 = 'rgba(10, 10, 10, 1)';
    }
    
    container.style.setProperty('--mountain-base-1', mountainBase1);
    container.style.setProperty('--mountain-base-2', mountainBase2);
    
    // Control background brightness (day/night cycle)
    // 0% = dawn (dark), 50% = midday (full brightness), 100% = night (dark)
    let backgroundBrightness;
    if (clampedPercentage < 0.5) {
        // Dawn to midday: fade from dark (0.3) to full brightness (1.0)
        backgroundBrightness = 0.3 + (clampedPercentage * 2) * 0.7;
    } else {
        // Midday to dusk: fade from full brightness (1.0) to dark (0.2)
        backgroundBrightness = 1.0 - ((clampedPercentage - 0.5) * 2) * 0.8;
    }
    
    // Apply background overlay for dimming effect
    container.style.setProperty('--background-brightness', backgroundBrightness);
    
    // Control star visibility (appear as sun sets after midday)
    let starOpacity = 0;
    if (clampedPercentage > 0.5) {
        // Stars fade in from 50% to 100% of song
        starOpacity = (clampedPercentage - 0.5) * 2;
    }
    
    const starsContainer = container.querySelector('.sunrise-stars');
    if (starsContainer) {
        starsContainer.style.opacity = starOpacity;
    }
}

// Animate sunrise with client-side interpolation
function animateSunrise() {
    if (!progressState.isPlaying || !sunriseAnimationState.lastUpdateTime) {
        return;
    }
    
    const now = Date.now();
    const elapsed = now - sunriseAnimationState.lastUpdateTime;

    // **Update every 100ms instead of every frame**
    // Sun moves slowly, 10fps is plenty smooth
    if (elapsed < 100) {
        sunriseAnimationState.animationFrameId = requestAnimationFrame(animateSunrise);
        return;
    }
    
    // Update progress with elapsed time
    progressState.progressMs = Math.min(progressState.progressMs + elapsed, progressState.durationMs);
    sunriseAnimationState.lastUpdateTime = now;
    
    // Update visual position
    updateSunriseElement();
    
    // Continue animation loop if still playing
    if (progressState.isPlaying && progressState.progressMs < progressState.durationMs) {
        sunriseAnimationState.animationFrameId = requestAnimationFrame(animateSunrise);
    }
}

// Show sunrise element
function showSunriseElement() {
    if (!elements.sunriseContainer) {
        createSunriseElement();
    }
    
    if (elements.sunriseContainer) {
        // Update position BEFORE making visible to avoid visual jump
        updateSunriseElement();
        
        elements.sunriseContainer.classList.remove('hidden');
        
        // Start animation loop if playing
        if (progressState.isPlaying) {
            if (sunriseAnimationState.animationFrameId) {
                cancelAnimationFrame(sunriseAnimationState.animationFrameId);
            }
            sunriseAnimationState.lastUpdateTime = Date.now();
            sunriseAnimationState.animationFrameId = requestAnimationFrame(animateSunrise);
        }
        
        // Start random shooting star spawning
        startShootingStarSpawning();
        
        console.log('Sunrise element shown');
    }
}

// Hide sunrise element
function hideSunriseElement() {
    if (elements.sunriseContainer) {
        elements.sunriseContainer.classList.add('hidden');
    }
    
    // Stop animation loop
    if (sunriseAnimationState.animationFrameId) {
        cancelAnimationFrame(sunriseAnimationState.animationFrameId);
        sunriseAnimationState.animationFrameId = null;
    }
    
    // Stop shooting star spawning
    stopShootingStarSpawning();
}

// Pause sunrise (keep visible but stop moving)
function pauseSunrise() {
    if (sunriseAnimationState.animationFrameId) {
        cancelAnimationFrame(sunriseAnimationState.animationFrameId);
        sunriseAnimationState.animationFrameId = null;
    }
    // Stop shooting star spawning when paused
    stopShootingStarSpawning();
}

// Resume sunrise animation
function resumeSunrise() {
    if (progressState.isPlaying && elements.sunriseContainer && !elements.sunriseContainer.classList.contains('hidden')) {
        sunriseAnimationState.lastUpdateTime = Date.now();
        if (sunriseAnimationState.animationFrameId) {
            cancelAnimationFrame(sunriseAnimationState.animationFrameId);
        }
        sunriseAnimationState.animationFrameId = requestAnimationFrame(animateSunrise);
        // Resume shooting star spawning
        startShootingStarSpawning();
        console.log('Sunrise animation resumed');
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
        hideSunriseElement();
        return;
    }
    
    // Track previous playback state for comparison
    const wasPlaying = isPlaying;
    
    // Update playback state
    isPlaying = trackData.is_playing;
    
    // Update body class for pausing animations
    if (isPlaying) {
        document.body.classList.remove('music-paused');
    } else {
        document.body.classList.add('music-paused');
    }
    
    // Notify server about progress needs based on playback state and active effects
    if (socket && socket.connected && progressEffectState !== 'off') {
        if (isPlaying && !wasPlaying) {
            // Music started playing - request progress updates
            socket.emit('enable_progress');
            console.log('Music playing - requesting progress updates from server');
        } else if (!isPlaying && wasPlaying) {
            // Music paused - stop progress updates
            socket.emit('disable_progress');
            console.log('Music paused - stopping progress updates from server');
        }
    }
    
    // Update progress state for comet and sunrise animation
    if (trackData.progress_ms !== undefined && trackData.duration_ms !== undefined) {
        const wasProgressPlaying = progressState.isPlaying;
        progressState.progressMs = trackData.progress_ms;
        progressState.durationMs = trackData.duration_ms;
        progressState.isPlaying = trackData.is_playing;
        progressState.lastUpdateTime = Date.now();
        
        // Update comet and sunrise position
        updateProgressComet();
        updateSunriseElement();
        
        // Handle play/pause state changes
        if (trackData.is_playing && !wasProgressPlaying) {
            // Resumed playing
            resumeProgressComet();
            resumeSunrise();
        } else if (!trackData.is_playing && wasProgressPlaying) {
            // Paused
            pauseProgressComet();
            pauseSunrise();
        } else if (trackData.is_playing) {
            // Still playing, ensure animation is running
            resumeProgressComet();
            resumeSunrise();
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
        
        // Show sunrise if we have valid duration and effect is enabled
        if (trackData.duration_ms > 0 && (progressEffectState === 'sunrise' || progressEffectState === 'blended-sunrise')) {
            showSunriseElement();
        } else {
            hideSunriseElement();
        }
    } else {
        // No progress data available
        hideProgressComet();
        hideSunriseElement();
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
                    // Update comet and sunrise position and colors after colors are extracted
                    updateProgressComet();
                    updateSunriseElement();
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
                elements.albumArt.src = CONFIG.DEF_ALBUM_ART_PATH;
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
        
        if (elements.deviceName) {
            const statusText = isPlaying ? 'Playing on' : 'Paused on';
            elements.deviceName.textContent = `${statusText} ${deviceDisplay}`;
        }
    }
    
    // Show appropriate display:
    // Only show now-playing UI when music is actively playing
    // When paused, wait 5 minutes before showing screensaver
    if (trackData.is_playing) {
        // Music is playing - cancel any pending screensaver timer and show now-playing UI
        if (pausedScreensaverTimeout) {
            clearTimeout(pausedScreensaverTimeout);
            pausedScreensaverTimeout = null;
        }
        showNowPlaying();
    } else {
        // Music is paused - start 5-minute timer before showing screensaver
        // Keep now-playing UI visible during the wait period
        if (!pausedScreensaverTimeout) {
            // Start timer only if not already started
            pausedScreensaverTimeout = setTimeout(() => {
                showNoPlayback();
                pausedScreensaverTimeout = null;
            }, PAUSED_SCREENSAVER_DELAY);
        }
        // Keep showing now-playing UI while paused (screensaver will appear after 5 min)
        showNowPlaying();
    }
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
    const appSettings = document.getElementById('app-settings');
    const label = document.getElementById('service-label');
    let autoCollapseTimer = null;
    
    // Dock timer management functions
    const dockTimer = {
        stop: () => {
            if (autoCollapseTimer) {
                clearTimeout(autoCollapseTimer);
                autoCollapseTimer = null;
            }
        },
        start: () => {
            dockTimer.stop();
            autoCollapseTimer = setTimeout(() => {
                if (appSettings.classList.contains('expanded')) {
                    dockTimer.collapse();
                }
            }, 10000);
        },
        collapse: () => {
            appSettings.classList.remove('expanded');
            dockTimer.stop();
        },
        expand: () => {
            appSettings.classList.add('expanded');
            dockTimer.start();
        },
        reset: () => {
            if (appSettings.classList.contains('expanded')) {
                dockTimer.start();
            }
        }
    };
    
    // Event handler factory - creates all event listeners for an icon
    const createIconHandlers = (element, config) => {
        if (!element) return;
        
        const {
            onClick,
            onHover,
            label: getLabel,
            preventClick = false
        } = config;
        
        // Click handler
        if (onClick || preventClick) {
            element.addEventListener('click', (e) => {
                e.stopPropagation();
                if (!preventClick && onClick) {
                    onClick(e);
                }
                if (getLabel) {
                    showServiceLabel(typeof getLabel === 'function' ? getLabel() : getLabel, element);
                }
                dockTimer.reset();
            });
        }
        
        // Touch handler
        if (onClick || preventClick) {
            element.addEventListener('touchend', (e) => {
                e.preventDefault();
                e.stopPropagation();
                if (!preventClick && onClick) {
                    onClick(e);
                }
                if (getLabel) {
                    showServiceLabel(typeof getLabel === 'function' ? getLabel() : getLabel, element);
                }
                dockTimer.reset();
            });
        }
        
        // Hover handlers
        if (onHover !== false) {
            element.addEventListener('mouseenter', () => {
                const labelText = onHover 
                    ? (typeof onHover === 'function' ? onHover() : onHover)
                    : (typeof getLabel === 'function' ? getLabel() : getLabel);
                if (labelText) {
                    showServiceLabel(labelText, element);
                }
            });
            
            element.addEventListener('mouseleave', () => {
                hideServiceLabel();
            });
        }
    };
    
    // Touch handling for dock toggle
    let touchHandled = false;
    let touchStartX = 0, touchStartY = 0, touchStartTime = 0;
    
    document.body.addEventListener('touchstart', (e) => {
        const touch = e.touches[0];
        touchStartX = touch.clientX;
        touchStartY = touch.clientY;
        touchStartTime = Date.now();
    }, { passive: true });
    
    document.body.addEventListener('touchend', (e) => {
        const touch = e.changedTouches[0];
        const deltaX = Math.abs(touch.clientX - touchStartX);
        const deltaY = Math.abs(touch.clientY - touchStartY);
        const duration = Date.now() - touchStartTime;
        const isTap = deltaX < 10 && deltaY < 10 && duration < 300;
        
        if (!isTap) return;
        
        touchHandled = true;
        
        if (e.target.closest('#app-settings')) {
            dockTimer.reset();
            setTimeout(() => { touchHandled = false; }, 500);
            return;
        }
        
        if (e.target === label || e.target.closest('.service-label')) {
            setTimeout(() => { touchHandled = false; }, 500);
            return;
        }
        
        appSettings.classList.contains('expanded') ? dockTimer.collapse() : dockTimer.expand();
        setTimeout(() => { touchHandled = false; }, 500);
    });
    
    // Click handling for dock toggle
    document.body.addEventListener('click', (e) => {
        if (touchHandled) return;
        
        if (e.target.closest('#app-settings')) {
            dockTimer.reset();
            return;
        }
        
        if (e.target === label || e.target.closest('.service-label')) {
            return;
        }
        
        appSettings.classList.contains('expanded') ? dockTimer.collapse() : dockTimer.expand();
    });
    
    // Prevent label from closing itself
    label.addEventListener('click', (e) => e.stopPropagation());
    
    // Close label when clicking elsewhere
    document.addEventListener('click', (e) => {
        if (label.classList.contains('show') && 
            !e.target.closest('#app-settings') &&
            !e.target.closest('.device-info') &&
            e.target !== label) {
            hideServiceLabel();
        }
    });
    
    // Setup all icon handlers using factory
    createIconHandlers(document.getElementById('service-sonos'), {
        label: 'Sonos Enabled'
    });
    
    createIconHandlers(document.getElementById('service-spotify'), {
        label: 'Spotify Enabled'
    });
    
    createIconHandlers(document.getElementById('playback-status'), {
        label: () => {
            const statusText = isPlaying ? 'Playing on' : 'Paused on';
            if (currentDeviceList.length > 0) {
                const deviceDisplay = currentDeviceList.length === 1 
                    ? currentDeviceList[0] 
                    : `${currentDeviceList[0]} +${currentDeviceList.length - 1} more`;
                return `${statusText} ${deviceDisplay}`;
            }
            return isPlaying ? 'Playing' : 'Paused';
        }
    });
    
    createIconHandlers(document.querySelector('#now-playing .album-art-container'), {
        label: () => currentAlbumName
    });
    
    createIconHandlers(document.getElementById('rotation-icon'), {
        onClick: () => rotateDisplay(),
        label: () => {
            const degrees = rotationState === 0 ? '0°' : `${rotationState}°`;
            return `Rotation: ${degrees}`;
        }
    });
    
    createIconHandlers(document.getElementById('glow-icon'), {
        onClick: () => cycleGlowState(),
        onHover: () => EFFECT_NAMES.GLOW[glowState]
    });
    
    createIconHandlers(document.getElementById('equalizer-icon'), {
        onClick: (e) => {
            if (document.body.classList.contains('no-playback-active')) {
                showServiceLabel('Equalizer unavailable in screensaver mode', e.target);
                return;
            }
            cycleEqualizerState();
        },
        onHover: () => EFFECT_NAMES.EQUALIZER[equalizerState]
    });
    
    createIconHandlers(document.getElementById('progress-effect-icon'), {
        onClick: (e) => {
            if (document.body.classList.contains('no-playback-active')) {
                showServiceLabel('Progress effects unavailable in screensaver mode', e.target);
                return;
            }
            cycleProgressEffectState();
        },
        onHover: () => EFFECT_NAMES.PROGRESS[progressEffectState]
    });
    
    createIconHandlers(document.getElementById('reset-icon'), {
        onClick: () => resetAllEffects(),
        label: 'Reset All Effects'
    });
    
    createIconHandlers(document.getElementById('fullscreen-icon'), {
        onClick: () => toggleFullscreen(),
        onHover: () => {
            const isFullscreen = document.fullscreenElement || document.webkitFullscreenElement;
            return isFullscreen ? 'Exit Fullscreen' : 'Enter Fullscreen';
        }
    });
    
    // Device name handlers
    const deviceName = elements.deviceName;
    if (deviceName) {
        const getDeviceLabel = () => {
            if (currentDeviceList.length > 0) {
                const statusText = isPlaying ? 'Playing on' : 'Paused on';
                return `${statusText}:\n${currentDeviceList.join('\n')}`;
            }
            return null;
        };
        
        deviceName.addEventListener('click', (e) => {
            e.stopPropagation();
            const labelText = getDeviceLabel();
            if (labelText) showServiceLabel(labelText, deviceName, true);
        });
        
        deviceName.addEventListener('touchend', (e) => {
            e.preventDefault();
            e.stopPropagation();
            const labelText = getDeviceLabel();
            if (labelText) showServiceLabel(labelText, deviceName, true);
        });
        
        deviceName.addEventListener('mouseenter', () => {
            const labelText = getDeviceLabel();
            if (labelText) showServiceLabel(labelText, deviceName, true);
        });
        
        deviceName.addEventListener('mouseleave', () => {
            hideServiceLabel();
        });
    }
    
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
    
    // Reapply background gradient with new rotation angle if album colors are loaded
    if (currentAlbumColors.length > 0) {
        applyGradientBackground(currentAlbumColors);
    }
    
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
    const currentIndex = EFFECT_STATES.GLOW.indexOf(glowState);
    const nextIndex = (currentIndex + 1) % EFFECT_STATES.GLOW.length;
    glowState = EFFECT_STATES.GLOW[nextIndex];
    
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
    showServiceLabel(EFFECT_NAMES.GLOW[glowState], glowIcon);
    
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
    if (savedGlow && EFFECT_STATES.GLOW.includes(savedGlow)) {
        glowState = savedGlow;
    } else {
        glowState = 'off'; // Default to off
    }
    
    // Apply the restored state
    applyGlowState();
}

// Cycle through equalizer states: off -> colors -> white -> off
function cycleEqualizerState() {
    const currentIndex = EFFECT_STATES.EQUALIZER.indexOf(equalizerState);
    const nextIndex = (currentIndex + 1) % EFFECT_STATES.EQUALIZER.length;
    equalizerState = EFFECT_STATES.EQUALIZER[nextIndex];
    
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
    showServiceLabel(EFFECT_NAMES.EQUALIZER[equalizerState], equalizerIcon);
}

// Initialize bar index CSS custom properties for spectrum equalizer modes
function initializeEqualizerBarIndices() {
    const equalizer = elements.equalizer;
    if (!equalizer) return;
    
    const bars = equalizer.querySelectorAll('.equalizer-bar');
    bars.forEach((bar, index) => {
        // Set 1-based index (bar 1 to 50)
        bar.style.setProperty('--bar-index', index + 1);
    });
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
    
    // Never show equalizer in screensaver mode (no-playback-active)
    const isScreensaverMode = document.body.classList.contains('no-playback-active');
    if (isScreensaverMode) {
        equalizer.classList.add('hidden');
        // Also remove bass glow effects from album art in screensaver mode
        if (albumArt) {
            albumArt.classList.remove('bass-white-glow', 'bass-color-glow');
        }
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
    if (savedEqualizer && EFFECT_STATES.EQUALIZER.includes(savedEqualizer)) {
        equalizerState = savedEqualizer;
    } else {
        equalizerState = 'off'; // Default to off
    }
    
    // Apply the restored state
    applyEqualizerState();
}

// Cycle through progress effect states
function cycleProgressEffectState() {
    const currentIndex = EFFECT_STATES.PROGRESS.indexOf(progressEffectState);
    const nextIndex = (currentIndex + 1) % EFFECT_STATES.PROGRESS.length;
    progressEffectState = EFFECT_STATES.PROGRESS[nextIndex];
    
    // Save to localStorage
    localStorage.setItem('progressEffectState', progressEffectState);
    
    // Apply the new state
    applyProgressEffectState();
    
    // Show label with effect name
    const progressEffectIcon = document.getElementById('progress-effect-icon');
    showServiceLabel(EFFECT_NAMES.PROGRESS[progressEffectState], progressEffectIcon);
    
    console.log('Progress effect state changed to:', progressEffectState);
}

// Apply current progress effect state
function applyProgressEffectState() {
    const progressEffectIcon = document.getElementById('progress-effect-icon');
    
    if (!progressEffectIcon) return;
    
    // Remove all effect classes
    progressEffectIcon.classList.remove('effect-comet', 'effect-album-comet', 'effect-across-comet', 'effect-sunrise', 'effect-blended-sunrise', 'effect-equalizer-fill');
    
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
        // Hide sunrise
        hideSunriseElement();
        // Turn off equalizer fill
        clearEqualizerFill();
    } else if (progressEffectState === 'album-comet') {
        progressEffectIcon.classList.add('effect-album-comet');
        // Show comet if there's valid progress data
        if (progressState.durationMs > 0 && isPlaying) {
            showProgressComet();
        }
        // Hide sunrise
        hideSunriseElement();
        // Turn off equalizer fill
        clearEqualizerFill();
    } else if (progressEffectState === 'across-comet') {
        progressEffectIcon.classList.add('effect-across-comet');
        // Show comet if there's valid progress data
        if (progressState.durationMs > 0 && isPlaying) {
            showProgressComet();
        }
        // Hide sunrise
        hideSunriseElement();
        // Turn off equalizer fill
        clearEqualizerFill();
    } else if (progressEffectState === 'sunrise') {
        progressEffectIcon.classList.add('effect-sunrise');
        // Hide comet
        hideProgressComet();
        // Show sunrise if there's valid progress data
        if (progressState.durationMs > 0 && isPlaying) {
            showSunriseElement();
        }
        // Turn off equalizer fill
        clearEqualizerFill();
    } else if (progressEffectState === 'blended-sunrise') {
        progressEffectIcon.classList.add('effect-blended-sunrise');
        // Hide comet
        hideProgressComet();
        // Show sunrise if there's valid progress data
        if (progressState.durationMs > 0 && isPlaying) {
            showSunriseElement();
        }
        // Turn off equalizer fill
        clearEqualizerFill();
    } else if (progressEffectState === 'equalizer-fill') {
        progressEffectIcon.classList.add('effect-equalizer-fill');
        // Hide comet and sunrise
        hideProgressComet();
        hideSunriseElement();
        // Enable border-white equalizer and show it
        enableEqualizerFillMode();
    } else {
        // Hide comet and sunrise when effect is off
        hideProgressComet();
        hideSunriseElement();
        // Turn off equalizer fill
        clearEqualizerFill();
    }
}

// Restore progress effect state from localStorage
function restoreProgressEffectState() {
    const savedEffect = localStorage.getItem('progressEffectState');
    if (savedEffect && EFFECT_STATES.PROGRESS.includes(savedEffect)) {
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
        }, CONFIG.CURSOR_HIDE_DELAY);
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
    
    // Initialize equalizer bar indices for CSS custom property calculations
    initializeEqualizerBarIndices();
    
    setupServiceIconHandlers();
    
    // Start background refresh for screensaver images
    startScreensaverRefresh();
    
    connectWebSocket();
    
    // Update URL configuration hint in console
    console.log('WebSocket URL:', WS_URL);
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
        socket.emit('request_current_track');
    } else {
        // Stop all animations when tab is hidden
        if (progressState.animationFrameId) {
            cancelAnimationFrame(progressState.animationFrameId);
        }
        if (sunriseAnimationState.animationFrameId) {
            cancelAnimationFrame(sunriseAnimationState.animationFrameId);
        }
        // Pause CSS animations
        document.body.style.animationPlayState = 'paused';
    }
});

// Handle window resize - update comet and sunrise position to match new screen dimensions
let resizeTimeout;
window.addEventListener('resize', () => {
    // Debounce resize events
    clearTimeout(resizeTimeout);
    resizeTimeout = setTimeout(() => {
        if (progressState.durationMs > 0) {
            // Recalculate comet position with new screen dimensions
            if (elements.progressComet && !elements.progressComet.classList.contains('hidden')) {
                updateProgressComet();
            }
            // Recalculate sunrise position with new screen dimensions
            if (elements.sunriseContainer && !elements.sunriseContainer.classList.contains('hidden')) {
                updateSunriseElement();
            }
        }
    }, 100); // Wait 100ms after resize stops to avoid excessive calculations
});
