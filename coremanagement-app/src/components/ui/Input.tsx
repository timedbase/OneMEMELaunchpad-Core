import { InputHTMLAttributes } from 'react'

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string
  error?: string
}

export function Input({ label, error, className = '', ...props }: InputProps) {
  return (
    <div className="flex flex-col gap-1">
      {label && (
        <label className="text-[11px] font-medium text-muted">{label}</label>
      )}
      <input
        className={`bg-bg border border-border rounded-md text-text placeholder-muted/40 px-2.5 py-1.5 text-xs outline-none transition-colors focus:border-accent/60 focus:ring-1 focus:ring-accent/20 ${className}`}
        {...props}
      />
      {error && <span className="text-[11px] text-danger">{error}</span>}
    </div>
  )
}
