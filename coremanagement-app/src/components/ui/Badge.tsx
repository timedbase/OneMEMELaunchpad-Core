interface BadgeProps {
  variant?: 'ok' | 'danger' | 'warn' | 'muted' | 'accent'
  children: React.ReactNode
}

const variantStyles = {
  ok: 'bg-green-500/15 text-ok',
  danger: 'bg-danger/15 text-danger',
  warn: 'bg-warn/15 text-warn',
  muted: 'bg-muted/15 text-muted',
  accent: 'bg-accent/15 text-accent',
}

export function Badge({ variant = 'muted', children }: BadgeProps) {
  return (
    <span className={`inline-block px-2 py-0.5 rounded-full text-xs font-semibold ${variantStyles[variant]}`}>
      {children}
    </span>
  )
}
