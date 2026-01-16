# Progress Updates Bandwidth Optimization

## Overview
The system now implements smart bandwidth optimization that only sends progress updates when clients actually need them. This prevents unnecessary network traffic when no progress effects are active.

## How It Works

### Client-Side ([app.js](../webapp/assets/js/app.js))
- When a progress effect is enabled (`comet`, `album-comet`, `across-comet`, or `equalizer-fill`), the client emits `enable_progress` event to the server
- When progress effect is turned off, the client emits `disable_progress` event to the server  
- Events are sent automatically when toggling progress effects via the UI

### Server-Side ([app.py](../server/app.py))
- Maintains a set `clients_needing_progress` to track which clients need progress updates
- Only polls Sonos/Spotify for position updates when at least one client needs them
- Two event handlers:
  - `@socketio.on('enable_progress')`: Adds client to tracking set
  - `@socketio.on('disable_progress')`: Removes client from tracking set
- Automatic cleanup when clients disconnect

## Implementation Details

### Client Event Emission
```javascript
// In applyProgressEffectState() function
if (socket && socket.connected) {
    if (progressEffectState !== 'off') {
        socket.emit('enable_progress');
        console.log('📊 Requested progress updates from server');
    } else {
        socket.emit('disable_progress');
        console.log('⏸️  Disabled progress updates from server');
    }
}
```

### Server Progress Polling Control
```python
# In poll_position_updates() - Sonos polling
while True:
    if clients_needing_progress:
        # Poll Sonos position
        ...
    time.sleep(2)

# In monitor_loop() - Spotify polling  
if not clients_needing_progress and not major_change:
    # Skip position-only update
    continue
```

### Server Client Tracking
```python
# Global set
clients_needing_progress = set()

# Add client when enabled
@socketio.on('enable_progress')
def handle_enable_progress():
    clients_needing_progress.add(request.sid)
    
# Remove client when disabled
@socketio.on('disable_progress')
def handle_disable_progress():
    clients_needing_progress.discard(request.sid)
    
# Cleanup on disconnect
@socketio.on('disconnect')
def handle_disconnect():
    if client_id in clients_needing_progress:
        clients_needing_progress.discard(client_id)
```

## Benefits
- **Reduced Network Traffic**: No progress updates sent when clients don't need them
- **Lower Server Load**: Polling only occurs when needed
- **Automatic Management**: No manual intervention required
- **Multi-Client Support**: Correctly handles multiple connected clients
- **Clean Shutdown**: Automatic cleanup on client disconnect

## Testing
1. Open the webapp with progress effect OFF
   - Server should show "⏸️  Disabled progress updates from server" 
   - No progress updates in console logs
   
2. Enable any progress effect (comet, album-comet, across-comet, equalizer-fill)
   - Server should show "📊 Requested progress updates from server"
   - Progress updates resume
   
3. Turn progress effect OFF again
   - Server should show "⏸️  Disabled progress updates from server"
   - Progress updates stop

4. Multiple clients scenario
   - First client enables progress → polling starts
   - Second client connects with progress OFF → polling continues
   - First client disables progress → polling continues (second still needs)
   - Second client enables progress → still polling
   - Both clients disable progress → polling stops

## Logging
The server logs progress tracking state changes:
- `✅ Progress updates enabled for client {id}... (Total: X)` - Client enabled progress
- `⏸️  Progress updates disabled for client {id}... (Total: X)` - Client disabled progress
- `📊 Starting progress tracking (client requested)` - First client needs progress
- `📊 Stopping progress tracking (no clients need it)` - Last client stopped needing progress
