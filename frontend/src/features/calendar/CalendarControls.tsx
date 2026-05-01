type CalendarControlsProps = {
  shadeActive: boolean;
  onPrevious: () => void;
  onToday: () => void;
  onNext: () => void;
  onToggleShade: () => void;
};

export function CalendarControls(props: CalendarControlsProps) {
  return (
    <div class="calendar-controls" aria-label="Calendar controls">
      <button class="calendar-control-btn" onClick={props.onPrevious}>Previous</button>
      <button class="calendar-control-btn" onClick={props.onToday}>Today</button>
      <button class="calendar-control-btn" onClick={props.onNext}>Next</button>
      <button
        class="calendar-control-btn"
        classList={{ active: props.shadeActive }}
        onClick={props.onToggleShade}
      >
        Shade
      </button>
    </div>
  );
}
