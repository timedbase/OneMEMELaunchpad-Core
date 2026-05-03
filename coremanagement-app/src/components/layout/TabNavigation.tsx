interface SidebarProps {
  activeTab: string
  onTabChange: (tab: string) => void
  isOpen: boolean
  onClose: () => void
}

const NAV_GROUPS = [
  {
    label: 'Platform',
    items: [
      { id: 'overview', label: 'Overview', icon: '◈' },
    ],
  },
  {
    label: 'Launchpad',
    items: [
      { id: 'create',    label: 'Create Token', icon: '+' },
      { id: 'registry',  label: 'Registry',     icon: '▤' },
      { id: 'inspector', label: 'Inspector',     icon: '◎' },
    ],
  },
  {
    label: 'Admin',
    items: [
      { id: 'admin',       label: 'Admin',       icon: '⚙' },
      { id: 'peripherals', label: 'Peripherals', icon: '⬡' },
    ],
  },
  {
    label: 'Protocol',
    items: [
      { id: 'aggregator', label: 'Aggregator', icon: '⇆' },
      { id: 'metatx',     label: 'MetaTx',     icon: '⚡' },
    ],
  },
]

export default function Sidebar({ activeTab, onTabChange, isOpen, onClose }: SidebarProps) {
  return (
    <aside
      className={`
        fixed md:relative inset-y-0 left-0 z-30
        w-48 flex flex-col shrink-0
        bg-surface border-r border-border
        transition-transform duration-200 ease-in-out
        ${isOpen ? 'translate-x-0' : '-translate-x-full md:translate-x-0'}
      `}
    >
      {/* Brand */}
      <div className="flex items-center gap-2 px-3 py-3 border-b border-border">
        <div className="w-6 h-6 rounded bg-accent/20 flex items-center justify-center text-accent font-bold text-xs select-none shrink-0">
          ◈
        </div>
        <div className="min-w-0">
          <div className="text-xs font-semibold text-text leading-tight">OneMEME</div>
          <div className="text-[9px] text-muted leading-tight">Core Management</div>
        </div>
        <button
          className="ml-auto md:hidden text-muted hover:text-text transition-colors cursor-pointer bg-transparent border-none text-xs"
          onClick={onClose}
        >
          ✕
        </button>
      </div>

      {/* Nav */}
      <nav className="flex-1 overflow-y-auto py-2 px-1.5 space-y-3">
        {NAV_GROUPS.map(group => (
          <div key={group.label}>
            <div className="px-2 mb-1 text-[9px] font-semibold uppercase tracking-widest text-muted/40">
              {group.label}
            </div>
            <div className="space-y-0.5">
              {group.items.map(item => (
                <button
                  key={item.id}
                  onClick={() => onTabChange(item.id)}
                  className={`
                    w-full flex items-center gap-2 px-2 py-1.5 rounded-md text-xs
                    transition-all duration-150 cursor-pointer border-none text-left
                    ${activeTab === item.id
                      ? 'bg-accent/15 text-accent font-medium'
                      : 'text-muted font-normal hover:text-text hover:bg-white/5'
                    }
                  `}
                >
                  <span className="text-xs leading-none w-3.5 text-center opacity-70 shrink-0">{item.icon}</span>
                  <span className="flex-1 truncate">{item.label}</span>
                  {activeTab === item.id && (
                    <span className="w-1 h-1 rounded-full bg-accent shrink-0" />
                  )}
                </button>
              ))}
            </div>
          </div>
        ))}
      </nav>

      {/* Footer */}
      <div className="px-3 py-2 border-t border-border">
        <div className="text-[9px] text-muted/30 font-mono">BSC · v1.0</div>
      </div>
    </aside>
  )
}
