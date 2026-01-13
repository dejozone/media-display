# Now Playing Display

A full-screen display for music playback with real-time updates. Supports Sonos API (no authentication required) and Spotify Connect as fallback.

## Project Structure

```
media-display/
├── server/          # Backend WebSocket server
│   ├── .env         # Environment variables (ENV, credentials)
│   ├── app.py       # Main server application
│   ├── config.py    # Configuration management
│   ├── requirements.txt
│   ├── start.sh     # Server startup script
│   ├── gunicorn_config.py
│   ├── conf/        # Environment-specific configs
│   │   ├── dev.json
│   │   └── prod.json
│   └── lib/         # Server modules
│       ├── app_state.py
│       ├── auth/    # Spotify authentication
│       ├── monitors/  # Sonos & Spotify monitors
│       └── utils/   # Utilities (logger, network, time)
├── webapp/          # Frontend web application
│   ├── .env         # Environment variables (ENV)
│   ├── index.html   # Main HTML file
│   ├── server.py    # Development server
│   ├── start.sh     # Webapp startup script
│   ├── requirements.txt
│   ├── gunicorn_config.py
│   ├── conf/        # Environment-specific configs
│   │   ├── dev.json
│   │   └── prod.json
│   └── assets/      # Static assets (organized structure)
│       ├── css/
│       │   └── styles.css      # Styling
│       ├── js/
│       │   └── app.js          # WebSocket client & display logic
│       └── images/
│           └── screensavers/   # Screensaver images
├── test/            # Test scripts
│   ├── spotify_connect_test.py
│   ├── run_test.sh
│   └── requirements.txt
├── start-all.sh     # Unified startup script
└── stop-all.sh      # Unified stop script
```

## Quick Start

### 1. Configure Environment Variables

Create a `server/.env` file:

```bash
# Environment type: "dev" for dev.json file, "local" or "prod".
ENV=dev
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
```

Create a `webapp/.env` file:

```bash
# Environment type: "dev" for dev.json file, "local" or "prod".
ENV=dev
```

### 2. Install Dependencies

```bash
# Install server dependencies
cd server
pip install -r requirements.txt
```

### 3. Start the Services

#### Option A: Start All Services (Recommended)

Use the unified startup script to start both server and webapp:

```bash
./start-all.sh
```

This will:
1. **Start the Spotify Server**:
   - Clean up any existing processes on required ports
   - Launch the WebSocket server on port 5001
   - Attempt to connect using Sonos API (local network, no authentication)
   - If Sonos not available or `MEDIA_SERVICE_METHOD=spotify`, use Spotify Connect:
     - Start OAuth callback server on port 8888
     - Open browser for Spotify authorization (first time only)
     - Check if existing credentials are valid
   - Wait for server to be fully ready

2. **Start the Web Application**:
   - Launch the webapp using Gunicorn (production-ready)
   - Available at `http://localhost:8081`
   - Wait for webapp to be fully ready

3. **Open Browser**:
   - Automatically open the webapp in your default browser
   - Display will connect to the WebSocket server automatically

4. **Keep Services Running**:
   - Press `Ctrl+C` to stop all services
   - Logs are written to `server.log` and `webapp.log`

**Systemd Mode**: For running as a system service, use `./start-all.sh --systemd`

#### Option B: Start Services Manually

If you need more control, start each service separately:

**Terminal 1 - Backend Server:**
```bash
cd server
./start.sh --gunicorn
```

**Terminal 2 - Web Application:**
```bash
cd webapp
./start.sh --gunicorn
```

Then open your browser to `http://localhost:8081`

### 4. Stop the Services

To stop all running services:

```bash
./stop-all.sh
```

This will:
- Stop the Spotify Server (port 5001)
- Stop the Web Application (port 8081)
- Clean up all related processes

**Note**: The stop script automatically finds and terminates processes using the configured ports, so you don't need to track PIDs manually.

### 5. Using the Display

Once started, the display will:
- Connect to the WebSocket server automatically
- Show current playback in full-screen
- Update in real-time when tracks change
- Display screensaver with custom images when no music is playing

## Features

### Core Playback
- **Dual Service Support**: 
  - **Sonos API** (Primary): Local network integration, no authentication required
  - **Spotify Connect** (Fallback): OAuth-based, works with any Spotify device
- **Real-time Updates**: Event-based updates for Sonos, 2-second polling for Spotify
- **Full-screen Display**: Optimized for dedicated displays
- **Responsive Design**: Works in both portrait and landscape
- **Dynamic Background**: Album art colors extracted for immersive display
- **Adaptive Text**: Automatically adjusts text color based on background luminance
- **Image Optimization**: Automatically fills containers regardless of image aspect ratio

