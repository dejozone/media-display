import { Navigate } from 'react-router-dom';
import { isAuthenticated } from '../utils/auth';

export default function PrivateRoute({ children }: { children: React.ReactElement }) {
  return isAuthenticated() ? children : <Navigate to="/" replace />;
}
