import { InputHTMLAttributes } from 'react'

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string
  error?: string
}

export function Input({ label, error, className = '', ...props }: InputProps) {
  return (
    <div className="flex flex-col gap-1.5">
      {label && (
        <label className="text-xs font-medium text-muted">{label}</label>
      )}
      <input
        className={`bg-bg border border-border rounded-lg text-text placeholder-muted/50 px-3 py-2 text-sm outline-none transition-colors focus:border-accent/60 focus:ring-1 focus:ring-accent/20 ${className}`}
        {...props}
      />
      {error && <span className="text-xs text-danger">{error}</span>}
    </div>
  )
}
