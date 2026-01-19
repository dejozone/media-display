const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const USERNAME_REGEX = /^[A-Za-z0-9._-]{3,50}$/;
const SUPPORTED_IMAGE_EXTS = ['.jpg', '.jpeg', '.png', '.bmp', '.heic', '.heif'];
const MAX_IMAGE_BYTES = 8 * 1024 * 1024; // 8 MB

type ImageValidationResult = {
  error?: string;
  targetFormat?: 'image/jpeg' | 'image/png';
  targetExt?: 'jpg' | 'png';
  isHeic?: boolean;
};

const normalizeExt = (name: string) => {
  const dot = name.lastIndexOf('.');
  if (dot < 0) return '';
  return name.slice(dot).toLowerCase();
};

export const validateEmail = (email?: string | null): string | null => {
  if (!email) return null;
  return EMAIL_REGEX.test(email) ? null : 'Invalid email format';
};

export const validateUsername = (username?: string | null): string | null => {
  if (!username) return null;
  return USERNAME_REGEX.test(username)
    ? null
    : 'Username must be 3-50 characters and only letters, numbers, dot, underscore, or dash.';
};

export const validateDisplayName = (displayName?: string | null): string | null => {
  if (!displayName) return null;
  return displayName.length <= 80 ? null : 'Display name must be 80 characters or fewer.';
};

export const validateImageFile = (file?: File | null): ImageValidationResult => {
  if (!file) return { error: 'No file provided' };
  const ext = normalizeExt(file.name);
  if (!SUPPORTED_IMAGE_EXTS.includes(ext)) {
    return { error: 'Unsupported file type. Use .jpg, .png, .bmp, or .heic' };
  }
  if (file.size > MAX_IMAGE_BYTES) {
    return { error: 'Image too large. Max size is 8 MB.' };
  }
  const isHeic = ext === '.heic' || ext === '.heif' || file.type === 'image/heic' || file.type === 'image/heif';
  if (ext === '.png') {
    return { targetFormat: 'image/png', targetExt: 'png', isHeic };
  }
  // All other supported formats convert to JPEG
  return { targetFormat: 'image/jpeg', targetExt: 'jpg', isHeic };
};
