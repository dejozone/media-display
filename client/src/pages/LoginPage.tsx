import { useState } from 'react';
import axios from 'axios';
import { useNavigate } from 'react-router-dom';

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL;

export default function LoginPage() {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const startGoogleLogin = async () => {
    if (!API_BASE_URL) {
      setError('API base URL not configured');
      return;
    }
    setLoading(true);
    setError(null);
    try {
      // We expect backend to provide an auth URL (optional state server-side)
      const res = await axios.get(`${API_BASE_URL}/api/auth/google/url`);
      const { url, state } = res.data;
      if (state) {
        localStorage.setItem('oauth_state_google', state);
      }
      window.location.href = url;
    } catch (e: any) {
      setError(e?.response?.data?.error || 'Failed to start Google login');
      setLoading(false);
    }
  };

  const startSpotifyLogin = async () => {
    if (!API_BASE_URL) {
      setError('API base URL not configured');
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const res = await axios.get(`${API_BASE_URL}/api/auth/spotify/url`);
      const { url, state } = res.data;
      if (state) {
        localStorage.setItem('oauth_state_spotify', state);
      }
      window.location.href = url;
    } catch (e: any) {
      setError(e?.response?.data?.error || 'Failed to start Spotify login');
      setLoading(false);
    }
  };

  return (
    <div className="container">
      <div className="card">
        <h1>Media Display Login</h1>
        <p>Sign in with Google to continue.</p>
        <button onClick={startGoogleLogin} disabled={loading} className="primary">
          {loading ? 'Redirecting…' : 'Login with Google'}
        </button>
        <hr />
        <p>Already logged in? Go to home.</p>
        <button onClick={() => navigate('/home')} className="secondary">Go to Home</button>
        {error && <p className="error">{error}</p>}
        <div className="hint">Spotify can be enabled from Home after login.</div>
        <button onClick={startSpotifyLogin} disabled={loading} className="ghost">
          {loading ? 'Redirecting…' : 'Enable Spotify (login)'}
        </button>
      </div>
    </div>
  );
}
