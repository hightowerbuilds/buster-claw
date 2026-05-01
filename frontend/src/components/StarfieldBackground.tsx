import { createMemo, For } from "solid-js";
import "./StarfieldBackground.css";

type StarLayer = {
  className: string;
  stars: string;
};

function seededRandom(seed: number) {
  let value = seed;
  return () => {
    value = (value * 1664525 + 1013904223) % 4294967296;
    return value / 4294967296;
  };
}

function buildStarLayer(count: number, width: number, height: number, seed: number) {
  const random = seededRandom(seed);
  const stars: string[] = [];

  for (let index = 0; index < count; index += 1) {
    const x = Math.round(random() * width);
    const y = Math.round(random() * height);
    const alpha = 0.18 + random() * 0.62;
    stars.push(`${x}px ${y}px rgba(224, 232, 255, ${alpha.toFixed(2)})`);
  }

  return stars.join(", ");
}

export function StarfieldBackground() {
  const layers = createMemo<StarLayer[]>(() => [
    {
      className: "starfield-layer starfield-layer-far",
      stars: buildStarLayer(2400, 2200, 2800, 1729),
    },
    {
      className: "starfield-layer starfield-layer-mid",
      stars: buildStarLayer(1400, 2200, 2800, 2237),
    },
    {
      className: "starfield-layer starfield-layer-near",
      stars: buildStarLayer(820, 2200, 2800, 2917),
    },
  ]);

  return (
    <div class="starfield-background" aria-hidden="true">
      <For each={layers()}>
        {(layer) => <div class={layer.className} style={{ "box-shadow": layer.stars }} />}
      </For>
    </div>
  );
}
