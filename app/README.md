# Media Display Flutter Client

Multi-platform Flutter client (web, mobile, desktop) for the Media Display backend.

## Getting started

1. Install Flutter (stable, 3.3+). Enable desktop platforms as needed:
   ```
   flutter config --enable-macos-desktop
   flutter config --enable-windows-desktop
   flutter config --enable-linux-desktop
   flutter config --enable-web
   ```
2. From `app/`, fetch packages and run codegen (none yet):
   ```
   flutter pub get
   ```
3. Configure environment:
   - Copy `assets/env/.env.example` to `assets/env/.env`
   - Set `API_BASE_URL` (default http://localhost:5001) and `WS_BASE_URL` (default ws://localhost:5002/events/media)
4. Run:
   - Web: `flutter run -d chrome`
   - macOS: `flutter run -d macos`
   - Linux: `flutter run -d linux`
   - Windows: `flutter run -d windows`
   - iOS/Android: `flutter run -d ios` / `flutter run -d android`

## Project layout
- `lib/main.dart` — entry point
- `lib/src/app.dart` — app shell and theme
- `lib/src/config/env.dart` — env/config provider (dotenv)
- `lib/src/routing/router.dart` — go_router routes
- `lib/src/services/` — API/auth/token helpers
- `lib/src/features/` — screens (auth, home, account stubs)

## Next steps
- Implement actual OAuth launching (url_launcher) and token handling per platform.
- Flesh out Home/Account screens with now-playing, toggles, avatar upload, and websocket handling.
- Add websocket service for live events with backoff similar to React app.
- Add tests and CI for web + desktop targets.