### Visual Effects
- **Glow Effects** (Toggleable):
  - **Off**: No glow effect (default)
  - **Colors**: Rainbow color cycling (30s cycle for album art, 8s for screensaver)
  - **White**: Gentle white glow animation
  - **Fast White**: Rapid white glow animation
  - **Fast Colors**: Rapid rainbow color cycling
  - **Album Colors**: Glow colors extracted from album art
  - **Fast Album Colors**: Rapid album color glow cycling
  - Persisted across sessions via localStorage
  - Click light bulb icon to cycle through modes

- **Equalizer Effects** (Toggleable):
  - **Off**: No equalizer bars (default)
  - **Normal**: Animated bars with no glow
  - **White Border**: White bordered bars
  - **White**: White glowing bars
  - **Navy**: Navy blue bars
  - **Blue Spectrum**: Blue gradient spectrum
  - **Colors**: Rainbow colored bars
  - **Color Spectrum**: Full color spectrum animation
  - **Fast White Album Glow**: Fast bass-reactive white glow on album art
  - **Fast Color Album Glow**: Fast bass-reactive color glow on album art
  - Automatically shows during playback, hides when paused
  - Persisted across sessions via localStorage
  - Click equalizer icon to cycle through modes

- **Progress Effects** (Toggleable):
  - **Off**: No progress visualization (default)
  - **Edge Comet**: Animated comet traveling around screen edges
  - **Album Comet**: Comet traveling around album art border
  - **Across Comet**: Comet traveling horizontally along bottom
  - **Sunrise & Sunset**: Animated sun rising/setting with dynamic sky colors, stars at night, and mountain silhouette with reactive lighting
  - **Blended Sunrise & Sunset**: Same as Sunrise & Sunset but mountain colors blend with album art background
  - **Equalizer Fill**: Progressively fills equalizer bars as song plays
  - All effects complete at 98% of song duration for smooth transitions
  - Persisted across sessions via localStorage
  - Click progress effect icon to cycle through modes

- **Screensaver Mode**: When no music is playing
  - Cycles through custom images every 30 seconds with fade transitions
  - Animated background color cycling
  - Glow effects apply to screensaver images

### Display Controls
- **Rotation Control**: Click rotation icon to rotate display counter-clockwise by 90°
  - Supports 0°, 90°, 180°, 270° orientations
  - Perfect for wall-mounted displays
  - All visual effects automatically adjust to rotated orientation
  - Setting persisted across sessions
- **Settings Panel**: Expandable settings with auto-collapse after 5 seconds
  - Service status indicators (Sonos/Spotify)
  - Playback status (play/pause) with device information
  - Glow effect toggle with effect name display
  - Equalizer effect toggle with effect name display
  - Progress effect toggle with effect name display
  - Display rotation control
  - Fullscreen toggle

### Connection Management
- **Auto-reconnect**: Handles connection drops gracefully
- **Visual Connection Status**: Border glow indicates connection state
  - Pink/blue glow: Connecting/disconnected
  - Green glow: Connected (fades after 10 seconds)
- **Service Indicators**: Visual icons show which service is active

## Service Method Configuration

The `MEDIA_SERVICE_METHOD` environment variable controls which service to use:

### `all` (Default)
- Tries Sonos API first (no authentication required)
- Falls back to Spotify Connect if Sonos not available
- Best for mixed environments

### `sonos`
- Uses Sonos API only
- Requires Sonos speakers on local network
- No authentication needed
- Event-based real-time updates

### `spotify`
- Uses Spotify Connect only
- Requires Spotify OAuth authentication
- Works with any Spotify device
- 2-second polling for updates

## Display Controls

### Keyboard Shortcuts
- **Double-click**: Toggle fullscreen
- **F key**: Toggle fullscreen
- **ESC**: Exit fullscreen

### Interactive Elements
- **Settings Icon** (gear): Expand/collapse settings panel
- **Light Bulb Icon**: Cycle through glow effects
  - Displays current effect name on hover/click
  - 7 modes: Off → Colors → White → Fast White → Fast Colors → Album Colors → Fast Album Colors
- **Equalizer Icon**: Cycle through equalizer effects
  - Displays current effect name on hover/click
  - 10 modes: Off → Normal → White Border → White → Navy → Blue Spectrum → Colors → Color Spectrum → Fast White Album Glow → Fast Color Album Glow
