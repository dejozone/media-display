import { useEffect, useState } from 'react';
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

  useEffect(() => {
    if (!user || !user.spotifyConnected) return;
    const token = getAuthToken();
    if (!token) return;

    const ws = new WebSocket(`${EVENTS_WS_URL}?token=${token}`);
    setNowLoading(true);

    ws.onopen = () => setNowLoading(false);

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'now_playing') {
          setNowError(null);
          setNowPlaying(msg.data);
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

    ws.onerror = () => {
      setNowError('Live updates unavailable');
      setNowLoading(false);
    };

    ws.onclose = (evt) => {
      if (evt.code === 4401 || evt.code === 4403 || evt.code === 1008) {
        forceLogout('Session expired. Please sign in again.');
      }
    };

    const handleBeforeUnload = () => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.close(1001, 'Page unload');
      }
    };
    window.addEventListener('beforeunload', handleBeforeUnload);

    return () => {
      window.removeEventListener('beforeunload', handleBeforeUnload);
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        ws.close(1001, 'Component unmount');
      }
    };
  }, [user, navigate]);

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

  const statusLabel = (() => {
    const deviceName = nowPlaying?.device?.name?.trim();
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
              <span className="eyebrow">{statusLabel}</span>
              <span className="pill">Live</span>
            </div>
            <div className="np-body">
              {!user?.spotifyConnected ? (
                <p className="hint">Connect Spotify to see Now Playing.</p>
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
                  <div className="artwork" style={{ backgroundImage: `url(${nowPlaying.item.album?.images?.[0]?.url || ''})` }} />
                  <div className="meta">
                    <div className="track-title">{nowPlaying.item.name}</div>
                    <div className="track-artist">{nowPlaying.item.artists?.map((a: any) => a.name).join(', ')}</div>
                    <div className="track-album">{nowPlaying.item.album?.name}</div>
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
