// This hook owns no DOM. Its sticky LiveView supplies the authoritative state.
export const DutyTab = {
  mounted() { this.notify() },
  updated() { this.notify() },
  notify() { window.dispatchEvent(new Event("bc:duty-changed")) },
}

export function dutyTabs(tabs, active) {
  const others = tabs.filter((tab) => tab.path !== "/duty")
  if (!active) return others
  const index = tabs.findIndex((tab) => tab.path === "/duty")
  others.splice(index < 0 ? others.length : index, 0, {path: "/duty", label: "On duty"})
  return others
}
