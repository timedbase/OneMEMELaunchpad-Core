import { ButtonHTMLAttributes } from 'react'

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'default' | 'secondary' | 'danger' | 'ok'
  size?: 'sm' | 'md' | 'lg'
}

const variantStyles: Record<string, string> = {
  default:   'bg-accent text-white border border-transparent hover:bg-accent-2',
  secondary: 'bg-transparent text-muted border border-border hover:border-accent/40 hover:text-text',
  danger:    'bg-danger/10 text-danger border border-danger/25 hover:bg-danger/20',
  ok:        'bg-ok/10 text-ok border border-ok/25 hover:bg-ok/20',
}

const sizeStyles: Record<string, string> = {
  sm: 'px-3 py-1.5 text-xs',
  md: 'px-4 py-2 text-sm',
  lg: 'px-5 py-2.5 text-sm',
}

export function Button({ variant = 'default', size = 'md', className = '', ...props }: ButtonProps) {
  return (
    <button
      className={`inline-flex items-center justify-center gap-1.5 rounded-lg font-medium cursor-pointer transition-all duration-150 disabled:opacity-40 disabled:cursor-not-allowed ${variantStyles[variant]} ${sizeStyles[size]} ${className}`}
      {...props}
    />
  )
}