- **Progress Effect Icon**: Cycle through progress visualization effects
  - Displays current effect name on hover/click
  - 7 modes: Off → Edge Comet → Album Comet → Across Comet → Sunrise & Sunset → Blended Sunrise & Sunset → Equalizer Fill
- **Rotation Icon**: Rotate display counter-clockwise by 90°
- **Fullscreen Icon**: Toggle fullscreen mode
- **Play/Pause Icon**: Shows current playback state
- **Service Icons** (Sonos/Spotify): Click to view service details
- **Device Name**: Click or hover to view all connected devices
- **Album Art**: Hover to view album name

### Settings Panel Behavior
- Expands when clicking settings icon
- Auto-collapses after 5 seconds of inactivity
- Clicking any icon resets the 5-second timer
- Click outside panel to close immediately

## Production Deployment

### Backend Server

The server can run on any machine with Python. For production:

1. Use a process manager like `systemd` or `supervisor`
2. Configure firewall to allow WebSocket port (5001)
3. Set `SERVER_HOST=0.0.0.0` to allow external connections
4. For Sonos mode: Ensure server is on same local network as Sonos devices
6. For Spotify mode: Configure OAuth credentials in `server/.env`
6. Set `MEDIA_SERVICE_METHOD` based on your environment

### Frontend Web App

The webapp is static HTML/CSS/JS and can be served by any web server:

#### Using Nginx

```nginx
server {
    listen 80;
    server_name yourdomain.com;
    
    root /path/to/media-display/webapp;
    index index.html;
    
    location / {
        try_files $uri $uri/ =404;
    }
}
```

#### Update WebSocket URL

Edit `webapp/assets/js/app.js` line 2-4 to point to your production server:

```javascript
const WEBSOCKET_URL = window.location.hostname === 'localhost' 
    ? 'http://localhost:5001' 
    : 'https://your-server-domain.com:5001';
```

#### Add Screensaver Images

Place your custom screensaver images in `webapp/assets/images/screensavers/` and update the `screensaverImages` array in `webapp/assets/js/app.js` (lines 22-37).

## Configuration

### Server Configuration (`server/conf/dev.json`)

The server uses environment-specific JSON configuration files. All timing values are in seconds unless otherwise noted.

#### Service Configuration
- **`svcMethod`**: Service method to use (`"sonos"`, `"spotify"`, or `"all"`)
  - `"sonos"` - Use Sonos API only
  - `"spotify"` - Use Spotify Connect only  
  - `"all"` - Try Sonos first, fallback to Spotify (default)

- **`localCallbackSrvPort`**: Port for OAuth callback server (default: `8888`)
  - Used during Spotify authentication flow
  - Must match the redirect URI in Spotify app settings

#### Service Recovery
- **`svcRecoveryWindowTime`**: Maximum time window for service recovery attempts in seconds (default: `129600` = 36 hours)
  - After this period, server stops trying to recover failed services

- **`svcRecoveryRetryInterval`**: Interval between service recovery retry attempts in seconds (default: `15`)
  - How often to retry starting a failed service

- **`svcRecoveryInitDelay`**: Initial delay before first service recovery attempt in seconds (default: `15`)
  - Prevents immediate retry on startup failure

#### Logging
- **`logging.level`**: Log verbosity level (`"debug"`, `"info"`, `"warning"`, `"error"`, `"critical"`)
  - `"debug"` - Detailed diagnostic information
  - `"info"` - General informational messages (default)
  - `"warning"` - Warning messages
  - `"error"` - Error messages only
  - `"critical"` - Critical errors only

#### WebSocket Configuration
- **`websocket.serverPort`**: WebSocket server port (default: `5001`)
  - Port where clients connect for real-time updates

- **`websocket.subPath`**: WebSocket endpoint path (default: `"/socket.io"`)
  - Used for nginx subpath proxying (e.g., `"/notis/media-display/socket.io"`)

#### Sonos Configuration
- **`sonos.checkTakeoverInterval`**: Interval for checking if Sonos should take over from lower-priority sources in seconds (default: `2`)
  - How often to poll Sonos devices for playback state
  - Also used for position updates when clients need progress

- **`sonos.stopHeartBeatTimeNoPlayback`**: Minimum time before sending heartbeat updates to keep timestamp fresh in seconds (default: `8`)
  - Prevents other sources from thinking Sonos is stale during playback
  - Heartbeat only sent when events are active and no clients need progress updates

#### Spotify Configuration
- **`spotify.takeoverWaitTime`**: Time to wait before Spotify takes over from stale higher-priority source in seconds (default: `10`)
  - Prevents flapping during brief Sonos pauses/buffering
  - Lower values (3-5s) = more responsive but may cause brief source switches
  - Higher values (10s+) = more stable but slower to respond to source changes

