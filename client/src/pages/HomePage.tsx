import { useEffect, useRef, useState } from 'react';
import axios from 'axios';
import { useNavigate } from 'react-router-dom';
import { getAuthToken, clearAuthToken } from '../utils/auth';

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL;
const EVENTS_WS_URL = import.meta.env.VITE_EVENTS_WS_URL || `${window.location.origin.replace(/^http/, 'ws')}/events/media`;

type User = {
  id: string;
  email?: string;
  name?: string;
  provider?: string;
  spotifyConnected?: boolean;
  avatarUrl?: string;
};

export default function HomePage() {
  const navigate = useNavigate();
  const [user, setUser] = useState<User | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [nowPlaying, setNowPlaying] = useState<any>(null);
  const [nowError, setNowError] = useState<string | null>(null);
  const [nowLoading, setNowLoading] = useState(true);
  const [settings, setSettings] = useState<{ spotify_enabled?: boolean; sonos_enabled?: boolean } | null>(null);
  const [settingsSaving, setSettingsSaving] = useState(false);
  const [nowProvider, setNowProvider] = useState<string | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const [wsVersion, setWsVersion] = useState(0);
  const wsRetryTimerRef = useRef<number | null>(null);
  const wsRetryStateRef = useRef<{ start: number; rapidAttempts: number } | null>(null);
  const [liveColor, setLiveColor] = useState<'green' | 'red' | null>(null);
  const [livePulse, setLivePulse] = useState<'green' | 'red' | null>(null);
  const livePulseTimerRef = useRef<number | null>(null);
  const prevSettingsRef = useRef<typeof settings>(null);

  const forceLogout = (message?: string) => {
    clearAuthToken();
    setUser(null);
    setError(message || 'Session expired. Please sign in again.');
    navigate('/');
  };

  useEffect(() => {
    const token = getAuthToken();
    if (!token) {
      navigate('/');
      return;
    }
    const fetchUser = async () => {
      try {
        const res = await axios.get(`${API_BASE_URL}/api/user/me`, {
          headers: { Authorization: `Bearer ${token}` }
        });
        setUser(res.data.user);
        await fetchSettings(token);
        if (res.data.user?.spotifyConnected) {
          await fetchNowPlaying(token);
        } else {
          setNowLoading(false);
        }
      } catch (e: any) {
        const status = e?.response?.status;
        if (status === 401 || status === 403) {
          forceLogout('Session expired. Please sign in again.');
          return;
        }
        setError(e?.response?.data?.error || 'Failed to load user');
        setNowLoading(false);
      } finally {
        setLoading(false);
      }
    };
    fetchUser();
  }, [navigate]);

  // Decide when to (re)connect the WebSocket without disrupting the active provider
  useEffect(() => {
    if (!user || !settings) return;
    const current = wsRef.current;
    const isActive = current && (current.readyState === WebSocket.OPEN || current.readyState === WebSocket.CONNECTING);

    const activeEnabled = (() => {
      if (nowProvider === 'sonos') return settings?.sonos_enabled !== false;
      if (nowProvider === 'spotify') return settings?.spotify_enabled !== false;
      return true;
    })();

    // If no socket or it was closed, trigger a reconnect
    if (!isActive) {
      setWsVersion((v) => v + 1);
      prevSettingsRef.current = settings;
      return;
    }

    // If the currently active provider got disabled, reconnect to allow fallback
    if (!activeEnabled) {
      current.close(1000, 'Switching provider');
      setWsVersion((v) => v + 1);
      prevSettingsRef.current = settings;
      return;
    }

    const prev = prevSettingsRef.current;
    const sonosJustEnabled = prev && prev.sonos_enabled === false && settings.sonos_enabled === true;
    if (nowProvider === 'spotify' && sonosJustEnabled) {
      current.close(1000, 'Preferring sonos after enable');
      setWsVersion((v) => v + 1);
    }

    prevSettingsRef.current = settings;
  }, [user, settings, nowProvider]);

  // Establish the WebSocket when requested by wsVersion
  useEffect(() => {
    if (!user || !settings) return;
    const token = getAuthToken();
    if (!token) return;

    const RAPID_INTERVAL_MS = 2000;
    const RAPID_MAX = 15;
    const COOLDOWN_MS = 5 * 60 * 1000;
    const WINDOW_MS = 28000 * 1000;

    const clearRetryTimer = () => {
      if (wsRetryTimerRef.current !== null) {
        window.clearTimeout(wsRetryTimerRef.current);
        wsRetryTimerRef.current = null;
      }
    };

    const scheduleRetry = (delayMs: number) => {
      clearRetryTimer();
      wsRetryTimerRef.current = window.setTimeout(() => {
        setWsVersion((v) => v + 1);
      }, delayMs);
    };

    const resetRetryState = () => {
      wsRetryStateRef.current = { start: Date.now(), rapidAttempts: 0 };
    };

    const triggerPulse = (color: 'green' | 'red') => {
      setLiveColor(color);
      if (livePulseTimerRef.current !== null) {
        window.clearTimeout(livePulseTimerRef.current);
        livePulseTimerRef.current = null;
      }
      setLivePulse(color);
      livePulseTimerRef.current = window.setTimeout(() => {
        setLivePulse(null);
        livePulseTimerRef.current = null;
      }, 5000);
    };

    if (!wsRetryStateRef.current) {
      resetRetryState();
    }

    const ws = new WebSocket(`${EVENTS_WS_URL}?token=${token}`);
    wsRef.current = ws;
    setNowLoading(true);

    ws.onopen = () => {
      clearRetryTimer();
      resetRetryState();
      triggerPulse('green');
      setNowLoading(false);
      try {
        const poll: Record<string, number> = {};
        if (settings?.spotify_enabled) poll.spotify = 2;
        if (settings?.sonos_enabled === true && false) {
          // intentionally not sending interval for Sonos; change-only mode by design
        }
        if (Object.keys(poll).length > 0) {
          ws.send(JSON.stringify({ type: 'config', poll }));
        }
      } catch (err) {
        // noop
      }
    };

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'now_playing') {
          setNowError(null);
          setNowPlaying(msg.data);
          setNowProvider(msg.provider || null);
          setNowLoading(false);
        } else if (msg.type === 'error') {
          if (msg.code === 401 || msg.code === 403 || msg.error === 'invalid_token') {
            forceLogout('Session expired. Please sign in again.');
            return;
          }
          setNowError(msg.error || 'Live updates unavailable');
          setNowLoading(false);
        }
      } catch (err) {
        setNowError('Live updates unavailable');
        setNowLoading(false);
      }
    };

    const handleRetryableClose = () => {
      const state = wsRetryStateRef.current;
      if (!state) {
        resetRetryState();
        return scheduleRetry(RAPID_INTERVAL_MS);
      }
      const elapsed = Date.now() - state.start;
      if (elapsed >= WINDOW_MS) {
        setNowError('Live updates unavailable');
        setNowLoading(false);
        return;
      }
      if (state.rapidAttempts < RAPID_MAX) {
        wsRetryStateRef.current = { ...state, rapidAttempts: state.rapidAttempts + 1 };
        return scheduleRetry(RAPID_INTERVAL_MS);
      }
      // After rapid attempts, back off to 5 minutes and keep window accounting
      return scheduleRetry(COOLDOWN_MS);
    };

    ws.onerror = () => {
      setNowError('Live updates unavailable');
      setNowLoading(false);
      triggerPulse('red');
      handleRetryableClose();
    };

    ws.onclose = (evt) => {
      if (evt.code === 4401 || evt.code === 4403 || evt.code === 1008) {
        forceLogout('Session expired. Please sign in again.');
        return;
      }
      triggerPulse('red');
      handleRetryableClose();
    };

    const handleBeforeUnload = () => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.close(1000, 'Page unload');
      }
    };
    window.addEventListener('beforeunload', handleBeforeUnload);

    return () => {
      window.removeEventListener('beforeunload', handleBeforeUnload);
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        ws.close(1000, 'Component unmount');
      }
      if (wsRef.current === ws) {
        wsRef.current = null;
      }
      clearRetryTimer();
      if (livePulseTimerRef.current !== null) {
        window.clearTimeout(livePulseTimerRef.current);
        livePulseTimerRef.current = null;
      }
    };
  }, [user, wsVersion]);

  const fetchNowPlaying = async (jwtToken: string) => {
    setNowLoading(true);
    setNowError(null);
    setNowPlaying(null);
    try {
      const res = await axios.get(`${API_BASE_URL}/api/spotify/now-playing`, {
        headers: { Authorization: `Bearer ${jwtToken}` }
      });
      if (!res.data || Object.keys(res.data).length === 0) {
        setNowPlaying(null);
      } else {
        setNowPlaying(res.data);
        setNowProvider('spotify');
      }
    } catch (e: any) {
      const status = e?.response?.status;
      if (status === 401 || status === 403) {
        forceLogout('Session expired. Please sign in again.');
        return;
      }
      const code = e?.response?.data?.code;
      if (code === 'ERR_SPOTIFY_4001') {
        setNowError('ERR_SPOTIFY_4001');
      } else {
        setNowError(e?.response?.data?.error || 'Failed to load Now Playing');
      }
    } finally {
      setNowLoading(false);
    }
  };

  const fetchSettings = async (jwtToken: string) => {
    try {
      const res = await axios.get(`${API_BASE_URL}/api/settings`, {
        headers: { Authorization: `Bearer ${jwtToken}` }
      });
      setSettings(res.data.settings);
    } catch (e: any) {
      setError((prev) => prev || e?.response?.data?.error || 'Failed to load settings');
    }
  };

  const logout = () => {
    clearAuthToken();
    navigate('/');
  };

  const enableSpotify = async () => {
    try {
      const token = getAuthToken();
      const res = await axios.get(`${API_BASE_URL}/api/auth/spotify/url`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {}
      });
      const { url, state } = res.data;
      if (state) {
        localStorage.setItem('oauth_state_spotify', state);
      }
      window.location.href = url;
    } catch (e: any) {
      setError(e?.response?.data?.error || 'Failed to start Spotify login');
    }
  };

  const updateSettings = async (partial: { spotify_enabled?: boolean; sonos_enabled?: boolean }) => {
    const token = getAuthToken();
    if (!token) {
      forceLogout('Session expired. Please sign in again.');
      return;
    }
    setSettingsSaving(true);
    try {
      const res = await axios.put(`${API_BASE_URL}/api/settings`, partial, {
        headers: { Authorization: `Bearer ${token}` }
      });
      setSettings(res.data.settings);
    } catch (e: any) {
      setError(e?.response?.data?.error || 'Failed to update settings');
    } finally {
      setSettingsSaving(false);
    }
  };

  const handleSpotifyToggle = async (next: boolean) => {
    // If turning on and Spotify not connected yet, kick off OAuth flow
    if (next && !user?.spotifyConnected) {
      await enableSpotify();
      return;
    }
    await updateSettings({ spotify_enabled: next });
  };

  const handleSonosToggle = async (next: boolean) => {
    await updateSettings({ sonos_enabled: next });
  };

  if (loading) return <div className="container"><p>Loading…</p></div>;

  const displayName = user?.name || user?.email || 'User';
  const avatarInitial = (displayName || 'U').trim().charAt(0).toUpperCase();
  const spotifyEnabled = !!settings?.spotify_enabled;
  const sonosEnabled = !!settings?.sonos_enabled;
  const sonosGroupDevices =
    nowProvider === 'sonos' && Array.isArray(nowPlaying?.group_devices)
      ? (nowPlaying.group_devices as any[]).filter(Boolean)
      : [];

  const albumText = (() => {
    const album = nowPlaying?.item?.album ?? nowPlaying?.album;
    if (nowProvider === 'sonos') {
      if (typeof album === 'string') return album;
      if (album && typeof album === 'object') {
        return (album as any).name || (album as any).title || '';
      }
      return '';
    }
    // spotify or unknown
    if (album && typeof album === 'object') {
      return (album as any).name || (album as any).title || '';
    }
    if (typeof album === 'string') return album;
    const show = nowPlaying?.item?.show || nowPlaying?.show;
    if (show && typeof show === 'object') {
      return (show as any).name || (show as any).title || '';
    }
    return '';
  })();

  const artistText = (() => {
    const artists = nowPlaying?.item?.artists;
    if (!artists || !Array.isArray(artists)) return '';
    return artists.map((a: any) => (typeof a === 'string' ? a : a?.name)).filter(Boolean).join(', ');
  })();

  const artworkUrl = (() => {
    const pickImage = (images: any) => {
      if (!Array.isArray(images)) return '';
      const firstWithUrl = images.find((img: any) => img?.url);
      return firstWithUrl?.url || '';
    };

    if (!nowPlaying) return '';

    if (nowProvider === 'sonos') {
      return (
        nowPlaying?.item?.album_art_url ||
        nowPlaying?.item?.albumArt ||
        nowPlaying?.item?.album_art ||
        ''
      );
    }

    const album = nowPlaying?.item?.album ?? nowPlaying?.album;
    const fromAlbum = pickImage(album?.images);
    if (fromAlbum) return fromAlbum;

    const fromItem = pickImage(nowPlaying?.item?.images);
    if (fromItem) return fromItem;

    const fromTop = pickImage(nowPlaying?.images);
    if (fromTop) return fromTop;

    return '';
  })();

  const statusLabel = (() => {
    const deviceName = (() => {
      if (nowProvider === 'sonos') {
        if (sonosGroupDevices.length > 1) {
          return `${String(sonosGroupDevices[0]).trim()} +${sonosGroupDevices.length - 1} more`;
        }
        return (sonosGroupDevices[0] || nowPlaying?.device?.name || '').trim();
      }
      return nowPlaying?.device?.name?.trim();
    })();
    const isPlaying = nowPlaying?.is_playing;

    if (isPlaying === true) {
      return deviceName ? `Now Playing on ${deviceName}` : 'Now Playing';
    }

    if (isPlaying === false) {
      return deviceName ? `Paused on ${deviceName}` : 'Paused';
    }

    // Fallback when status is unknown: prefer device context, otherwise default label
    if (deviceName) {
      return `Now Playing on ${deviceName}`;
    }

    // If we have a payload but no status, treat as stopped; else default
    if (nowPlaying && Object.keys(nowPlaying).length > 0) {
      return deviceName ? `Stopped on ${deviceName}` : 'Stopped';
    }

    return 'Now Playing';
  })();

  return (
    <div className="container">
      <div className="shell">
        <header className="app-header">
          <div className="logo">Media Display</div>
          <div className="user-pill">
            <span className="user-name">{displayName}</span>
            {user && (
              <div
                className="avatar"
                style={user.avatarUrl ? { backgroundImage: `url(${user.avatarUrl})` } : undefined}
                aria-label="User avatar"
              >
                {!user.avatarUrl && <span>{avatarInitial}</span>}
              </div>
            )}
            <button onClick={logout} className="chip">Logout</button>
          </div>
        </header>

        <div className="grid">
          <div className="card">
            <h1>Home</h1>
            {user ? (
              <>
                <p>Welcome, {user.name || user.email || user.id}</p>
                <p>Provider: {user.provider}</p>
                <div className="toggle-group">
                  <div className="toggle-row">
                    <span className="toggle-label">Spotify</span>
                    <label className="switch">
                      <input
                        type="checkbox"
                        checked={!!settings?.spotify_enabled}
                        onChange={(e) => handleSpotifyToggle(e.target.checked)}
                        disabled={settingsSaving}
                      />
                      <span className="slider" />
                    </label>
                  </div>
                  <div className="toggle-row">
                    <span className="toggle-label">Sonos</span>
                    <label className="switch">
                      <input
                        type="checkbox"
                        checked={!!settings?.sonos_enabled}
                        onChange={(e) => handleSonosToggle(e.target.checked)}
                        disabled={settingsSaving}
                      />
                      <span className="slider" />
                    </label>
                  </div>
                </div>
              </>
            ) : (
              <p>No user info</p>
            )}
            {error && <p className="error">{error}</p>}
          </div>

          <div className="card now-playing">
            <div className="np-header">
              <span className="eyebrow tooltip-trigger">
                {statusLabel}
                {sonosGroupDevices.length > 0 ? (
                  <span className="tooltip">{sonosGroupDevices.join('\n')}</span>
                ) : null}
              </span>
              <span
                className={`live-dot ${liveColor || ''} ${livePulse ? `pulse` : ''}`.trim()}
                aria-label="Live status"
              />
            </div>
            <div className="np-body">
              {!spotifyEnabled && !sonosEnabled ? (
                <p className="hint">Enable Spotify or Sonos to see Now Playing.</p>
              ) : nowLoading ? (
                <>
                  <div className="artwork placeholder" />
                  <div className="meta">
                    <div className="line thick" />
                    <div className="line" />
                    <div className="line short" />
                  </div>
                </>
              ) : nowError ? (
                <p className="error">{nowError === 'spotify_not_connected_or_token_invalid' || nowError === 'ERR_SPOTIFY_4001' ? 'Connect Spotify to see Now Playing.' : nowError}</p>
              ) : nowPlaying && nowPlaying.item ? (
                <>
                  <div
                    className={`artwork${artworkUrl ? '' : ' placeholder'}`}
                    style={artworkUrl ? { backgroundImage: `url(${artworkUrl})` } : undefined}
                  />
                  <div className="meta">
                    <div className="track-title">{nowPlaying.item.name}</div>
                    <div className="track-artist">{artistText}</div>
                    <div className="track-album">{albumText}</div>
                  </div>
                </>
              ) : (
                <p className="hint">Nothing playing right now.</p>
              )}
            </div>
            {/* <p className="hint">We will display track info from Spotify and Sonos here.</p> */}
          </div>
        </div>
      </div>
    </div>
  );
}
