# Now Playing Display

A full-screen display for music playback with real-time updates. Supports Sonos API (no authentication required) and Spotify Connect as fallback.

## Project Structure

```
media-display/
├── server/          # Backend WebSocket server
│   ├── app.py       # Main server application
│   ├── requirements.txt
│   └── start.sh     # Server startup script
├── webapp/          # Frontend web application
│   ├── index.html   # Main HTML file
│   ├── server.py    # Development server
│   ├── start.sh     # Webapp startup script
│   └── assets/      # Static assets (organized structure)
│       ├── css/
│       │   └── styles.css      # Styling
│       ├── js/
│       │   └── app.js          # WebSocket client & display logic
│       └── images/
│           └── screensavers/   # Screensaver images
└── test/            # Test scripts
    ├── spotify_connect_test.py
    ├── run_test.sh
    ├── requirements.txt
```

## Quick Start

### 1. Configure Environment Variables

Create a `.env` file in the root directory:

```bash
# Service Method Configuration (optional)
# Options: 'sonos', 'spotify', 'all'
# 'sonos' - Use Sonos API only (no authentication)
# 'spotify' - Use Spotify Connect only (requires OAuth)
# 'all' - Try Sonos first, fallback to Spotify (default)
MEDIA_SERVICE_METHOD=all

# Spotify Configuration (required for spotify/all modes)
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
SPOTIFY_REDIRECT_URI=https://media.projecttechcycle-dev.org:9080/callback
LOCAL_CALLBACK_PORT=8888

# Server Configuration
SERVER_HOST=0.0.0.0
SERVER_PORT=5001
WEBAPP_PORT=8080
```

### 2. Install Dependencies

```bash
# Install server dependencies
cd server
pip install -r requirements.txt
```

### 3. Start the Backend Server

```bash
cd server
./start.sh
```

The server will:
- Attempt to connect using Sonos API (local network, no authentication)
- If Sonos not available or MEDIA_SERVICE_METHOD=spotify, use Spotify Connect:
  - Start OAuth callback server on port 8888
  - Open browser for Spotify authorization (first time only)
- Start WebSocket server on port 5001
- Monitor playback and broadcast updates

### 4. Start the Web App (Development)

In a new terminal:

```bash
cd webapp
./start.sh
```

The webapp will be available at: `http://localhost:8081`

### 5. Open the Display

Open your browser to `http://localhost:8081` and the display will:
- Connect to the WebSocket server automatically
- Show current playback in full-screen
- Update in real-time when tracks change

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
5. For Spotify mode: Configure OAuth credentials in `.env`
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
- Check `.env` file has correct Spotify credentials
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
