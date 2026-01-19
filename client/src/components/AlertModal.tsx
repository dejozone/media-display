import React from 'react';
import { useNavigate } from 'react-router-dom';

export type AlertModalProps = {
  open: boolean;
  title: string;
  message: string;
  primaryLabel: string;
  onPrimary: () => void;
  secondaryLabel?: string;
  onSecondary?: () => void;
  onClose?: () => void;
  autoNavigateBack?: boolean;
  closeOnBackdrop?: boolean;
};

export function AlertModal({
  open,
  title,
  message,
  primaryLabel,
  onPrimary,
  secondaryLabel,
  onSecondary,
  onClose,
  autoNavigateBack = false,
  closeOnBackdrop = false,
}: AlertModalProps) {
  const navigate = useNavigate();

  const navigateBack = () => {
    if (!autoNavigateBack) return;
    if (typeof window !== 'undefined' && window.history.length > 1) {
      navigate(-1);
    } else {
      navigate('/');
    }
  };

  const handlePrimary = () => {
    onPrimary();
    navigateBack();
  };

  const handleSecondary = () => {
    if (onSecondary) onSecondary();
    navigateBack();
  };

  const handleBackdrop = () => {
    if (!closeOnBackdrop) return;
    if (onClose) onClose();
    navigateBack();
  };

  if (!open) return null;

  return (
    <div className="modal-backdrop alert-modal" onClick={handleBackdrop}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h2>{title}</h2>
        <p className="hint" style={{ marginTop: 4 }}>{message}</p>
        <div className="actions" style={{ marginTop: 16 }}>
          {secondaryLabel && onSecondary && (
            <button className="ghost" onClick={handleSecondary}>{secondaryLabel}</button>
          )}
          <button className="primary" onClick={handlePrimary}>{primaryLabel}</button>
        </div>
      </div>
    </div>
  );
}

export default AlertModal;
