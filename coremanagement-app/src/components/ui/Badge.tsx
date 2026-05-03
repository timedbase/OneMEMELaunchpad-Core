interface BadgeProps {
  variant?: 'ok' | 'danger' | 'warn' | 'muted' | 'accent'
  children: React.ReactNode
}

const variantStyles: Record<string, string> = {
  ok:     'bg-ok/15 text-ok border border-ok/20',
  danger: 'bg-danger/15 text-danger border border-danger/20',
  warn:   'bg-warn/15 text-warn border border-warn/20',
  muted:  'bg-muted/10 text-muted border border-muted/15',
  accent: 'bg-accent/15 text-accent border border-accent/20',
}

export function Badge({ variant = 'muted', children }: BadgeProps) {
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${variantStyles[variant]}`}>
      {children}
    </span>
  )
}
