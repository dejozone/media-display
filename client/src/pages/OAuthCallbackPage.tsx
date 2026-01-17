import { useEffect, useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import axios from 'axios';
import { setAuthToken } from '../utils/auth';

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL;

export default function OAuthCallbackPage() {
  const { provider } = useParams();
  const [search] = useSearchParams();
  const navigate = useNavigate();
  const [message, setMessage] = useState('Completing sign-in…');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const code = search.get('code');
    const state = search.get('state');
    if (!provider || !code) {
      setError('Missing code or provider');
      return;
    }
    // Optional: validate state
    const stored = localStorage.getItem(`oauth_state_${provider}`);
    if (stored && state && stored !== state) {
      setError('State mismatch');
      return;
    }
    const complete = async () => {
      try {
        const res = await axios.get(`${API_BASE_URL}/api/auth/${provider}/callback`, {
          params: { code }
        });
        const token = res.data.jwt;
        if (!token) throw new Error('No token returned');
        setAuthToken(token);
        setMessage('Signed in! Redirecting…');
        localStorage.removeItem(`oauth_state_${provider}`);
        navigate('/home', { replace: true });
      } catch (e: any) {
        setError(e?.response?.data?.error || e.message || 'Login failed');
      }
    };
    complete();
  }, [provider, search, navigate]);

  return (
    <div className="container">
      <div className="card">
        {error ? <p className="error">{error}</p> : <p>{message}</p>}
      </div>
    </div>
  );
}
