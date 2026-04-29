type StatusBarProps = {
  currentModel: string;
  modelCount: number;
  activity: string;
};

export function StatusBar(props: StatusBarProps) {
  return (
    <div class="status-bar">
      <span>{props.currentModel ? `Model: ${props.currentModel}` : "No model"} | {props.modelCount} installed</span>
      <span class="status-activity">{props.activity}</span>
      <span>Buster Claw</span>
    </div>
  );
}
