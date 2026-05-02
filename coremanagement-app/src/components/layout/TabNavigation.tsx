interface TabNavigationProps {
  activeTab: string
  onTabChange: (tab: string) => void
}

const tabs = [
  { id: 'overview', label: 'Overview' },
  { id: 'create', label: 'Create Token' },
  { id: 'registry', label: 'Registry' },
  { id: 'inspector', label: 'Inspector' },
  { id: 'admin', label: 'Admin' },
  { id: 'peripherals', label: 'Peripherals' },
  { id: 'aggregator', label: 'Aggregator' },
]

export default function TabNavigation({ activeTab, onTabChange }: TabNavigationProps) {
  return (
    <div className="flex gap-0 border-b border-border mb-6 overflow-x-auto">
      {tabs.map((tab) => (
        <button
          key={tab.id}
          onClick={() => onTabChange(tab.id)}
          className={`px-5 py-2.5 bg-none border-none text-sm font-medium cursor-pointer border-b-2 transition-colors whitespace-nowrap ${
            activeTab === tab.id
              ? 'text-accent border-accent'
              : 'text-muted hover:text-text border-transparent'
          }`}
        >
          {tab.label}
        </button>
      ))}
    </div>
  )
}