- **`spotify.api.sslCertVerification`**: Enable/disable SSL certificate verification for Spotify API calls (default: `true`)
  - Set to `false` for development with self-signed certificates
  - Should be `true` in production

- **`spotify.api.callbackRedirRootUrl`**: OAuth callback URL for Spotify authentication
  - Must match the redirect URI configured in your Spotify app settings
  - Example: `"https://media-display.projecttechcycle-dev.org:9080/spotify/callback"`

- **`spotify.api.scope`**: OAuth scopes requested from Spotify (default: `"user-read-currently-playing user-read-playback-state"`)
  - Required scopes for reading playback information
  - Should not be changed unless additional API features are added

### Web Application Configuration (`webapp/conf/dev.json`)

The web application uses a simple configuration file for server settings.

#### Server Configuration
- **`server.port`**: Port for the web application server (default: `8081`)
  - Where the webapp will be accessible (e.g., `http://localhost:8081`)

- **`server.sendFileCacheMaxAge`**: Cache duration for static files in seconds (default: `86400` = 24 hours)
  - How long browsers should cache CSS/JS/image files
  - Longer durations improve performance but may require cache clearing after updates

- **`server.dirListingCacheMaxAge`**: Cache duration for directory listings in seconds (default: `3600` = 1 hour)
  - How long to cache file listing responses (e.g., screensaver image lists)
  - Shorter duration ensures new images are discovered more quickly

### Environment Variables (`server/.env`)

These are loaded before the JSON configuration and contain sensitive credentials:

- **`ENV`**: Environment name (`"dev"` or `"prod"`) - determines which JSON config file to load
- **`SPOTIFY_CLIENT_ID`**: Spotify app client ID (required for Spotify mode)
- **`SPOTIFY_CLIENT_SECRET`**: Spotify app client secret (required for Spotify mode)

### Environment Variables (`webapp/.env`)

The webapp requires a simple environment file:

- **`ENV`**: Environment name (`"dev"` or `"prod"`) - determines which JSON config file to load from `webapp/conf/`

## User Preferences

The following settings are automatically saved to the browser's localStorage and persist across sessions:

- **Display Rotation**: Current rotation angle (0°, 90°, 180°, 270°)
- **Glow Effect**: Current glow mode (7 modes available)
- **Equalizer Effect**: Current equalizer style (10 modes available)
- **Progress Effect**: Current progress visualization (7 modes available)

These settings are device-specific and stored in the browser. To reset preferences, clear the browser's localStorage or use developer tools.

## Architecture

### Sonos Mode (Primary)
1. **Server** discovers Sonos devices via mDNS/Zeroconf
2. Subscribes to UPnP AVTransport events for real-time updates
3. When track changes, server broadcasts via WebSocket to all connected clients
4. **Web app** receives updates and displays track info with album art
5. No authentication required, works on local network only

### Spotify Mode (Fallback)
1. **Server** monitors Spotify API every 2 seconds
2. When track changes, server broadcasts via WebSocket to all connected clients
3. **Web app** receives updates and displays track info with album art
4. Works with ANY Spotify device on the same account
5. Requires OAuth authentication

## API Endpoints

### WebSocket Events

**Client → Server:**
- `request_current_track` - Request current track info

**Server → Client:**
- `track_update` - Track information update

**Track Data Format:**
```json
{
  "track_id": "...",
  "track_name": "Song Name",
  "artist": "Artist Name",
  "album": "Album Name",
  "album_art": "https://...",
  "is_playing": true,
  "progress_ms": 45000,
  "duration_ms": 180000,
  "device": {
    "name": "Device Name",
    "type": "Speaker"
  }
}
```

### HTTP Endpoints

- `GET /` - Server info page
- `GET /health` - Health check endpoint

## Troubleshooting

### Server won't start
- Check `server/.env` file has correct Spotify credentials
- Ensure port 8888 is not in use by another application
- Verify nginx is proxying callback URL correctly

### Web app can't connect
- Ensure server is running on port 5000
- Check firewall allows WebSocket connections
- Update `WEBSOCKET_URL` in `app.js` if server is on different machine

### No track updates
- **Sonos mode**: Ensure Sonos devices are on same network and playing
- **Spotify mode**: Play music on any Spotify device
- Check server logs for errors
- Verify `MEDIA_SERVICE_METHOD` is set correctly
- For Sonos: Check that `soco` library is installed (`pip install soco`)
- For Spotify: Verify Spotify account has active playback

## License

MIT
