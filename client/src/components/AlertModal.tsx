import React from 'react';

export type AlertModalProps = {
  open: boolean;
  title: string;
  message: string;
  primaryLabel: string;
  onPrimary: () => void;
  secondaryLabel?: string;
  onSecondary?: () => void;
};

export function AlertModal({
  open,
  title,
  message,
  primaryLabel,
  onPrimary,
  secondaryLabel,
  onSecondary,
}: AlertModalProps) {
  if (!open) return null;

  return (
    <div className="modal-backdrop alert-modal">
      <div className="modal">
        <h2>{title}</h2>
        <p className="hint" style={{ marginTop: 4 }}>{message}</p>
        <div className="actions" style={{ marginTop: 16 }}>
          {secondaryLabel && onSecondary && (
            <button className="ghost" onClick={onSecondary}>{secondaryLabel}</button>
          )}
          <button className="primary" onClick={onPrimary}>{primaryLabel}</button>
        </div>
      </div>
    </div>
  );
}

export default AlertModal;
