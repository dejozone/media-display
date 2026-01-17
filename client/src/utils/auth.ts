import { jwtDecode } from 'jwt-decode';

const TOKEN_KEY = 'media_display_jwt';

type JwtPayload = { exp?: number };

export function setAuthToken(token: string) {
  localStorage.setItem(TOKEN_KEY, token);
}

export function getAuthToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function clearAuthToken() {
  localStorage.removeItem(TOKEN_KEY);
}

export function isAuthenticated(): boolean {
  const token = getAuthToken();
  if (!token) return false;
  try {
    const { exp } = jwtDecode<JwtPayload>(token);
    if (!exp) return true;
    const now = Math.floor(Date.now() / 1000);
    return exp > now;
  } catch (err) {
    return false;
  }
}
