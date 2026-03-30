import { ButtonHTMLAttributes } from 'react'

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'default' | 'secondary' | 'danger' | 'ok'
  size?: 'sm' | 'md' | 'lg'
}

const variantStyles = {
  default: 'bg-accent text-bg hover:bg-accent-2',
  secondary: 'bg-surface text-text border border-border hover:border-accent hover:text-accent',
  danger: 'bg-danger text-white hover:bg-red-700',
  ok: 'bg-ok text-bg hover:bg-green-600',
}

const sizeStyles = {
  sm: 'px-2 py-1 text-xs',
  md: 'px-4 py-2 text-sm',
  lg: 'px-4 py-3 text-base',
}

export function Button({
  variant = 'default',
  size = 'md',
  className = '',
  ...props
}: ButtonProps) {
  const baseStyle = 'inline-flex items-center gap-1.5 border-none rounded-[10px] font-semibold cursor-pointer transition-colors disabled:opacity-40 disabled:cursor-not-allowed'
  const variantStyle = variantStyles[variant]
  const sizeStyle = sizeStyles[size]

  return (
    <button
      className={`${baseStyle} ${variantStyle} ${sizeStyle} ${className}`}
      {...props}
    />
  )
}
