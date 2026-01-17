import { useEffect, useState } from 'react';
import axios from 'axios';
import { useNavigate } from 'react-router-dom';
import { getAuthToken, clearAuthToken } from '../utils/auth';

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL;

type User = {
  id: string;
  email?: string;
  name?: string;
  provider?: string;
};

export default function HomePage() {
  const navigate = useNavigate();
  const [user, setUser] = useState<User | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

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
      } catch (e: any) {
        setError(e?.response?.data?.error || 'Failed to load user');
      } finally {
        setLoading(false);
      }
    };
    fetchUser();
  }, [navigate]);

  const logout = () => {
    clearAuthToken();
    navigate('/');
  };

  const enableSpotify = async () => {
    try {
      const res = await axios.get(`${API_BASE_URL}/api/auth/spotify/url`);
      const { url, state } = res.data;
      if (state) {
        localStorage.setItem('oauth_state_spotify', state);
      }
      window.location.href = url;
    } catch (e: any) {
      setError(e?.response?.data?.error || 'Failed to start Spotify login');
    }
  };

  if (loading) return <div className="container"><p>Loading…</p></div>;

  return (
    <div className="container">
      <div className="shell">
        <header className="app-header">
          <div className="logo">Media Display</div>
          <div className="user-pill">
            <span>{user?.name || user?.email || 'User'}</span>
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
                <div className="actions">
                  {user.provider !== 'spotify' && (
                    <button onClick={enableSpotify} className="primary">Enable Spotify</button>
                  )}
                  <button onClick={logout} className="secondary">Logout</button>
                </div>
              </>
            ) : (
              <p>No user info</p>
            )}
            {error && <p className="error">{error}</p>}
          </div>

          <div className="card now-playing">
            <div className="np-header">
              <span className="eyebrow">Now Playing</span>
              <span className="pill">Coming soon</span>
            </div>
            <div className="np-body">
              <div className="artwork placeholder" />
              <div className="meta">
                <div className="line thick" />
                <div className="line" />
                <div className="line short" />
              </div>
            </div>
            <p className="hint">We will display track info from Spotify and Sonos here.</p>
          </div>
        </div>
      </div>
    </div>
  );
}
