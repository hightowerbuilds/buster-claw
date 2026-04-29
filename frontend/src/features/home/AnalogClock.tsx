import { createEffect, createSignal, onCleanup } from "solid-js";

export function AnalogClock() {
  const [time, setTime] = createSignal(new Date());

  createEffect(() => {
    const timer = setInterval(() => setTime(new Date()), 1000);
    onCleanup(() => clearInterval(timer));
  });

  const secondsDegrees = () => (time().getSeconds() / 60) * 360;
  const minsDegrees = () => ((time().getMinutes() + time().getSeconds() / 60) / 60) * 360;
  const hourDegrees = () => ((time().getHours() % 12 + time().getMinutes() / 60) / 12) * 360;

  return (
    <div class="analog-clock-wrapper">
      <div class="analog-clock">
        <div class="clock-center"></div>
        <div class="clock-hand hour-hand" style={{ transform: `rotate(${hourDegrees()}deg)` }}></div>
        <div class="clock-hand minute-hand" style={{ transform: `rotate(${minsDegrees()}deg)` }}></div>
        <div class="clock-hand second-hand" style={{ transform: `rotate(${secondsDegrees()}deg)` }}></div>
      </div>
    </div>
  );
}
