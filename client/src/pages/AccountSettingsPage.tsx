import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';
import { clearAuthToken, getAuthToken } from '../utils/auth';
import { validateEmail, validateUsername, validateDisplayName, validateImageFile } from '../utils/validation';
import Cropper, { Area } from 'react-easy-crop';
import heic2any from 'heic2any';

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL;
const FALLBACK_AVATAR = 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64" fill="none"><circle cx="32" cy="32" r="32" fill="%23e5e7eb"/><circle cx="32" cy="26" r="10" fill="%2394a3b8"/><path d="M16 54c4-8 12-12 16-12s12 4 16 12" stroke="%2394a3b8" stroke-width="4" stroke-linecap="round"/></svg>';

type AccountUser = {
  id: string;
  email?: string;
  username?: string;
  display_name?: string;
  avatar_url?: string | null;
  provider_avatars?: Record<string, string | null>;
  provider_avatar_list?: ProviderAvatar[];
  provider_selected?: string | null;
  provider?: string | null;
};

type ProviderAvatar = {
  provider: string;
  provider_id?: string;
  avatar_url?: string | null;
  is_selected?: boolean;
};

type ApiUser = {
  user: AccountUser;
};

export default function AccountSettingsPage() {
  const navigate = useNavigate();
  const [user, setUser] = useState<AccountUser | null>(null);
  const [email, setEmail] = useState('');
  const [username, setUsername] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [selectedAvatar, setSelectedAvatar] = useState<string | null>(null);
  const [selectedProvider, setSelectedProvider] = useState<string | null>(null);
  const [providerAvatars, setProviderAvatars] = useState<ProviderAvatar[]>([]);
  const [customAvatar, setCustomAvatar] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [avatarSaving, setAvatarSaving] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [cropImage, setCropImage] = useState<string | null>(null);
  const [showCropper, setShowCropper] = useState(false);
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [croppedAreaPixels, setCroppedAreaPixels] = useState<Area | null>(null);
  const [targetFormat, setTargetFormat] = useState<'image/jpeg' | 'image/png'>('image/jpeg');
  const [targetExt, setTargetExt] = useState<'jpg' | 'png'>('jpg');
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const currentSelectedProvider = () => {
    return selectedProvider
      || providerAvatars.find((p) => p.is_selected)?.provider
      || null;
  };

  const forceLogout = (message?: string) => {
    clearAuthToken();
    navigate('/', { replace: true, state: { message: message || 'Session expired. Please sign in again.' } });
  };

  const initialAvatarSource = useMemo(() => {
    const selectedFromProvider = providerAvatars.find((p) => p.is_selected)?.avatar_url;
    if (selectedAvatar !== null) return selectedAvatar || selectedFromProvider || null;
    if (selectedFromProvider) return selectedFromProvider;
    return providerAvatars.find((p) => p.avatar_url)?.avatar_url || user?.avatar_url || null;
  }, [providerAvatars, selectedAvatar, user?.avatar_url]);

  const resetMessages = () => {
    setError(null);
    setSuccess(null);
  };

  const loadImage = (src: string): Promise<HTMLImageElement> =>
    new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('Failed to load image'));
      img.src = src;
    });

  const openCropper = () => {
    setShowCropper(true);
    setSuccess(null);
  };

  const closeCropper = () => {
    if (cropImage) {
      URL.revokeObjectURL(cropImage);
    }
    setShowCropper(false);
    setCropImage(null);
    setCroppedAreaPixels(null);
    setUploading(false);
  };

  const handleFileInput = async (file?: File | null) => {
    resetMessages();
    const result = validateImageFile(file);
    if (result.error || !result.targetFormat || !result.targetExt) {
      setError(result.error || 'Unsupported file');
      return;
    }

    setTargetFormat(result.targetFormat);
    setTargetExt(result.targetExt);

    let workingBlob: Blob = file;
    if (result.isHeic) {
      try {
        const converted = await heic2any({ blob: file, toType: 'image/jpeg', quality: 0.95 });
        workingBlob = Array.isArray(converted) ? converted[0] : converted;
        setTargetFormat('image/jpeg');
        setTargetExt('jpg');
      } catch (err) {
        setError('Failed to convert HEIC/HEIF image. Try another file.');
        return;
      }
    }

    try {
      const objectUrl = URL.createObjectURL(workingBlob);
      // Validate the image can be loaded before showing the cropper
      await loadImage(objectUrl);
      setCropImage(objectUrl);
      setCrop({ x: 0, y: 0 });
      setZoom(1);
      openCropper();
    } catch (err) {
      setError('Could not read the selected image.');
    }
  };

  const onCropComplete = useCallback((_: Area, cropped: Area) => {
    setCroppedAreaPixels(cropped);
  }, []);

  const getCroppedBlob = useCallback(async (): Promise<Blob> => {
    if (!cropImage || !croppedAreaPixels) {
      throw new Error('Crop area not ready');
    }
    // Always produce a 200x200 image client-side before upload
    const image = await loadImage(cropImage);
    const canvas = document.createElement('canvas');
    const size = 200;
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('Canvas unavailable');

    const { x, y, width, height } = croppedAreaPixels;
    ctx.drawImage(image, x, y, width, height, 0, 0, size, size);

    return new Promise<Blob>((resolve, reject) => {
      canvas.toBlob((blob) => {
        if (blob) resolve(blob);
        else reject(new Error('Failed to create image blob'));
      }, targetFormat, targetFormat === 'image/jpeg' ? 0.9 : undefined);
    });
  }, [cropImage, croppedAreaPixels, targetFormat]);

  const uploadCroppedAvatar = useCallback(async () => {
    const token = getAuthToken();
    if (!token) {
      forceLogout('Session expired. Please sign in again.');
      return;
    }
    if (!croppedAreaPixels || !cropImage) {
      setError('Select a crop area before uploading.');
      return;
    }
    setUploading(true);
    setError(null);
    setSuccess(null);
    try {
      const blob = await getCroppedBlob();
      const formData = new FormData();
      formData.append('file', blob, `avatar.${targetExt}`);
      const res = await axios.post<{ avatar_url: string }>(`${API_BASE_URL}/api/account/avatar`, formData, {
        headers: { Authorization: `Bearer ${token}` }
      });
      const finalUrl = res.data.avatar_url;
      setSelectedAvatar(finalUrl);
      setSelectedProvider(currentSelectedProvider());
      setCustomAvatar(finalUrl);
      setUser((prev) => (prev ? { ...prev, avatar_url: finalUrl } : prev));
      setSuccess('Avatar updated');
      closeCropper();
    } catch (e: any) {
      const status = e?.response?.status;
      if (status === 401 || status === 403) {
        forceLogout('Session expired. Please sign in again.');
        return;
      }
      setError(e?.response?.data?.error || 'Failed to upload avatar');
    } finally {
      setUploading(false);
    }
  }, [cropImage, croppedAreaPixels, forceLogout, getCroppedBlob, currentSelectedProvider]);

  useEffect(() => {
    const token = getAuthToken();
    if (!token) {
      forceLogout();
      return;
    }
    const fetchAccount = async () => {
      setLoading(true);
      setError(null);
      try {
        const res = await axios.get<ApiUser>(`${API_BASE_URL}/api/account`, {
          headers: { Authorization: `Bearer ${token}` }
        });
        const account = res.data.user;
        setUser(account);
        setEmail(account.email || '');
        setUsername(account.username || '');
        setDisplayName(account.display_name || '');
        setProviderAvatars(account.provider_avatar_list || []);
        const providerSelected = account.provider_selected || account.provider || null;
        setSelectedProvider(providerSelected);
        const selectedFromProvider = (account.provider_avatar_list || []).find((p) => p.is_selected)?.avatar_url;
        const avatar = account.avatar_url || selectedFromProvider || null;
        setSelectedAvatar(avatar);
        setCustomAvatar(avatar || '');
      } catch (e: any) {
        const status = e?.response?.status;
        if (status === 401 || status === 403) {
          forceLogout('Session expired. Please sign in again.');
          return;
        }
        setError(e?.response?.data?.error || 'Failed to load account');
      } finally {
        setLoading(false);
      }
    };
    fetchAccount();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => () => {
    if (cropImage) {
      URL.revokeObjectURL(cropImage);
    }
  }, [cropImage]);

  const handleSave = async () => {
    const token = getAuthToken();
    if (!token) {
      forceLogout('Session expired. Please sign in again.');
      return;
    }
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const emailError = validateEmail(email);
      const usernameError = validateUsername(username);
      const displayNameError = validateDisplayName(displayName);
      const firstError = emailError || usernameError || displayNameError;
      if (firstError) {
        setError(firstError);
        setSaving(false);
        return;
      }
      const payload: Record<string, any> = {
        email: email || null,
        username: username || null,
        display_name: displayName || null,
      };
      const res = await axios.put<ApiUser>(`${API_BASE_URL}/api/account`, payload, {
        headers: { Authorization: `Bearer ${token}` }
      });
      const updated = res.data.user;
      setUser(updated);
      setProviderAvatars(updated.provider_avatar_list || []);
      setSelectedProvider(updated.provider_selected || updated.provider || null);
      setSelectedAvatar(updated.avatar_url || null);
      setCustomAvatar(updated.avatar_url || '');
      setSuccess('Saved');
    } catch (e: any) {
      const status = e?.response?.status;
      if (status === 401 || status === 403) {
        forceLogout('Session expired. Please sign in again.');
        return;
      }
      setError(e?.response?.data?.error || 'Failed to save account');
    } finally {
      setSaving(false);
    }
  };

  const saveAvatar = async (avatarValue: string | null, providerOverride?: string | null) => {
    const token = getAuthToken();
    if (!token) {
      forceLogout('Session expired. Please sign in again.');
      return;
    }
    if (avatarValue === null) {
      setError('Select or clear an avatar before saving.');
      return;
    }
    setAvatarSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const res = await axios.put<ApiUser>(`${API_BASE_URL}/api/account`, {
        avatar_url: avatarValue,
        avatar_provider: providerOverride || undefined,
      }, {
        headers: { Authorization: `Bearer ${token}` }
      });
      const updated = res.data.user;
      setUser(updated);
      setProviderAvatars(updated.provider_avatar_list || []);
      setSelectedProvider(updated.provider_selected || updated.provider || null);
      setSelectedAvatar(updated.avatar_url || null);
      setCustomAvatar(updated.avatar_url || '');
      setSuccess('Avatar saved');
    } catch (e: any) {
      const status = e?.response?.status;
      if (status === 401 || status === 403) {
        forceLogout('Session expired. Please sign in again.');
        return;
      }
      setError(e?.response?.data?.error || 'Failed to save avatar');
    } finally {
      setAvatarSaving(false);
    }
  };

  const handleSaveAvatar = async () => {
    const providerForSave = selectedProvider || currentSelectedProvider();
    await saveAvatar(selectedAvatar, providerForSave);
  };

  const avatarPreview = selectedAvatar === '' ? FALLBACK_AVATAR : selectedAvatar || initialAvatarSource || FALLBACK_AVATAR;

  const applyProviderAvatar = (provider: string, url: string | null) => {
    setSelectedProvider(provider);
    setSelectedAvatar(url || '');
    setCustomAvatar(url || '');
  };

  const applyCustomAvatar = async () => {
    const trimmed = customAvatar.trim();
    const providerForSave = currentSelectedProvider();
    setSelectedProvider(providerForSave);
    setSelectedAvatar(trimmed || '');
    await saveAvatar(trimmed || '', providerForSave);
  };

  if (loading) {
    return (
      <div className="container">
        <div className="card">
          <p>Loading account…</p>
        </div>
      </div>
    );
  }

  if (!user) {
    return (
      <div className="container">
        <div className="card">
          <p className="error">Unable to load account.</p>
          <button className="secondary" onClick={() => navigate('/home')}>Back</button>
        </div>
      </div>
    );
  }

  return (
    <div className="container">
      <div className="shell">
        <header className="app-header">
          <div className="logo">Account Settings</div>
          <div className="user-pill">
            <button className="chip" onClick={() => navigate('/home')}>Back to Home</button>
          </div>
        </header>

        <div className="grid settings-grid">
          <div className="card">
            <h1>Profile</h1>
            <div className="field">
              <label className="label" htmlFor="email">Email</label>
              <input
                id="email"
                className="input"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
              />
            </div>

            <div className="field">
              <label className="label" htmlFor="username">Username</label>
              <input
                id="username"
                className="input"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                placeholder="username"
              />
            </div>

            <div className="field">
              <label className="label" htmlFor="displayName">Display name</label>
              <input
                id="displayName"
                className="input"
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                placeholder="Display name"
              />
            </div>

            <div className="actions">
              <button className="primary" onClick={handleSave} disabled={saving}>
                {saving ? 'Saving…' : 'Save'}
              </button>
              <button className="secondary" onClick={() => navigate('/home')}>Cancel</button>
            </div>
            {error && <p className="error">{error}</p>}
            {success && <p className="hint">{success}</p>}
          </div>

          <div className="card">
            <h1>Avatar</h1>
            <div className="avatar-preview" style={{ backgroundImage: `url(${avatarPreview})` }} aria-label="Avatar preview" />
            <div className="avatar-options">
              <label className="label" htmlFor="avatarFile">Available Images</label>
              {providerAvatars.length === 0 && <p className="hint">Link a provider to pull an avatar.</p>}
              {providerAvatars.length > 0 && (
                <div className="avatar-strip" role="list">
                  {providerAvatars.map((p) => {
                    const isActive = p.is_selected || p.provider === selectedProvider;
                    return (
                      <button
                        key={`${p.provider}-${p.provider_id || 'default'}`}
                        type="button"
                        role="listitem"
                        className={`avatar-dot ${isActive ? 'active' : ''}`}
                        onClick={() => applyProviderAvatar(p.provider, p.avatar_url || null)}
                        aria-label={`Add ${p.provider} avatar`}
                      >
                        <span
                          className="avatar-thumb large"
                          style={{ backgroundImage: `url(${p.avatar_url || FALLBACK_AVATAR})` }}
                        />
                        <span className="avatar-tooltip">{p.provider}</span>
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
            <div className="avatar-upload">
              <label className="label" htmlFor="avatarFile">Upload New Image</label>
              <input
                id="avatarFile"
                type="file"
                accept=".jpg,.jpeg,.png,.bmp,.heic,.heif,image/jpeg,image/png,image/bmp,image/heic,image/heif"
                onChange={(e) => handleFileInput(e.target.files?.[0])}
              />
              <p className="hint">Supported: JPG, PNG, BMP, HEIC.</p>
            </div>
            
            <div className="field">
              <label className="label" htmlFor="customAvatar">Custom Image URL</label>
              <div className="inline-input">
                <input
                  id="customAvatar"
                  className="input"
                  value={customAvatar}
                  onChange={(e) => setCustomAvatar(e.target.value)}
                  placeholder="https://example.com/avatar.png"
                />
                <button className="secondary" onClick={applyCustomAvatar}>Add</button>
                <button className="ghost" onClick={() => { setSelectedProvider(currentSelectedProvider()); setSelectedAvatar(''); setCustomAvatar(''); }}>
                Clear
              </button>
              </div>
              
            </div>
            <div className="actions">
              <button
                className="primary"
                onClick={handleSaveAvatar}
                disabled={avatarSaving || selectedAvatar === null}
              >
                {avatarSaving ? 'Saving…' : 'Save'}
              </button>
            </div>
          </div>
        </div>
      </div>

      {showCropper && cropImage && (
        <div className="modal-backdrop">
          <div className="modal">
            <h2>Crop avatar</h2>
            <div className="cropper-shell">
              <Cropper
                image={cropImage}
                crop={crop}
                zoom={zoom}
                aspect={1}
                cropShape="rect"
                showGrid={false}
                onCropChange={setCrop}
                onZoomChange={setZoom}
                onCropComplete={onCropComplete}
              />
            </div>
            <div className="crop-controls">
              <span className="hint">Zoom</span>
              <input
                className="range"
                type="range"
                min={1}
                max={3}
                step={0.01}
                value={zoom}
                onChange={(e) => setZoom(Number(e.target.value))}
              />
            </div>
            <div className="modal-actions">
              <button className="secondary" onClick={closeCropper} disabled={uploading}>Cancel</button>
              <button className="primary" onClick={uploadCroppedAvatar} disabled={uploading}>
                {uploading ? 'Uploading…' : 'Save'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
