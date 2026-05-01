import { AppViews } from "./app/AppViews";
import { useAppController } from "./app/useAppController";
import { Header } from "./components/Header";
import { Sidebar } from "./components/Sidebar";
import { StarfieldBackground } from "./components/StarfieldBackground";
import { StatusBar } from "./components/StatusBar";

function App() {
  const app = useAppController();

  return (
    <div class="app">
      <StarfieldBackground />
      <Header />
      <Sidebar activeView={app.activeView} status={app.status} onSwitchView={app.switchView} onClearChat={app.clearChat} />
      <AppViews controller={app} />
      <StatusBar currentModel={app.currentModel} modelCount={app.models.length} activity={app.statusActivity} />
    </div>
  );
}

export default App;
